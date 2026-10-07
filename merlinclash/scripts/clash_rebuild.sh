#!/bin/sh
. /jffs/softcenter/scripts/base.sh
. /jffs/softcenter/scripts/clash_safe.sh
LOG_FILE=/tmp/upload/merlinclash_log.txt

restart_dnsmasq() {
    # Firmware regenerates its own resolver settings. Retain unrelated DNS files.
    service restart_dnsmasq >/dev/null 2>&1 || return 1
    dns_procs=0
    dnsmasqpid=$(pidof dnsmasq)
    for d in $dnsmasqpid; do dns_procs=$((dns_procs + 1)); done
    if [ "$dns_procs" -gt 1 ]; then service restart_dnsmasq >/dev/null 2>&1 || return 1; fi
}
prepare_dnsmasq() {
    # Remove only the plugin-owned symlink, retaining unrelated firmware hooks.
    if [ "$(readlink /jffs/scripts/dnsmasq.postconf)" = /jffs/softcenter/merlinclash/conf/dnsmasq.postconf ]; then
        rm -f /jffs/scripts/dnsmasq.postconf || return 1
    fi
}
start_rebuild() {
    root=/jffs/softcenter/merlinclash/yaml_bak
    list=$(mc_mktemp "$root/.yamls.XXXXXX") || return 1
    for profile in "$root"/*.yaml; do
        [ -f "$profile" ] || continue
        name=${profile##*/}; name=${name%.yaml}
        mc_valid_name "$name" && printf '%s\n' "$name"
    done > "$list"
    mv -f "$list" "$root/yamls.txt" && ln -sf "$root/yamls.txt" /tmp/upload/yamls.txt || { rm -f "$list"; return 1; }
}
start_hot_off() {
    sh /jffs/softcenter/scripts/clash_config.sh stop stop
}
start_cool_off() {
    sh /jffs/softcenter/scripts/clash_config.sh stop stop || return 1
    prepare_dnsmasq || return 1
    restart_dnsmasq || return 1
    echo 'Magic Catling disabled; router restarting in five seconds' >> "$LOG_FILE"
    mc_unlock
    sleep 5
    reboot
}
case "$2" in rebuild|hot_off_mc|cool_off_mc) ;; *) exit 1 ;; esac
mc_lock || exit 75
trap 'mc_unlock' EXIT
trap 'exit 1' HUP INT TERM
mkdir -p /tmp/upload || exit 1
http_response "$1"
case "$2" in
    rebuild) start_rebuild || exit 1 ;;
    hot_off_mc) start_hot_off || exit 1 ;;
    cool_off_mc) start_cool_off || exit 1 ;;
esac
echo BBABBBBC >> "$LOG_FILE"
