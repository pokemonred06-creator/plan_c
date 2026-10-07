#!/bin/sh

. /jffs/softcenter/scripts/base.sh
. /jffs/softcenter/scripts/clash_safe.sh
alias echo_date='echo 【$(date +%Y年%m月%d日\ %X)】:'
LOG_FILE=/tmp/upload/merlinclash_log.txt

# 通用函数定义
detect_domain() {
    printf '%s\n' "$1" | awk '
    length($0)>253 || $0 !~ /\./ || $0 ~ /[^A-Za-z0-9.-]/ || $0 ~ /^[0-9.]+$/ { exit 1 }
    { n=split($0,a,"."); for(i=1;i<=n;i++) if(length(a[i])<1||length(a[i])>63||a[i]!~/^[A-Za-z0-9]/||a[i]!~/[A-Za-z0-9]$/)exit 1 }'
}

detect_ip() {
    IPADDR=$1
    # Count expanded 16-bit groups, allowing exactly one :: compression and a
    # final IPv4 tail (two groups). Prefixes and every octet/group are bounded.
    result=$(printf '%s\n' "$IPADDR" | awk '
    function ipv4(s, a,n,i) {
        n=split(s,a,"."); if(n!=4)return 0
        for(i=1;i<=4;i++)if(a[i]!~/^[0-9]+$/||length(a[i])>3||a[i]+0>255||
            (length(a[i])>1&&substr(a[i],1,1)=="0"))return 0
        return 1
    }
    function groups(s, a,n,i,count) {
        if(s=="")return 0
        n=split(s,a,":"); count=0
        for(i=1;i<=n;i++) {
            if(a[i]=="")return -99
            if(index(a[i],".")) { if(i!=n||!ipv4(a[i]))return -99; count+=2 }
            else { if(length(a[i])>4||a[i]!~/^[0-9A-Fa-f]+$/)return -99; count++ }
        }
        return count
    }
    {
        n=split($0,p,"/"); if(n>2||p[1]=="")exit
        if(n==2&&p[2]!~/^[0-9]+$/)exit
        if(!index(p[1],":")) { if(ipv4(p[1])&&(n==1||p[2]+0<=32))print 4; exit }
        if(n==2&&p[2]+0>128)exit
        pos=index(p[1],"::")
        if(pos) {
            left=substr(p[1],1,pos-1); right=substr(p[1],pos+2)
            if(index(right,"::")||index(left,"."))exit
            a=groups(left); b=groups(right)
            if(a>=0&&b>=0&&a+b<8)print 6
        } else if(groups(p[1])==8)print 6
    }')
    case "$result" in 4) return 4 ;; 6) return 6 ;; *) return 1 ;; esac
}

