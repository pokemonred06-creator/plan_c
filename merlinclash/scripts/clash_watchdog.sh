#!/bin/sh
PATH=/jffs/softcenter/bin:/jffs/softcenter/scripts:/usr/sbin:/sbin:/bin:/usr/bin
. /jffs/softcenter/scripts/clash_safe.sh
LOG=/tmp/clash_watchdog.log
log() {
    [ ! -f "$LOG" ] || [ "$(wc -c < "$LOG")" -lt 65536 ] || mv "$LOG" "$LOG.old"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}
mc_off_needs_cleanup() {
    [ -z "$(mc_core_pids)" ] || return 0
    mc_owned_state_present
}
if [ "${1:-}" != --check ]; then
    if [ "$(dbus get merlinclash_enable)" != 1 ] && [ "$(dbus get merlinclash_recovery_wanted)" != 1 ]; then
        ! mc_off_needs_cleanup || exec sh /jffs/softcenter/scripts/clash_config.sh watchdog stop
        exit 0
    fi
fi
watchdog_profile() {
    # A selected profile can be pending Apply while another profile is serving.
    if [ -n "$(mc_core_pids)" ]; then mc_active_name; else mc_selected; fi
}
NAME=$(watchdog_profile) || exit 1
CFG="$MC_ROOT/yaml_use/$NAME.yaml"
listens() {
    local protocol="$1" port="$2" pid="$3" options
    case "$protocol" in tcp) options=-lnpt;; udp) options=-lnup;; *) return 1;; esac
    netstat "$options" 2>/dev/null | awk -v protocol="$protocol" -v port="$port" -v pid="$pid" '
        $1 ~ ("^" protocol) && $4 ~ ("[:.]" port "$") {
            split($NF,owner,"/")
            if(owner[1]==pid) found=1
        }
        END {exit !found}
    '
}
healthy() {
    local p args active dnsport dns_enabled redir control secret
    set -- $(mc_core_pids)
    [ "$#" = 1 ] || return 1
    p=$1
    active=$(tr '\000' '\n' < "/proc/$p/cmdline" | awk 'found {print; exit} $0=="-f" {found=1}')
    [ "$(readlink -f "$active")" = "$(readlink -f "$CFG")" ] || return 1
    control=$(yq e -r '.external-controller // ""' "$CFG")
    redir=$(yq e -r '.redir-port // 0' "$CFG")
    case "$redir:${control##*:}" in *[!0-9:]*) return 1 ;; esac
    listens tcp "${control##*:}" "$p" || return 1
    dns_enabled=$(yq e '.dns.enable // false' "$CFG") || return 1
    case "$dns_enabled" in
        true)
            dnsport=$(yq e -r '.dns.listen // ""' "$CFG") || return 1
            dnsport=${dnsport##*:}
            case "$dnsport" in ''|*[!0-9]*) return 1 ;; esac
            listens tcp "$dnsport" "$p" && listens udp "$dnsport" "$p" || return 1
            ;;
        false) ;;
        *) return 1;;
    esac
    [ "$redir" = 0 ] || listens tcp "$redir" "$p" || return 1
    case "$control" in 0.0.0.0:*) control="127.0.0.1:${control##*:}" ;; :*) control="127.0.0.1$control" ;; esac
    secret=$(yq e -r '.secret // ""' "$CFG")
    mc_curl --noproxy '*' -fsS --connect-timeout 2 --max-time 4 -H "Authorization: Bearer $secret" "http://$control/version" 2>/dev/null | jq -e '.version | type == "string"' >/dev/null || return 1
    if [ "$(yq e '.tun.enable // false' "$CFG")" = true ]; then
        local dev
        dev=$(yq e -r '.tun.device // "Meta"' "$CFG")
        ip link show "$dev" >/dev/null 2>&1 || return 1
    fi
}
routed() {
    mc_ai_profile "$CFG" || return 0
    local wan_if
    wan_if=$(nvram get wan0_ifname)
    ip route show table 234 | grep -q '^default dev mcquic' || return 1
    ip rule show | grep -q '100:.*fwmark 0x234/0xffff.*lookup 234' || return 1
    iptables -t mangle -C CGPT_QUIC -j MARK --set-xmark 0x234/0xffff 2>/dev/null || return 1
    iptables -t mangle -C CGPT_QUIC -j ACCEPT 2>/dev/null || return 1
    iptables -t mangle -C PREROUTING -i br0 -d 198.19.0.0/16 -j CGPT_QUIC 2>/dev/null || return 1
    iptables -t nat -C PREROUTING -i br0 -d 198.19.0.0/16 -j ACCEPT 2>/dev/null || return 1
    iptables -C FORWARD -i br0 -o mcquic -d 198.19.0.0/16 -m mark --mark 0x234/0xffff -j ACCEPT 2>/dev/null || return 1
    local lan_cidr
    lan_cidr=$(ip route show dev br0 | awk '$1 ~ /\// && $1 != "default" {print $1; exit}')
    [ -n "$lan_cidr" ] || return 1
    ip route show table 234 | grep -Fq "$lan_cidr dev br0" || return 1
    iptables -C FORWARD -i mcquic -o br0 -s 198.19.0.0/16 -d "$lan_cidr" -j ACCEPT 2>/dev/null || return 1
    iptables -C FORWARD -i br0 -o "$wan_if" -d 198.19.0.0/16 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null
}
if [ "${1:-}" = --check ]; then healthy && routed; exit $?; fi
if [ "$(dbus get merlinclash_enable)" != 1 ] && [ "$(dbus get merlinclash_recovery_wanted)" != 1 ]; then
    # Off may arrive after the entry check but before mutex acquisition.
    ! mc_off_needs_cleanup || exec sh /jffs/softcenter/scripts/clash_config.sh watchdog stop
    exit 0
