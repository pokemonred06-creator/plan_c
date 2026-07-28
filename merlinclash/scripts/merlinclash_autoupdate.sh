#!/bin/sh
PATH=/jffs/softcenter/bin:/usr/sbin:/sbin:/bin:/usr/bin:/opt/bin:/opt/sbin
LOG=/jffs/softcenter/merlinclash/autoupdate.log
DEBUG=/tmp/autoupdate_debug.log
API="https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha"
CURL_CMD="/usr/sbin/curl"
# Prefer Entware curl if available (works better in cron)
if [ -x /opt/bin/curl ]; then
  CURL_CMD="/opt/bin/curl"
fi
UPDATED=0
WAS_RUNNING=0
MAX_RETRIES=3

# Wait for network to be ready
sleep 15

stamp() { TZ=UTC-8 date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "$(stamp) $1" >> "$LOG"; }

set_version() {
  cmd=$1; key=$2; label=$3; shift 3
  ver=$(LD_LIBRARY_PATH=/jffs/softcenter/bin "$cmd" "$@" 2>/dev/null | head -n 1)
  if [ -n "$ver" ]; then
    dbus set "$key"="$ver"
    log "set $label version -> $ver"
  else
    log "WARN: $label returned empty version"
  fi
}

current_clash_version() {
  /jffs/softcenter/bin/clash -v 2>/dev/null | head -n 1 | awk '{print $3}'
}

clash_running() {
  if pidof clash >/dev/null 2>&1; then return 0; fi
  ps | grep "[c]lash" >/dev/null 2>&1
}

disable_watchdog() {
  sed -i "/clash_watchdog/d" /var/spool/cron/crontabs/* >/dev/null 2>&1
}

restart_clash() {
  if [ -x /jffs/softcenter/merlinclash/clashconfig.sh ]; then
    log "restarting via clashconfig.sh restart"
    sh /jffs/softcenter/scripts/fix_merlinclash_ports.sh >/dev/null 2>&1
    sh /jffs/softcenter/merlinclash/clashconfig.sh restart
    return 0
  fi
  log "WARN: no restart script found"
}

update_clash() {
  cur=$(current_clash_version)
  
  echo "$(stamp) DEBUG: Starting update check" >> "$DEBUG"
  
  i=0
  url=""
  while [ $i -lt $MAX_RETRIES ]; do
      # Use HTTP (redirects to HTTPS) with -L to follow redirects
      $CURL_CMD -Lks -o /tmp/api_response.json "http://api.github.com/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha" 2>/dev/null
      raw_size=$(wc -c < /tmp/api_response.json 2>/dev/null || echo "0")
      echo "$(stamp) DEBUG: curl used: $CURL_CMD, returned $raw_size bytes" >> "$DEBUG"
      
      url=$(grep -o 'https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/mihomo-linux-armv7-[^"]*\.gz' /tmp/api_response.json | head -n 1)
      echo "$(stamp) DEBUG: grep result: $url" >> "$DEBUG"
      
      if [ -n "$url" ]; then
          break
      fi
      log "WARN: failed to fetch asset URL or API error (attempt $((i+1))/$MAX_RETRIES), retrying in 30s..."
      sleep 30
      i=$((i+1))
  done

  rm -f /tmp/api_response.json

  if [ -z "$url" ]; then
    log "ERROR: no armv7 asset found after $MAX_RETRIES attempts"
    return 1
  fi

  newver=$(echo "$url" | sed 's/.*linux-armv7-//' | sed 's/\.gz.*//')
  
  if [ -n "$cur" ] && [ "$cur" = "$newver" ]; then
    log "clash already at $cur; skip download"
    return 0
  fi
  
  tmpdir=/tmp/mihomo.$$
  mkdir -p "$tmpdir" || return 1
  pkg="$tmpdir/mihomo.gz"
  
  j=0
  dl_success=0
  while [ $j -lt $MAX_RETRIES ]; do
      if $CURL_CMD -Lks -o "$pkg" "$url"; then
          dl_success=1
          break
      fi
      log "WARN: download failed (attempt $((j+1))/$MAX_RETRIES), retrying in 30s..."
      sleep 30
      j=$((j+1))
  done

  if [ $dl_success -eq 0 ]; then
    log "ERROR: download failed after $MAX_RETRIES attempts: $url"
    rm -rf "$tmpdir"
    return 1
  fi
  
  need=$(du -k "$pkg" | awk '{print $1}')
  avail=$(df -k /jffs | tail -n 1 | awk '{print $4}')
  if [ -n "$need" ] && [ -n "$avail" ] && [ "$avail" -lt "$need" ]; then
    log "WARN: not enough /jffs space (need ${need}K, avail ${avail}K)"
    rm -rf "$tmpdir"
    return 1
  fi
  
  if ! gunzip -c "$pkg" > "$tmpdir/clash"; then
    log "WARN: gunzip failed: $pkg"
    rm -rf "$tmpdir"
    return 1
  fi
  
  chmod 755 "$tmpdir/clash"
  
  if clash_running; then
    WAS_RUNNING=1
    log "stopping running clash before replace"
    disable_watchdog
    killall clash >/dev/null 2>&1
    sleep 1
  fi
  
  [ -x /jffs/softcenter/bin/clash ] && cp /jffs/softcenter/bin/clash /jffs/softcenter/bin/clash.bak 2>/dev/null
  mv "$tmpdir/clash" /jffs/softcenter/bin/clash
  log "clash updated to $newver from $url"
  UPDATED=1
  rm -rf "$tmpdir"
}

update_clash
set_version /jffs/softcenter/bin/clash merlinclash_clash_version clash -v
set_version /jffs/softcenter/bin/clash merlinclash_clash_version_tmp clash_tmp -v

ret=$(/jffs/softcenter/bin/clash -v 2>/dev/null | head -n 1)
ver=$(echo "$ret" | awk '{if ($2=="Meta") print $1" "$2" "$3; else print $1" "$2}')
[ -n "$ver" ] && dbus set merlinclash_binary_ver="$ver"

if [ "$UPDATED" = "1" ]; then
  if [ "$WAS_RUNNING" = "1" ]; then
    restart_clash
  else
    log "update applied; clash was not running, restart skipped"
  fi
else
  log "no update applied; restart skipped"
fi

log "merlinclash_autoupdate run completed"
