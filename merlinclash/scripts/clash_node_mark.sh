#!/bin/sh
export PATH=/opt/bin:/opt/sbin:/jffs/softcenter/bin:/jffs/softcenter/scripts:$PATH
. /jffs/softcenter/scripts/base.sh
. /jffs/softcenter/scripts/clash_safe.sh
LOG_FILE=/tmp/upload/merlinclash_node_mark.log
mc_lock || exit 75
trap 'mc_unlock' EXIT
trap 'exit 1' HUP INT TERM
case "$1" in
    setmark)
        [ "$(dbus get merlinclash_enable)" = 1 ] || exit 0
        # UI selection can change before the old core is stopped. Attribute its
        # selectors to the actual running profile and use that profile's API.
        yamlname=$(mc_active_name) || exit 1
        ;;
    start_remark|remark)
        if [ "${MC_REQUEST_PROFILE+x}" = x ]; then yamlname=$MC_REQUEST_PROFILE
        else yamlname=$(mc_selected) || exit 1; fi
        ;;
    *) exit 1 ;;
esac
mc_valid_name "$yamlname" || exit 1
yamlpath="/jffs/softcenter/merlinclash/yaml_use/$yamlname.yaml"
secret=$(yq eval -r '.secret // ""' "$yamlpath" 2>/dev/null) || exit 1
ec=$(yq eval -r '.external-controller // ""' "$yamlpath" 2>/dev/null) || exit 1
ecport=${ec##*:}
case "$ecport" in ''|*[!0-9]*) exit 1 ;; esac
[ "$ecport" -gt 0 ] && [ "$ecport" -le 65535 ] || exit 1
lan_ipaddr=$(nvram get lan_ipaddr)
case "$lan_ipaddr" in ''|*[!0-9.]*) exit 1 ;; esac
controller_host=${ec%:*}
case "$controller_host" in 0.0.0.0|'[::]'|''|localhost) controller_host=127.0.0.1 ;; esac
printf '%s\n' "$controller_host" | grep -Eq '^[0-9a-fA-F:.]+$|^\[[0-9a-fA-F:]+\]$' || exit 1
case "$secret" in *'
'*|*"$(printf '\r')"*) exit 1 ;; esac
api="http://$controller_host:$ecport"
dirconf=/jffs/softcenter/merlinclash/mark
filename="$dirconf/$yamlname.txt"

api_get() {
    mc_curl -fsS --connect-timeout 2 --max-time 5 -H "Authorization: Bearer $secret" "$api/$1"
}
api_put() {
    code=$(mc_curl -sS --connect-timeout 2 --max-time 5 -o /dev/null -w '%{http_code}' \
        -X "$1" -H "Authorization: Bearer $secret" -H 'Content-Type: application/json' \
        --data "$3" "$api/$2") || return 1
    [ "$code" = 204 ]
}
mark_lock() {
    mkdir -p "$dirconf" || return 1
    # Selector records do not mutate lifecycle state; use their own stable lock inode.
    exec 8>"/tmp/clash-mark-$yamlname.lock" || return 1
    flock -n 8 || return 1
    mark_tmp=$(mc_mktemp -d /tmp/clash-mark.XXXXXX) || return 1
    trap 'rm -rf "$mark_tmp"; [ -z "$mark_dst" ] || rm -f "$mark_dst"; flock -u 8; mc_unlock' EXIT
    trap 'exit 1' HUP INT TERM
}
setmark() {
    [ "$(dbus get merlinclash_enable)" = 1 ] || return 0
    [ -n "$(mc_core_pids)" ] || return 1
    mark_lock || return 1
    api_get proxies > "$mark_tmp/proxies" || return 1
    api_get configs > "$mark_tmp/configs" || return 1
    mode=$(jq -er '.mode | select(type == "string")' "$mark_tmp/configs") || return 1
    case "$mode" in rule|global|direct) ;; *) return 1 ;; esac
    jq -e --arg mode "$mode" '
        .proxies | select(type == "object") |
        {mark: map_values(select(.type == "Selector" and (.now | type == "string")) | {now}), config: {mode: $mode}}' "$mark_tmp/proxies" > "$mark_tmp/record" || return 1
    cmp -s "$mark_tmp/record" "$filename" && return 0
    mark_dst=$(mc_mktemp "${filename}.XXXXXX") || return 1
    cp "$mark_tmp/record" "$mark_dst" && chmod 600 "$mark_dst" && mv -f "$mark_dst" "$filename"
}
remark() {
    [ "$(dbus get merlinclash_enable)" = 1 ] || return 0
    [ -s "$filename" ] || return 0
    mark_lock || return 1
    jq -e '.mark | type == "object"' "$filename" >/dev/null || return 1
    i=0; ready=0
    while [ "$i" -lt 10 ]; do
        if api_get version > /dev/null; then ready=1; break; fi
        i=$((i + 1))
        [ "$i" -ge 10 ] || sleep 1
    done
    [ "$ready" = 1 ] || { echo 'Controller unavailable; selector restore deferred' >> "$LOG_FILE"; return 1; }
    api_get proxies > "$mark_tmp/current" || return 1
    jq -e '.proxies | type == "object"' "$mark_tmp/current" >/dev/null || return 1
    jq -c '.mark | to_entries[] | select(.value.now | type == "string")' "$filename" > "$mark_tmp/entries" || return 1
    failed=0
    while IFS= read -r line; do
        group_key=$(printf '%s\n' "$line" | jq -r '.key') || return 1
        # Automatic URLTest/Fallback/LoadBalance groups do not support selector PUT.
        # Old records may contain them or removed groups; leave their current state.
        jq -e --arg group "$group_key" '.proxies[$group].type == "Selector"' "$mark_tmp/current" >/dev/null || continue
        group_name=$(printf '%s\n' "$line" | jq -r '.key | @uri') || return 1
        now_name=$(printf '%s\n' "$line" | jq -r '.value.now') || return 1
        jq -e --arg group "$group_key" --arg name "$now_name" '
            .proxies[$group].all | if type == "array" then index($name) != null else true end
        ' "$mark_tmp/current" >/dev/null || continue
        payload=$(jq -nc --arg name "$now_name" '{name:$name}') || return 1
        if ! api_put PUT "proxies/$group_name" "$payload"; then
            echo 'A saved selector could not be restored' >> "$LOG_FILE"
            failed=1
        fi
    done < "$mark_tmp/entries"
    mode=$(jq -er '.config.mode | select(type == "string")' "$filename") || return 1
    case "$mode" in rule|global|direct) ;; *) return 1 ;; esac
    payload=$(jq -nc --arg mode "$mode" '{mode:$mode}') || return 1
    api_put PATCH configs "$payload" || failed=1
    [ "$failed" = 0 ] || return 1
    printf '###### %s ######\nBBABBBBC\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "/tmp/upload/${yamlname}_status.txt"
}
case "$1" in
    setmark) setmark ;;
    start_remark|remark) remark ;;
    *) exit 1 ;;
esac