fi
MC_STOP_TOKEN=$(dbus get merlinclash_stop_token)
mc_lock
lock_status=$?
if [ "$lock_status" != 0 ]; then
    sleep 2
    mc_lock
    lock_status=$?
fi
if [ "$lock_status" != 0 ]; then
    if [ "$(dbus get merlinclash_stop_token)" != "$MC_STOP_TOKEN" ] ||
       { [ "$(dbus get merlinclash_enable)" != 1 ] && [ "$(dbus get merlinclash_recovery_wanted)" != 1 ]; }; then
        # Recovery may fail before the normal cleanup trap is installed. Off
        # still gets its mutex and cleanup without altering the retained journal.
        mc_lock --cleanup-only || exit $?
        sh /jffs/softcenter/scripts/clash_config.sh watchdog stop >> "$LOG" 2>&1
        lock_status=$?
        mc_unlock
    fi
    exit "$lock_status"
fi
finish() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ "$(dbus get merlinclash_stop_token)" != "$MC_STOP_TOKEN" ] ||
       { [ "$(dbus get merlinclash_enable)" != 1 ] && [ "$(dbus get merlinclash_recovery_wanted)" != 1 ]; }; then
        # A UI stop can lose the lock race. Complete it while this owner still
        # holds the inherited lifecycle mutex, including a late health-check Off.
        sh /jffs/softcenter/scripts/clash_config.sh watchdog stop >> "$LOG" 2>&1 || status=1
    fi
    mc_unlock
    exit "$status"
}
trap finish EXIT
NAME=$(watchdog_profile) || exit 1
CFG="$MC_ROOT/yaml_use/$NAME.yaml"
trap 'exit 1' HUP INT TERM
# A dead writer releases the advisory lock, even after SIGKILL.
dbus set merlinclash_maintenance=0
[ "$(dbus get merlinclash_enable)" = 1 ] || [ "$(dbus get merlinclash_recovery_wanted)" = 1 ] || exit 0
if healthy; then
    if ! routed; then
        log 'Repairing AI-only routes'
        /jffs/scripts/chatgpt-http3.sh >> "$LOG" 2>&1 || exit 1
    fi
    if routed; then
        dbus set merlinclash_recovery_wanted=0
        rm -f /tmp/clash-recovery-last
        exit 0
    fi
fi
now=$(date +%s); last=$(cat /tmp/clash-recovery-last 2>/dev/null)
case "$last" in ''|*[!0-9]*) last=0 ;; esac
[ $((now-last)) -ge 180 ] || exit 1
printf '%s\n' "$now" > /tmp/clash-recovery-last
# The verified core may have exited during health checks; only then does the
# pending selection become the recovery source. Capture once for the controller.
NAME=$(watchdog_profile) || exit 1
CFG="$MC_ROOT/yaml_use/$NAME.yaml"
log "Recovering profile $NAME through the checked controller"
MC_REQUEST_PROFILE="$NAME" sh /jffs/softcenter/scripts/clash_config.sh recovery restart >/tmp/clash_watchdog_restart.log 2>&1 || { log 'Recovery failed; last working profile retained'; exit 1; }
healthy && routed || { log 'Recovery completed but health check failed'; exit 1; }
log 'Recovery verified'
