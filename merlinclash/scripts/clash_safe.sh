#!/bin/sh
# Shared safety primitives. Lock files are stable inodes and are never unlinked.
PATH=/jffs/softcenter/bin:/jffs/softcenter/scripts:/usr/sbin:/sbin:/bin:/usr/bin:/opt/bin:/opt/sbin
export PATH
MC_ROOT=/jffs/softcenter/merlinclash
MC_LIFECYCLE_LOCK=/tmp/merlinclash.lifecycle.lock
mc_curl() {
    # This firmware client can exit 0 without issuing a request. Entware works.
    if [ -x /opt/bin/curl ]; then /opt/bin/curl "$@"; else /usr/sbin/curl "$@"; fi
}
mc_mktemp() {
    local kind=file template prefix item n=0
    if [ "${1:-}" = -d ]; then kind=dir; shift; fi
    template=${1:-/tmp/merlinclash.XXXXXX}
    case "$template" in *XXXXXX) prefix=${template%XXXXXX} ;; *) return 1 ;; esac
    while [ "$n" -lt 100 ]; do
        item="${prefix}$$.$(date +%s).$n"
        if [ "$kind" = dir ]; then
            (umask 077; mkdir "$item") 2>/dev/null && { printf '%s\n' "$item"; return 0; }
        else
            (umask 077; set -C; : > "$item") 2>/dev/null && { printf '%s\n' "$item"; return 0; }
        fi
        n=$((n+1))
    done
    return 1
}
mc_lock() {
    local cleanup_only=0
    [ "$#" -le 1 ] || return 2
    case "${1:-}" in '' ) ;; --cleanup-only) cleanup_only=1 ;; *) return 2 ;; esac
    if [ "${MC_LOCK_HELD:-}" = 1 ] && [ "$(readlink /proc/$$/fd/9 2>/dev/null)" = "$MC_LIFECYCLE_LOCK" ]; then
        flock -n 9 || return 75
        [ "${MC_LOCK_OWNER_PID:-}" = "$$" ] || MC_LOCK_OWNER=0
        return 0
    fi
    exec 9>"$MC_LIFECYCLE_LOCK" || return 1
    flock -n 9 || { exec 9>&-; return 75; }
    MC_LOCK_HELD=1
    MC_LOCK_OWNER=1
    MC_LOCK_OWNER_PID=$$
    export MC_LOCK_HELD
    # Only the new owner repairs interrupted publications. An inherited owner
    # may be the child of a transaction that is still publishing its own pair.
    # Stop needs only mutual exclusion; broken profiles must not block cleanup.
    [ "$cleanup_only" != 1 ] || return 0
    mc_recover_profiles || { mc_unlock; return 1; }
}
mc_unlock() {
    if [ "${MC_LOCK_OWNER:-0}" = 1 ]; then
        flock -u 9
        exec 9>&-
        unset MC_LOCK_HELD MC_LOCK_OWNER MC_LOCK_OWNER_PID
    fi
}
mc_valid_name() {
    case "${1:-}" in ''|.|..|*[!a-zA-Z0-9_.-]*) return 1 ;; esac
    [ "${#1}" -le 128 ]
}
mc_core_pids() {
    local p exe expected args
    expected=$(readlink -f /jffs/softcenter/bin/clash)
    for p in $(pidof clash 2>/dev/null); do
        exe=$(readlink "/proc/$p/exe" 2>/dev/null)
        exe=${exe% (deleted)}
        args=$(tr '\000' '\n' < "/proc/$p/cmdline" 2>/dev/null)
        printf '%s\n' "$args" | grep -Eq '^-(t|v)$' && continue
        [ "$exe" != "$expected" ] || printf '%s\n' "$p"
    done
}
mc_selected() {
    local name
    name=$(dbus get merlinclash_set_yamlsel_start)
    [ -n "$name" ] || name=$(dbus get merlinclash_yamlsel)
    mc_valid_name "$name" || return 1
    printf '%s\n' "$name"
}
mc_active_config() {
    local p cfg
    p=$(mc_core_pids | head -1)
    [ -n "$p" ] || return 1
    cfg=$(tr '\000' '\n' < "/proc/$p/cmdline" | awk 'found {print; exit} $0=="-f" {found=1}')
    cfg=$(readlink -f "$cfg") || return 1
    case "$cfg" in "$MC_ROOT"/yaml_use/*.yaml) [ -s "$cfg" ] && printf '%s\n' "$cfg" ;; *) return 1 ;; esac
}
mc_active_name() {
    local cfg name
    cfg=$(mc_active_config) || return 1
    name=${cfg##*/}; name=${name%.yaml}
    mc_valid_name "$name" || return 1
    printf '%s\n' "$name"
}
mc_dnsmasq_owner() {
    local p expected exe start
    # The firmware also has a dnsmasq helper process. Identify the main server
    # by the actual local DNS socket, then verify its executable and lifetime.
    p=$(netstat -lnup 2>/dev/null | awk '
        /^udp/ && ($4=="127.0.0.1:53" || $4=="0.0.0.0:53") {
            split($NF,owner,"/")
            if(owner[1] ~ /^[0-9]+$/ && owner[2]=="dnsmasq") {print owner[1]; exit}
        }')
    case "$p" in ''|*[!0-9]*) return 1 ;; esac
    expected=$(readlink -f /usr/sbin/dnsmasq) || return 1
    exe=$(readlink "/proc/$p/exe" 2>/dev/null) || return 1
    [ "$exe" = "$expected" ] || return 1
    start=$(sed 's/.*) //' "/proc/$p/stat" 2>/dev/null | awk '{print $20}')
    case "$start" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s:%s\n' "$p" "$start"
}
mc_dnsmasq_block_matches() {
    local config=$1 expected= cfg listen host port enabled
    [ -f "$config" ] || return 1
    if [ "$(dbus get merlinclash_enable)" = 1 ] &&
       [ "$(dbus get merlinclash_ipt_closeproxy_sw)" != 1 ] &&
       [ -n "$(mc_core_pids)" ]; then
        cfg=$(mc_active_config) || return 1
        enabled=$(yq e -r '.dns.enable // false' "$cfg" 2>/dev/null) || return 1
        case "$enabled" in
        false) ;;
        true)
        listen=$(yq e -r '.dns.listen // ""' "$cfg" 2>/dev/null) || return 1
        port=${listen##*:}
        case "$port" in ''|*[!0-9]*) return 1 ;; esac
        [ "$port" -gt 0 ] && [ "$port" -le 65535 ] || return 1
        host=${listen%:*}
        case "$host" in '['*']') host=${host#\[}; host=${host%\]} ;; esac
        case "$host" in ''|0.0.0.0|localhost) host=127.0.0.1 ;; ::) host=::1 ;; esac
        case "$host" in ''|*[!0-9a-fA-F:.]*) return 1 ;; esac
        expected="server=/#/$host#$port"
        ;;
        *) return 1 ;;
        esac
    fi
    awk -v expected="$expected" '
        $0=="# BEGIN Magic Catling 2 DNS" {if(block || begins++) bad=1; block=1; next}
        $0=="# END Magic Catling 2 DNS" {if(!block || ends++) bad=1; block=0; next}
        block {if($0=="no-resolv") resolv++; else if($0==expected) servers++; else bad=1}
        END {
            if(block || bad) exit 1
            if(expected=="") exit (begins || ends)
            exit !(begins==1 && ends==1 && resolv==1 && servers==1)
        }
    ' "$config"
}
mc_dns_server_dir_owned() {
    local directory=$1 base=$2 prefix suffix
    mc_valid_name "$base" || return 1
    prefix=/tmp/mc-dnsmasq-server-files.$base.
    case "$directory" in "$prefix"*) suffix=${directory#"$prefix"} ;; *) return 1 ;; esac
    case "$suffix" in ''|*[!0-9.]*) return 1 ;; esac
    printf '%s\n' "$suffix" | awk -F. 'NF!=3 {exit 1} {for(i=1;i<=3;i++) if($i !~ /^[0-9]+$/) exit 1}' || return 1
    [ -d "$directory" ] && [ ! -L "$directory" ] &&
        [ -f "$directory/owned" ] && [ ! -L "$directory/owned" ] &&
        [ "$(cat "$directory/owned")" = "$base" ]
}
mc_dns_gc() {
    (
    local config=$1 base directory
    base=${config##*/}
    [ -f "$config" ] && mc_valid_name "$base" || return 1
    # Firmware callbacks do not take the lifecycle lock. Exclude their private
    # preparation as well as publication; a contended cleanup can safely defer.
    exec 7>"/tmp/merlinclash-dnsmasq-$base.lock" || return 1
    flock -n 7 || return 0
    for directory in /tmp/mc-dnsmasq-server-files."$base".*; do
        mc_dns_server_dir_owned "$directory" "$base" || continue
        # The replacement daemon has loaded this config. Retain current refs
        # and original-source comments, and retire only our other generations.
        grep -Fq "$directory/" "$config" && continue
        rm -rf "$directory" || return 1
    done
    return 0
    )
}
mc_dnsmasq_wait() {
    local previous=${1:-} config=${2:-/etc/dnsmasq.conf} owner n=0 now deadline
    now=$(date +%s) || return 1
    case "$now" in ''|*[!0-9]*) return 1 ;; esac
    deadline=$((now+30))
    # service queues an asynchronous firmware action. An old PID proves only
    # that the previous daemon is still alive, not that the new config loaded.
    while [ "$n" -lt 120 ]; do
        now=$(date +%s) || return 1
        case "$now" in ''|*[!0-9]*) return 1 ;; esac
        [ "$now" -lt "$deadline" ] || return 1
        owner=$(mc_dnsmasq_owner)
        if [ -n "$owner" ] && [ "$owner" != "$previous" ] &&
           mc_dnsmasq_block_matches "$config"; then
            mc_dns_gc "$config" || printf 'Obsolete DNS server-file generation retained.\n' >&2
            return 0
        fi
        usleep 250000
        n=$((n+1))
    done
    return 1
}
mc_validate_yaml() {
    [ -s "$1" ] && /jffs/softcenter/bin/clash -t -d "$MC_ROOT" -f "$1" >/tmp/merlinclash-validation.log 2>&1
}
mc_ai_profile() {
    local range yq_bin
    yq_bin=$(command -v yq 2>/dev/null || echo /jffs/softcenter/bin/yq)
    [ -x "$yq_bin" ] || return 1
    [ "$("$yq_bin" e '.tun.enable == true and .tun.device == "mcquic"' "$1" 2>/dev/null)" = true ] || return 1
    range=$("$yq_bin" e -r '.dns.fake-ip-range // ""' "$1" 2>/dev/null) || return 1
    case "$range" in 198.19.*.*/16) ;; *) return 1 ;; esac
    printf '%s' "${range%/16}" | awk -F. '{
        if(NF!=4) exit 1
        for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i+0>255) exit 1
    }'
}

