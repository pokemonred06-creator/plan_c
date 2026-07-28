#!/bin/sh
PATH=/jffs/softcenter/bin:/usr/sbin:/sbin:/bin:/usr/bin:/opt/bin:/opt/sbin
LOG=/tmp/clash_watchdog.log
stamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(stamp) $1" >> "$LOG"; }
get_dbus() { dbus get "$1" 2>/dev/null; }

fix_ports() {
  [ -x /jffs/softcenter/scripts/fix_merlinclash_ports.sh ] && sh /jffs/softcenter/scripts/fix_merlinclash_ports.sh >/dev/null 2>&1
}

healthy() {
  pidof clash >/dev/null 2>&1 || return 1
  netstat -tln 2>/dev/null | grep -q ':3333 ' || return 1
  return 0
}

sync_started() {
  PID=$(pidof clash | awk '{print $1}')
  [ -n "$PID" ] && dbus set merlinclash_pid="$PID" >/dev/null 2>&1
  dbus set merlinclash_status=started >/dev/null 2>&1
}

fail_open() {
  log "fail-open: removing MerlinClash redirect/tproxy rules because Clash is not healthy"
  # Prefer plugin stop path if available; it flushes MerlinClash NAT/mangle chains.
  if [ -x /jffs/softcenter/merlinclash/clashconfig.sh ]; then
    sh /jffs/softcenter/merlinclash/clashconfig.sh stop >/dev/null 2>&1
  fi
  # Defensive cleanup for leftover rules/chains. Ignore failures.
  iptables -t nat -D PREROUTING -p tcp -j merlinclash >/dev/null 2>&1
  iptables -t nat -D OUTPUT -j merlinclash_OUTPUT >/dev/null 2>&1
  iptables -t mangle -D PREROUTING -p udp -j merlinclash_divert >/dev/null 2>&1
  iptables -t mangle -D PREROUTING -p udp -j merlinclash_PREROUTING >/dev/null 2>&1
  iptables -t nat -F merlinclash >/dev/null 2>&1
  iptables -t nat -F merlinclash_CHN >/dev/null 2>&1
  iptables -t nat -F merlinclash_NOR >/dev/null 2>&1
  iptables -t nat -F merlinclash_EXT >/dev/null 2>&1
  iptables -t nat -F merlinclash_OUTPUT >/dev/null 2>&1
  iptables -t mangle -F merlinclash >/dev/null 2>&1
  iptables -t mangle -F merlinclash_PREROUTING >/dev/null 2>&1
  iptables -t mangle -F merlinclash_divert >/dev/null 2>&1
  dbus set merlinclash_status=stopped >/dev/null 2>&1
}

ENABLED=$(get_dbus merlinclash_enable)
[ "$ENABLED" = "1" ] || exit 0

if healthy; then
  sync_started
  exit 0
fi

log "Clash unhealthy/dead while enabled; attempting restart"
fix_ports
sh /jffs/softcenter/merlinclash/clashconfig.sh restart >/tmp/clash_watchdog_restart.log 2>&1 &
RPID=$!
sleep 25
if kill -0 "$RPID" 2>/dev/null; then
  log "restart script still running after 25s; killing restart script"
  kill "$RPID" >/dev/null 2>&1
fi
sleep 3
if healthy; then
  log "restart successful"
  sync_started
  exit 0
fi

log "restart failed; entering fail-open mode"
fail_open
exit 1