# Prepare complete replacement sets and DNS records before publishing any change.
ipset_signal() {
    # Defer interruption during publication until the successful step is recorded.
    # This closes the child-command/flag window needed for accurate rollback.
    if [ "$ipset_commit_phase" = 1 ]; then ipset_interrupted=1; else exit 1; fi
}
ipset_cleanup() {
    rollback_failed=0
    if [ "$ipset_committed" != 1 ]; then
        [ "$swapped6" != 1 ] || ipset swap "$set6" "$ipset_name_v6" || rollback_failed=1
        [ "$swapped4" != 1 ] || ipset swap "$set4" "$ipset_name_v4" || rollback_failed=1
        if [ "$conf_changed" = 1 ]; then
            if [ "$had_conf" = 1 ]; then mv -f "$IPSET_TMP/conf.old" "$conf_file" || rollback_failed=1
            else rm -f "$conf_file" || rollback_failed=1; fi
        fi
        if [ "$dns_changed" = 1 ]; then
            case "$had_dns" in
                link) ln -sf "$old_dns_link" "$dnsmasq_conf" || rollback_failed=1 ;;
                file) mv -f "$IPSET_TMP/dns.old" "$dnsmasq_conf" || rollback_failed=1 ;;
                *) rm -f "$dnsmasq_conf" || rollback_failed=1 ;;
            esac
        fi
    fi
    if [ "$rollback_failed" = 0 ]; then
        [ "$created4" != 1 ] || ipset destroy "$set4" >/dev/null 2>&1
        [ "$created6" != 1 ] || ipset destroy "$set6" >/dev/null 2>&1
        [ -z "$conf_stage" ] || rm -f "$conf_stage"
        [ -z "$IPSET_TMP" ] || rm -rf "$IPSET_TMP"
    else
        echo "IPset rollback incomplete; recovery files retained at $IPSET_TMP" >> "$LOG_FILE"
    fi
    mc_unlock
}
process_ipset_list() {
    config_type=$1; ipset_group=$2
    config_file="/jffs/softcenter/merlinclash/yaml_basic/$config_type.yaml"
    conf_file="/jffs/softcenter/merlinclash/conf/$config_type.conf"
    dnsmasq_conf="/tmp/etc/dnsmasq.user/$config_type.conf"
    ipset_name_v4="ipset_$ipset_group"; ipset_name_v6="ipset_${ipset_group}6"
    set4="mc4_$$"; set6="mc6_$$"
    mc_lock || return 1
    IPSET_TMP=$(mc_mktemp -d /tmp/clash-ipset.XXXXXX) || { mc_unlock; return 1; }
    trap 'ipset_cleanup' EXIT
    trap 'ipset_signal' HUP INT TERM
    if [ -e "$config_file" ]; then cp "$config_file" "$IPSET_TMP/list" || return 1
    else : > "$IPSET_TMP/list" || return 1; fi
    had_conf=0; had_dns=none
    if [ -e "$conf_file" ]; then cp -p "$conf_file" "$IPSET_TMP/conf.old" || return 1; had_conf=1; fi
    if [ -L "$dnsmasq_conf" ]; then old_dns_link=$(readlink "$dnsmasq_conf") || return 1; had_dns=link
    elif [ -e "$dnsmasq_conf" ]; then cp -p "$dnsmasq_conf" "$IPSET_TMP/dns.old" || return 1; had_dns=file; fi
    conf_stage=$(mc_mktemp "${conf_file}.XXXXXX") || return 1
    ipset create "$set4" hash:net family inet || return 1
    created4=1
    ipset create "$set6" hash:net family inet6 || return 1
    created6=1
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$line" in ''|\#*) continue ;; esac
        detect_ip "$line"; ip_type=$?
        case "$ip_type" in
            4) ipset -! add "$set4" "$line" || return 1 ;;
            6) ipset -! add "$set6" "$line" || return 1 ;;
            *)
                if detect_domain "$line"; then
                    printf 'ipset=/.%s/%s,%s\n' "$line" "$ipset_name_v4" "$ipset_name_v6" >> "$conf_stage" || return 1
                else
                    echo "Invalid address/domain skipped: $line" >> "$LOG_FILE"
                fi
                ;;
        esac
    done < "$IPSET_TMP/list"
    ipset_commit_phase=1
    ipset_interrupted=0
    ipset swap "$set4" "$ipset_name_v4" || return 1
    swapped4=1
    [ "$ipset_interrupted" = 0 ] || return 1
    ipset swap "$set6" "$ipset_name_v6" || return 1
    swapped6=1
    [ "$ipset_interrupted" = 0 ] || return 1
    mv -f "$conf_stage" "$conf_file" || return 1
    conf_changed=1
    [ "$ipset_interrupted" = 0 ] || return 1
    dns_changed=1
    ln -sf "$conf_file" "$dnsmasq_conf" || return 1
    [ "$ipset_interrupted" = 0 ] || return 1
    ipset_committed=1
    ipset_commit_phase=0
}
case "$2" in
    ipsetproxy) process_ipset_list ipsetproxy proxy || exit 1 ;;
    ipsetproxyarround) process_ipset_list ipsetproxyarround proxyarround || exit 1 ;;
esac
