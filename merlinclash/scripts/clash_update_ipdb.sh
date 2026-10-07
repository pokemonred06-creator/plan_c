#!/bin/sh
. /jffs/softcenter/scripts/base.sh
. /jffs/softcenter/scripts/clash_update_safe.sh
LOG_FILE=/tmp/upload/merlinclash_log.txt

validate_geodat() {
    # V2Ray GeoIP/GeoSite are repeated length-delimited protobuf messages.
    # This rejects text/error pages before invoking the actual consumer parser.
    _geo_header=$(od -An -tx1 -N1 "$1" | tr -d ' \n')
    [ "$_geo_header" = 0a ] || return 1
    _geo_dir=$MC_UPDATE_TMP/validate-$2
    mkdir -p "$_geo_dir" || return 1
    case "$2" in
        GeoIP) _geo_rule='GEOIP,CN,DIRECT' ;;
        GeoSite) _geo_rule='GEOSITE,CN,DIRECT' ;;
        *) return 1 ;;
    esac
    ln -s "$1" "$_geo_dir/$2.dat" || return 1
    printf '%s\n' 'mixed-port: 0' 'geodata-mode: true' 'geo-auto-update: false' 'rules:' "  - $_geo_rule" '  - MATCH,DIRECT' > "$_geo_dir/check.yaml" || return 1
    mc_update_run "$MC_SOFT/bin/clash" -t -d "$_geo_dir" -f "$_geo_dir/check.yaml"
}

update_geodat() {
    _geo_name=$1
    _geo_kind=$2
    _geo_dest=$MC_DATA/$_geo_kind.dat
    _geo_url=https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/$_geo_name
    _geo_file=$MC_UPDATE_TMP/$_geo_name
    mc_update_fetch "$_geo_url" "$_geo_file" || { mc_update_log "$_geo_kind download failed; existing database retained."; return 1; }
    # Use publisher SHA256 when the authenticated release API supplies one;
    # databases are still parsed by the core when upstream omits asset digests.
    if [ -f "$MC_UPDATE_TMP/geo-release.json" ]; then
        _geo_digest=$(jq -r --arg name "$_geo_name" '.assets[] | select(.name == $name) | .digest // empty' "$MC_UPDATE_TMP/geo-release.json") || return 1
        if [ -n "$_geo_digest" ]; then
            case "$_geo_digest" in sha256:*) _geo_digest=${_geo_digest#sha256:} ;; *) return 1 ;; esac
            mc_update_digest "$_geo_file" "$_geo_digest" || return 1
        fi
    fi
    validate_geodat "$_geo_file" "$_geo_kind" || { mc_update_log "$_geo_kind is not a valid database; existing database retained."; return 1; }
    if [ -f "$_geo_dest" ] && cmp -s "$_geo_file" "$_geo_dest"; then
        mc_update_log "$_geo_kind is already current."
        return 0
    fi
    mc_update_publish_data "$_geo_file" "$_geo_dest" || return 1
    mc_update_log "$_geo_kind validated and published; next core start loads the database."
}

main() {
    [ "$2" = 5 ] || return 0
    mc_update_begin || return 1
    http_response "$1"
    # A metadata outage does not prevent format-validated data updates over TLS.
    if ! mc_update_fetch https://api.github.com/repos/MetaCubeX/meta-rules-dat/releases/tags/latest "$MC_UPDATE_TMP/geo-release.json"; then
        rm -f "$MC_UPDATE_TMP/geo-release.json"
    fi
    status=0
    case "$(dbus get merlinclash_set_geoip_type)" in
        head) mc_update_log 'GeoIP follows the profile; manual update skipped.' ;;
        full) update_geodat geoip.dat GeoIP || status=1 ;;
        *) update_geodat geoip-lite.dat GeoIP || status=1 ;;
    esac
    case "$(dbus get merlinclash_set_geosite_type)" in
        head) mc_update_log 'GeoSite follows the profile; manual update skipped.' ;;
        full) update_geodat geosite.dat GeoSite || status=1 ;;
        *) update_geodat geosite-lite.dat GeoSite || status=1 ;;
    esac
    return "$status"
}
main "$@"
status=$?
printf '%s\n' BBABBBBC >> "$LOG_FILE"
exit "$status"
