#!/bin/sh
PATH=/jffs/softcenter/bin:/usr/sbin:/sbin:/bin:/usr/bin:/opt/bin:/opt/sbin
export PATH
LOG_FILE=/jffs/softcenter/merlinclash/autoupdate.log
. /jffs/softcenter/scripts/clash_update_safe.sh
API=https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha

main() {
    # A removed installation must not be revived by a surviving registration.
    [ -x "$MC_SOFT/bin/clash" ] && [ -f "$MC_SOFT/scripts/clash_config.sh" ] || return 1
    mc_update_begin || return 1
    if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt 65536 ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.old" || return 1
    fi
    mc_update_fetch "$API" "$MC_UPDATE_TMP/release.json" || { mc_update_log 'Release discovery failed TLS/HTTP verification.'; return 1; }
    # GitHub digest is obtained through the authenticated release API. Never
    # execute an asset when the publisher/API does not supply its SHA256.
    jq -er '.assets | map(select(.name | test("^mihomo-linux-armv7-[A-Za-z0-9._-]+\\.gz$"))) | sort_by(.name) | .[0] | select(.digest | type == "string") | [.browser_download_url, .digest, .name] | @tsv' "$MC_UPDATE_TMP/release.json" > "$MC_UPDATE_TMP/asset" || {
        mc_update_log 'No authenticated armv7 asset digest is available; keeping the installed engine.'
        return 1
    }
    IFS="$(printf '\t')" read -r url digest asset < "$MC_UPDATE_TMP/asset" || return 1
    case "$url" in https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha/*) ;; *) return 1 ;; esac
    case "$digest" in sha256:*) digest=${digest#sha256:} ;; *) return 1 ;; esac
    mc_update_run "$MC_SOFT/bin/clash" -v || return 1
    _mc_current=$(head -n 1 "$MC_UPDATE_TMP/probe-output" | awk '{print $3}')
    _mc_release=${asset#mihomo-linux-armv7-}
    _mc_release=${_mc_release%.gz}
    if [ -n "$_mc_current" ] && [ "$_mc_current" = "$_mc_release" ]; then
        mc_update_log "Already using $_mc_current; replacement skipped."
        return 0
    fi
    mc_update_fetch "$url" "$MC_UPDATE_TMP/engine.gz" || return 1
    mc_update_digest "$MC_UPDATE_TMP/engine.gz" "$digest" || { mc_update_log 'Asset SHA256 verification failed; downloaded code was not executed.'; return 1; }
    _mc_compressed=$(wc -c < "$MC_UPDATE_TMP/engine.gz")
    [ "$_mc_compressed" -le 67108864 ] || { mc_update_log 'Engine package exceeds the supported size limit.'; return 1; }
    # Test and expand while the current engine is still running. Space is checked
    # against expanded size plus backup before any destination write or stop.
    gzip -t "$MC_UPDATE_TMP/engine.gz" || return 1
    # Bound extraction before the exact expanded-space check. Firmware shells
    # use 512-byte or KiB file-limit units; either bound fits this router.
    (ulimit -f 131072 || exit 1; gunzip -c "$MC_UPDATE_TMP/engine.gz" > "$MC_UPDATE_TMP/engine") || return 1
    mc_update_core "$MC_UPDATE_TMP/engine"
}
main
exit $?
