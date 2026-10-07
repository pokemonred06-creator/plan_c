#!/bin/sh
. /jffs/softcenter/scripts/base.sh
. /jffs/softcenter/scripts/clash_update_safe.sh
LOG_FILE=/tmp/upload/merlinclash_log.txt

main() {
    [ "$2" = 12 ] || return 0
    mc_update_begin || return 1
    http_response "$1"
    binary_type=$(dbus get merlinclash_binary_type)
    case "$binary_type" in clash|subconverter) ;; *) mc_update_log 'Unsupported uploaded binary type.'; return 1 ;; esac
    upload_file=/tmp/upload/$binary_type
    [ -f "$upload_file" ] && [ ! -L "$upload_file" ] && [ -s "$upload_file" ] || return 1
    # Manual upload is an explicit trusted binary supplied by the user. Make a
    # private snapshot before validation; the destination is never the upload.
    cp "$upload_file" "$MC_UPDATE_TMP/uploaded" || return 1
    case "$binary_type" in
        clash) mc_update_core "$MC_UPDATE_TMP/uploaded" ;;
        subconverter) mc_update_subconverter "$MC_UPDATE_TMP/uploaded" ;;
    esac
}
main "$@"
status=$?
printf '%s\n' BBABBBBC >> "$LOG_FILE"
exit "$status"