mc_owned_state_present() {
    [ "$#" -le 1 ] || return 2
    case "${1:-}" in ''|--dns-only) ;; *) return 2;; esac
    local config resolved base config_dir etc_dir temp_etc_dir family table
    etc_dir=$(readlink -f /etc)
    temp_etc_dir=$(readlink -f /tmp/etc)
    for config in /etc/dnsmasq.conf /tmp/etc/dnsmasq*.conf /tmp/etc/dnsmasq.conf[0-9]*; do
        [ -f "$config" ] || continue
        resolved=$(readlink -f "$config") || continue
        base=${resolved##*/}
        case "$base" in dnsmasq*.conf|dnsmasq.conf[0-9]*) ;; *) continue;; esac
        case "$base" in *[!A-Za-z0-9_.-]*) continue;; esac
        config_dir=${resolved%/*}
        [ "$config_dir" = "$etc_dir" ] || [ "$config_dir" = "$temp_etc_dir" ] || continue
        if grep -Eq '^# (BEGIN|END) Magic Catling 2 DNS( server files)?$' "$resolved"; then return 0; fi
    done
    # Chain declarations alone are harmless. Follow only rules reachable from
    # built-in policies and parse tokens so quoted user comments never match.
    [ "${1:-}" != --dns-only ] || return 1
    for family in iptables ip6tables; do
        for table in nat mangle filter; do
            if "$family" -t "$table" -S 2>/dev/null | awk -v table="$table" '
                function splitrule(line, args, i,c,value,quote,escaped,n,present,sq) {
                    sq=sprintf("%c",39); value=""; quote=""; escaped=0; n=0; present=0
                    for(i=1;i<=length(line);i++) {
                        c=substr(line,i,1)
                        if(escaped) {value=value c; escaped=0; present=1; continue}
                        if(c=="\\" && quote!=sq) {escaped=1; present=1; continue}
                        if(quote!="") {if(c==quote) quote=""; else value=value c; present=1; continue}
                        if(c=="\"" || c==sq) {quote=c; present=1; continue}
                        if(c ~ /[[:space:]]/) {if(present) args[++n]=value; value=""; present=0; continue}
                        value=value c; present=1
                    }
                    if(present) args[++n]=value
                    return n
                }
                $1=="-P" {reachable[$2]=1}
                $1=="-A" {
                    n=splitrule($0,a); rules++; source[rules]=a[2]
                    for(key in fields) delete fields[key]
                    for(i=3;i<n;i+=2) fields[a[i]]=a[i+1]
                    if(table=="nat" && a[2]=="PREROUTING" && n==8 && fields["-i"]=="br0" && fields["-d"]=="198.19.0.0/16" && fields["-j"]=="ACCEPT") owned[rules]=1
                    if(table=="filter" && a[2]=="FORWARD") {
                        if(n==14 && fields["-i"]=="br0" && fields["-o"]=="mcquic" && fields["-d"]=="198.19.0.0/16" && fields["-m"]=="mark" && fields["--mark"]=="0x234/0xffff" && fields["-j"]=="ACCEPT") owned[rules]=1
                        if(n==12 && fields["-i"]=="mcquic" && fields["-o"]=="br0" && fields["-s"]=="198.19.0.0/16" && fields["-d"] ~ /^[0-9.]+\/[0-9]+$/ && fields["-j"]=="ACCEPT") owned[rules]=1
                        if(n==12 && fields["-i"]=="br0" && fields["-o"] ~ /^[A-Za-z0-9_.:-]+$/ && fields["-d"]=="198.19.0.0/16" && fields["-j"]=="REJECT" && fields["--reject-with"]=="icmp-port-unreachable") owned[rules]=1
                    }
                    for(i=3;i<n;i++) {
                        if(a[i]=="-j" || a[i]=="-g") {
                            target[rules]=a[i+1]
                            if(a[i+1] ~ /^(merlinclash(_[A-Za-z0-9_]+)?|MC_PControls|CGPT_QUIC)$/) owned[rules]=1
                        }
                        if(a[i]=="--match-set" && a[i+1] ~ /^(macblacklist_dns|macwhitelist_dns|ipblacklist_dns|ipwhitelist_dns|lan_mac_blacklist)$/) owned[rules]=1
                    }
                }
                END {
                    for(pass=0;pass<=rules;pass++) {
                        changed=0
                        for(i=1;i<=rules;i++) if(reachable[source[i]]) {
                            if(owned[i]) exit 0
                            if(target[i]!="" && !reachable[target[i]]) {reachable[target[i]]=1; changed=1}
                        }
                        if(!changed) break
                    }
                    exit 1
                }
            '; then return 0; fi
        done
    done
    ip rule show 2>/dev/null | awk '
        NF==7 && $1=="100:" && $2=="from" && $3=="all" && $4=="fwmark" && $5=="0x234/0xffff" && $6=="lookup" && $7=="234" {found=1}
        END {exit(found ? 0 : 1)}
    ' && return 0
    ip route show table 234 2>/dev/null | grep -Eq '^default dev mcquic([[:space:]]|$)' && return 0
    for family in -4 -6; do
        ip "$family" rule show 2>/dev/null | awk '
            NF==7 && $1 ~ /^[0-9]+:$/ && $2=="from" && $3=="all" && $4=="fwmark" && $5 ~ /^0x(2333|1111)(\/0xffffffff)?$/ && $6=="lookup" && $7=="233" {found=1}
            END {exit(found ? 0 : 1)}
        ' && return 0
        ip "$family" route show table 233 2>/dev/null | awk '
            $1=="local" && $2=="default" && $3=="dev" && $4=="lo" {found=1}
            END {exit(found ? 0 : 1)}
        ' && return 0
    done
    return 1
}
mc_cleanup_ai() {
    local table chain number numbers snapshot records rc=0
    # Exact historical hook ownership does not depend on today's LAN/WAN.
    # Delete numeric slots backwards to preserve interleaved unrelated rules.
    mc_ai_rule_numbers() {
        local snapshot
        snapshot=$(iptables -t "$1" -S "$2" 2>/dev/null) || return 1
        printf '%s\n' "$snapshot" | awk -v table="$1" '
            function splitrule(line, args, i,c,value,quote,escaped,n,present,sq) {
                sq=sprintf("%c",39); value=""; quote=""; escaped=0; n=0; present=0
                for(i=1;i<=length(line);i++) {
                    c=substr(line,i,1)
                    if(escaped) {value=value c; escaped=0; present=1; continue}
                    if(c=="\\" && quote!=sq) {escaped=1; present=1; continue}
                    if(quote!="") {if(c==quote) quote=""; else value=value c; present=1; continue}
                    if(c=="\"" || c==sq) {quote=c; present=1; continue}
                    if(c ~ /[[:space:]]/) {if(present) args[++n]=value; value=""; present=0; continue}
                    value=value c; present=1
                }
                if(present) args[++n]=value
                return n
            }
            $1=="-A" {
                number++; owned=0; n=splitrule($0,a)
                for(key in fields) delete fields[key]
                for(i=3;i<n;i+=2) fields[a[i]]=a[i+1]
                if(a[2]=="PREROUTING" && n==8 && fields["-i"]=="br0" && fields["-d"]=="198.19.0.0/16") {
                    if(table=="nat" && fields["-j"]=="ACCEPT") owned=1
                    if(table=="mangle" && fields["-j"]=="CGPT_QUIC") owned=1
                }
                if(table=="filter" && a[2]=="FORWARD") {
                    if(n==14 && fields["-i"]=="br0" && fields["-o"]=="mcquic" && fields["-d"]=="198.19.0.0/16" && fields["-m"]=="mark" && fields["--mark"]=="0x234/0xffff" && fields["-j"]=="ACCEPT") owned=1
                    if(n==12 && fields["-i"]=="mcquic" && fields["-o"]=="br0" && fields["-s"]=="198.19.0.0/16" && fields["-d"] ~ /^[0-9.]+\/[0-9]+$/ && fields["-j"]=="ACCEPT") owned=1
                    if(n==12 && fields["-i"]=="br0" && fields["-o"] ~ /^[A-Za-z0-9_.:-]+$/ && fields["-d"]=="198.19.0.0/16" && fields["-j"]=="REJECT" && fields["--reject-with"]=="icmp-port-unreachable") owned=1
                }
                if(owned) print number
            }
        '
    }
    for table in mangle nat filter; do
        chain=PREROUTING
        [ "$table" != filter ] || chain=FORWARD
        numbers=$(mc_ai_rule_numbers "$table" "$chain") || { rc=1; continue; }
        printf '%s\n' "$numbers" | sort -rn | while IFS= read -r number; do
            [ -n "$number" ] || continue
            iptables -t "$table" -D "$chain" "$number" >/dev/null 2>&1 || return 1
        done || rc=1
        numbers=$(mc_ai_rule_numbers "$table" "$chain") || { rc=1; continue; }
        [ -z "$numbers" ] || rc=1
    done
    iptables -t mangle -F CGPT_QUIC 2>/dev/null || true
    iptables -t mangle -X CGPT_QUIC 2>/dev/null || true
    snapshot=$(ip rule show 2>/dev/null) || { rc=1; snapshot=; }
    if printf '%s\n' "$snapshot" | awk '
        $1=="100:" {
            source=0; marked=0; table=0
            # Selector values may themselves be keywords, such as iif fwmark.
            for(i=2;i<NF;i++) {
                if($i=="from" && $(i+1)=="all") source=1
                if($i=="fwmark" && $(i+1)=="0x234/0xffff") marked=1
                if($i=="lookup" && $(i+1)=="234") table=1
            }
            if(source && marked && table) {
                if(NF==7 && $2=="from" && $4=="fwmark" && $6=="lookup") owned=1
                else conflict=1
            }
        }
        END {exit(owned && conflict ? 1 : 0)}
    '; then
        records=$(printf '%s\n' "$snapshot" | awk '
            NF==7 && $1=="100:" && $2=="from" && $3=="all" && $4=="fwmark" && $5=="0x234/0xffff" && $6=="lookup" && $7=="234" {print 100}
        ')
        for number in $records; do
            ip rule del priority 100 from all fwmark 0x234/0xffff lookup 234 2>/dev/null || { rc=1; break; }
        done
    else rc=1
    fi
    snapshot=$(ip rule show 2>/dev/null) || rc=1
    printf '%s\n' "$snapshot" | awk '
        NF==7 && $1=="100:" && $2=="from" && $3=="all" && $4=="fwmark" && $5=="0x234/0xffff" && $6=="lookup" && $7=="234" {found=1}
        END {exit(found ? 0 : 1)}
    ' && rc=1
    # Only our tunnel default is active ownership. Auxiliary LAN and user
    # routes remain harmless without our policy, and must not be flushed.
    snapshot=$(ip route show table 234 2>/dev/null) || { rc=1; snapshot=; }
    if printf '%s\n' "$snapshot" | grep -Eq '^default dev mcquic([[:space:]]|$)'; then
        ip route del default dev mcquic table 234 2>/dev/null || rc=1
    fi
    snapshot=$(ip route show table 234 2>/dev/null) || rc=1
    printf '%s\n' "$snapshot" | grep -Eq '^default dev mcquic([[:space:]]|$)' && rc=1
    return "$rc"
}
mc_recover_profile_stage() (
    # Retain every original until the full restore finishes, so it can retry.
    stage=$1 name= haduse= hadbak= use= bak= custom= links=
    hascustom=0 haslinks=0 hadcustom=0 hadlinks=0 hadcustomdir=1
    [ -d "$stage" ] && [ ! -L "$stage" ] || exit 1
    [ -f "$stage/name" ] && [ ! -L "$stage/name" ] || exit 1
    name=$(cat "$stage/name")
    mc_valid_name "$name" || exit 1
    for marker in haduse hadbak; do
        [ -f "$stage/$marker" ] && [ ! -L "$stage/$marker" ] || exit 1
    done
    haduse=$(cat "$stage/haduse"); hadbak=$(cat "$stage/hadbak")
    case "$haduse:$hadbak" in 0:0|0:1|1:0|1:1) ;; *) exit 1 ;; esac
    if [ -e "$stage/version" ] || [ -L "$stage/version" ]; then
        [ -f "$stage/version" ] && [ ! -L "$stage/version" ] &&
            [ "$(cat "$stage/version")" = 2 ] || exit 1
        for marker in hascustom haslinks hadcustom hadcustomdir hadlinks; do
            [ -f "$stage/$marker" ] && [ ! -L "$stage/$marker" ] || exit 1
        done
        hascustom=$(cat "$stage/hascustom"); haslinks=$(cat "$stage/haslinks")
        hadcustom=$(cat "$stage/hadcustom"); hadcustomdir=$(cat "$stage/hadcustomdir")
        hadlinks=$(cat "$stage/hadlinks")
        case "$hascustom:$haslinks" in 0:0|0:1|1:0|1:1) ;; *) exit 1 ;; esac
        case "$hadcustom:$hadcustomdir" in 0:0|0:1|1:1) ;; *) exit 1 ;; esac
        case "$hadlinks" in 0|1) ;; *) exit 1 ;; esac
        [ "$hascustom" = 1 ] || [ "$hadcustom:$hadcustomdir" = 0:1 ] || exit 1
        [ "$haslinks" = 1 ] || [ "$hadlinks" = 0 ] || exit 1
    else
        # Legacy journals contain only the pair. Partial new metadata must not
        # be mistaken for that format and silently omit sidecar recovery.
        for marker in hascustom haslinks hadcustom hadcustomdir hadlinks; do
            [ ! -e "$stage/$marker" ] && [ ! -L "$stage/$marker" ] || exit 1
        done
    fi
    if [ -e "$stage/committed" ] || [ -L "$stage/committed" ]; then
        [ -f "$stage/committed" ] && [ ! -L "$stage/committed" ] &&
            [ "$(cat "$stage/committed")" = 1 ] || exit 1
        rm -rf "$stage"
        exit $?
    fi
    use="$MC_ROOT/yaml_use/$name.yaml"; bak="$MC_ROOT/yaml_bak/$name.yaml"
    for directory in "$MC_ROOT/yaml_use" "$MC_ROOT/yaml_bak"; do
        [ -d "$directory" ] && [ ! -L "$directory" ] || exit 1
    done
    [ ! -L "$use" ] && [ ! -L "$bak" ] || exit 1
    custom_dir="$MC_ROOT/yaml_bak/$name"
    custom="$custom_dir/Custom.yaml"; links="$MC_ROOT/yaml_bak/$name.dlinks"
    if [ "$hascustom" = 1 ]; then
        [ ! -L "$custom_dir" ] && [ ! -L "$custom" ] || exit 1
        [ ! -e "$custom_dir" ] || [ -d "$custom_dir" ] || exit 1
        [ "$hadcustomdir" != 1 ] || [ -d "$custom_dir" ] || exit 1
        [ "$hadcustom" != 1 ] || { [ -f "$stage/custom.old" ] && [ ! -L "$stage/custom.old" ]; } || exit 1
    fi
    [ "$haslinks" != 1 ] || { [ ! -L "$links" ] &&
        { [ "$hadlinks" != 1 ] || { [ -f "$stage/links.old" ] && [ ! -L "$stage/links.old" ]; }; }; } || exit 1
    if [ "$hadbak" = 1 ]; then
        [ -f "$stage/bak.old" ] && [ ! -L "$stage/bak.old" ] &&
            cp -p "$stage/bak.old" "$stage/bak.restore" &&
            cmp -s "$stage/bak.old" "$stage/bak.restore" &&
            mv -f "$stage/bak.restore" "$bak" || exit 1
    else
        rm -f "$bak" || exit 1
    fi
    if [ "$haduse" = 1 ]; then
        [ -f "$stage/use.old" ] && [ ! -L "$stage/use.old" ] &&
            cp -p "$stage/use.old" "$stage/use.restore" &&
            cmp -s "$stage/use.old" "$stage/use.restore" &&
            mv -f "$stage/use.restore" "$use" || exit 1
    else
        rm -f "$use" || exit 1
    fi
    if [ "$hascustom" = 1 ]; then
        if [ "$hadcustom" = 1 ]; then
            cp -p "$stage/custom.old" "$stage/custom.restore" &&
                cmp -s "$stage/custom.old" "$stage/custom.restore" &&
                mv -f "$stage/custom.restore" "$custom" || exit 1
        else
            rm -f "$custom" || exit 1
        fi
        if [ "$hadcustomdir" = 0 ] && [ -d "$custom_dir" ]; then
            # Never remove unrelated files that appeared in this directory.
            rmdir "$custom_dir" || exit 1
        fi
    fi
    if [ "$haslinks" = 1 ]; then
        if [ "$hadlinks" = 1 ]; then
            cp -p "$stage/links.old" "$stage/links.restore" &&
                cmp -s "$stage/links.old" "$stage/links.restore" &&
                mv -f "$stage/links.restore" "$links" || exit 1
        else
            rm -f "$links" || exit 1
        fi
    fi
    sync || exit 1
    rm -rf "$stage"
)
mc_recover_profiles() {
    local stage
    for stage in "$MC_ROOT"/.profile.*; do
        # No name journal means publication has not begun; leave preparation
        # debris untouched. The name itself must never be a symlink.
        [ -e "$stage/name" ] || [ -L "$stage/name" ] || continue
        mc_recover_profile_stage "$stage" || {
            printf 'Profile recovery files retained at %s\n' "$stage" >&2
            return 1
        }
    done
}
mc_atomic_profile() (
    # A child owns the publication traps, preserving every caller's cleanup.
    # Keep transaction state in this isolated shell through its EXIT trap.
    [ "$#" -ge 2 ] || exit 1
    name=$1 input=$2 stage= use= bak= haduse=0 hadbak=0
    custom_source= links_source= hascustom=0 haslinks=0
    hadcustom=0 hadlinks=0 hadcustomdir=1
    shift 2
    while [ "$#" -gt 0 ]; do
        [ "$#" -ge 2 ] || exit 1
        case "$1" in
        --custom) [ "$hascustom" = 0 ] && [ -s "$2" ] && [ -f "$2" ] && [ ! -L "$2" ] || exit 1
            hascustom=1; custom_source=$2 ;;
        --dlinks) [ "$haslinks" = 0 ] && [ -f "$2" ] && [ ! -L "$2" ] || exit 1
            haslinks=1; links_source=$2 ;;
        *) exit 1 ;;
        esac
        shift 2
    done
    mc_profile_finish() {
        local status=$? failed=0
        trap - EXIT HUP INT TERM
        if [ -n "$stage" ]; then
            if [ -e "$stage/name" ] || [ -L "$stage/name" ]; then
                mc_recover_profile_stage "$stage" || failed=1
            else
                rm -rf "$stage" || failed=1
            fi
        fi
        if [ "$failed" = 1 ]; then
            printf 'Profile rollback files retained at %s\n' "$stage" >&2
            status=1
        fi
        exit "$status"
    }
    trap 'mc_profile_finish' EXIT
    trap 'exit 143' HUP INT TERM
    mc_valid_name "$name" && [ -s "$input" ] || exit 1
    stage=$(mc_mktemp -d "$MC_ROOT/.profile.XXXXXX") || exit 1
    use="$MC_ROOT/yaml_use/$name.yaml"; bak="$MC_ROOT/yaml_bak/$name.yaml"
    for directory in "$MC_ROOT/yaml_use" "$MC_ROOT/yaml_bak"; do
        [ -d "$directory" ] && [ ! -L "$directory" ] || exit 1
    done
    [ ! -L "$use" ] && [ ! -L "$bak" ] || exit 1
    custom_dir="$MC_ROOT/yaml_bak/$name"
    custom="$custom_dir/Custom.yaml"; links="$MC_ROOT/yaml_bak/$name.dlinks"
    # Sidecar destinations are fixed by the validated name, never caller paths.
    if [ "$hascustom" = 1 ]; then
        [ ! -L "$custom_dir" ] && [ ! -L "$custom" ] || exit 1
        if [ -e "$custom_dir" ]; then [ -d "$custom_dir" ] || exit 1; else hadcustomdir=0; fi
        if [ -e "$custom" ]; then
            [ -f "$custom" ] && cp -p "$custom" "$stage/custom.old" &&
                cmp -s "$custom" "$stage/custom.old" && cp -p "$stage/custom.old" "$stage/custom.new" &&
                cat "$custom_source" > "$stage/custom.new" || exit 1
            hadcustom=1
        else
            cp -p "$custom_source" "$stage/custom.new" || exit 1
        fi
    fi
    if [ "$haslinks" = 1 ]; then
        [ ! -L "$links" ] || exit 1
        if [ -e "$links" ]; then
            [ -f "$links" ] && cp -p "$links" "$stage/links.old" &&
                cmp -s "$links" "$stage/links.old" && cp -p "$stage/links.old" "$stage/links.new" &&
                cat "$links_source" > "$stage/links.new" || exit 1
            hadlinks=1
        else
            cp -p "$links_source" "$stage/links.new" || exit 1
        fi
    fi
    cp "$input" "$stage/use.new" || exit 1
    if [ "$hascustom" = 1 ]; then
        # The final provider pointer must name our fixed destination. Validate
        # its private new contents without changing the live provider first.
        [ "$(yq e -r '.proxy-providers.Custom.type // ""' "$stage/use.new" 2>/dev/null)" = file ] &&
            [ "$(yq e -r '.proxy-providers.Custom.path // ""' "$stage/use.new" 2>/dev/null)" = "./yaml_bak/$name/Custom.yaml" ] || exit 1
        CUSTOM_PATH="$stage/custom.new" yq e '.proxy-providers.Custom.path = strenv(CUSTOM_PATH)' "$stage/use.new" > "$stage/validate.yaml" || exit 1
        mc_validate_yaml "$stage/validate.yaml" || exit 1
    else
        mc_validate_yaml "$stage/use.new" || exit 1
    fi
    cp "$stage/use.new" "$stage/bak.new" && cmp -s "$stage/use.new" "$stage/bak.new" || exit 1
    if [ -e "$use" ]; then
        cp -p "$use" "$stage/use.old" && cmp -s "$use" "$stage/use.old" || exit 1
        haduse=1
    fi
    if [ -e "$bak" ]; then
        cp -p "$bak" "$stage/bak.old" && cmp -s "$bak" "$stage/bak.old" || exit 1
        hadbak=1
    fi
    chmod 600 "$stage/use.new" "$stage/bak.new" || exit 1
    printf '2\n' > "$stage/version" &&
        printf '%s\n' "$hascustom" > "$stage/hascustom" &&
        printf '%s\n' "$haslinks" > "$stage/haslinks" &&
        printf '%s\n' "$hadcustom" > "$stage/hadcustom" &&
        printf '%s\n' "$hadcustomdir" > "$stage/hadcustomdir" &&
        printf '%s\n' "$hadlinks" > "$stage/hadlinks" &&
        printf '%s\n' "$haduse" > "$stage/haduse" &&
        printf '%s\n' "$hadbak" > "$stage/hadbak" &&
        printf '%s\n' "$name" > "$stage/name.tmp" &&
        mv -f "$stage/name.tmp" "$stage/name" && sync || exit 1
    # Every destination, including a new provider directory, is protected by
    # the same durable journal and one commit boundary before publication.
    if [ "$hascustom" = 1 ]; then
        [ "$hadcustomdir" != 0 ] || mkdir "$custom_dir" || exit 1
        mv -f "$stage/custom.new" "$custom" || exit 1
    fi
    [ "$haslinks" != 1 ] || mv -f "$stage/links.new" "$links" || exit 1
    mv -f "$stage/bak.new" "$bak" || exit 1
    mv -f "$stage/use.new" "$use" || exit 1
    # Flush the complete profile/provider/link set before the commit marker.
    sync && printf '1\n' > "$stage/committed.tmp" &&
        mv -f "$stage/committed.tmp" "$stage/committed" && sync || exit 1
    exit 0
)
mc_retire_supervisors() {
    # Match the executable script argument, never arbitrary process name text.
    local p args
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        args=$(tr '\000' '\n' < "$p/cmdline" 2>/dev/null)
        printf '%s\n' "$args" | grep -qx '/tmp/clash_dog.sh' && kill "${p##*/}" 2>/dev/null
    done
    return 0
}
