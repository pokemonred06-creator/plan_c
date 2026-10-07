#!/bin/sh
# Mirror the owned LAN DNS capture into TCP with the same interface/ACL scope.
umask 077
. /jffs/softcenter/scripts/base.sh || exit 1
. /jffs/softcenter/scripts/clash_safe.sh || exit 1
STOP_TOKEN=$(dbus get merlinclash_stop_token)
mc_lock || exit $?
WORK=
finish() {
    status=$?
    trap - EXIT HUP INT TERM
    [ -z "$WORK" ] || rm -f "$WORK" "$WORK.tcp"
    if [ "$(dbus get merlinclash_stop_token)" != "$STOP_TOKEN" ] ||
       { [ "$(dbus get merlinclash_enable)" != 1 ] && [ "$(dbus get merlinclash_recovery_wanted)" != 1 ]; }; then
        [ -z "$(mc_core_pids)" ] || sh /jffs/softcenter/scripts/clash_config.sh dns stop >/dev/null 2>&1 || status=1
    fi
    mc_unlock
    exit "$status"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
enabled() {
    [ "$(dbus get merlinclash_stop_token)" = "$STOP_TOKEN" ] &&
    [ "$(dbus get merlinclash_enable)" = 1 ] &&
    [ "$(dbus get merlinclash_ipt_closeproxy_sw)" != 1 ] &&
    [ -n "$(mc_core_pids)" ]
}
enabled || exit 0
# The controller owns creation of the target chain and its payload.
iptables -t nat -C merlinclash_DNS53 -p tcp -j REDIRECT --to-ports 53 2>/dev/null || exit 0
WORK=$(mc_mktemp /tmp/merlinclash-dns-tcp.XXXXXX) || exit 1
iptables -t nat -S PREROUTING > "$WORK" || exit 1
awk '
    $1=="-A" && $2=="PREROUTING" && $NF=="merlinclash_DNS53" {
        udp=0; dns=0
        for(i=3;i<NF;i++) {
            if($i=="-p" && $(i+1)=="udp") udp=1
            if($i=="--dport" && $(i+1)=="53") dns=1
        }
        if(udp && dns) print
    }
' "$WORK" | sed 's/ -p udp / -p tcp /g;s/ -m udp / -m tcp /g' > "$WORK.tcp" || exit 1
mv -f "$WORK.tcp" "$WORK" || exit 1
set -f
while IFS= read -r rule; do
    enabled || exit 0
    set -- $rule
    shift 2
    iptables -t nat -C PREROUTING "$@" 2>/dev/null ||
        iptables -t nat -I PREROUTING 1 "$@" || exit 1
done < "$WORK"
