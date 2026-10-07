#!/bin/sh
. /jffs/softcenter/scripts/base.sh
. /jffs/softcenter/scripts/clash_safe.sh || exit 1
LOG_FILE=/tmp/upload/merlinclash_log.txt
MC_DIR=/jffs/softcenter/merlinclash
MC_WORK=
MC_STAGE=
MC_ROLLBACK=
MC_SWAPPED=0
MC_OLD_MOVED=0
MC_DB_CHANGED=0
MC_STOPPED=0
MC_DONE=0
MC_RUNNING=0
MC_CAPTURED_MARK_PROFILE=
MC_FORWARD_MARK_PROFILE=
umask 077

restart_requested() {
    [ "$(dbus get merlinclash_stop_token)" = "$MC_STOP_TOKEN" ] || return 1
    [ "$(dbus get merlinclash_enable)" = 1 ] || [ "$(dbus get merlinclash_recovery_wanted)" = 1 ]
}
restart_with_checkpoint() {
    local selected checkpoint=
    selected=$(mc_selected) || return 1
    [ "$1" != "$selected" ] || checkpoint="$1"
    MC_FRESH_MARK_PROFILE="$checkpoint" sh /jffs/softcenter/scripts/clash_config.sh recovery restart
}
cleanup_off_state() {
    local token
    restart_requested && return 0
    token=$(dbus get merlinclash_stop_token)
    if [ -n "$(mc_core_pids)" ] || mc_owned_state_present ||
       { [ "$token" != "$MC_STOP_TOKEN" ] && [ "$token" != "${MC_OFF_CLEANED_TOKEN:-}" ] &&
         { [ "$(dbus get merlinclash_enable)" = 1 ] || [ "$(dbus get merlinclash_recovery_wanted)" = 1 ]; }; }; then
        sh /jffs/softcenter/scripts/clash_config.sh stop stop >/dev/null 2>&1 || return 1
        [ -z "$(mc_core_pids)" ] && ! mc_owned_state_present || return 1
        MC_OFF_CLEANED_TOKEN=$(dbus get merlinclash_stop_token)
    fi
    return 0
}
log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
check_backup() {
    for category in set yaml acl db rule dns; do
        [ "$(dbus get merlinclash_bak_$category)" != 1 ] || return 0
    done
    log '请至少开启一个备份/还原选项。'
    return 1
}
# No values from the archive are ever evaluated as shell text.
valid_record() {
    record_key=${1%%=*}
    [ "$record_key" != "$1" ] || return 1
    case "$record_key" in ''|*[!A-Za-z0-9_]*) return 1;; esac
    case "$2:$record_key" in
        set:merlinclash_set_*|set:merlinclash_ipt_*|set:merlinclash_select_*|yaml:merlinclash_sub_*|dns:merlinclash_dns_*|rule:merlinclash_acl_*|db:merlinclash_db_*|acl:merlinclash_nokpacl_*) return 0;;
    esac
    return 1
}
copy_optional() {
    [ -e "$1" ] || return 0
    cp -RL "$1" "$2"
}
export_category() {
    category=$1
    mkdir -p "$MC_WORK/clash_backup/$category" || return 1
    : > "$MC_WORK/clash_backup/$category/dbus.txt" || return 1
    case "$category" in
        set) prefixes='set_ ipt_ select_';;
        yaml) prefixes='sub_';;
        dns) prefixes='dns_';;
        rule) prefixes='acl_';;
        db) prefixes='db_';;
        acl) prefixes='nokpacl_';;
    esac
    for prefix in $prefixes; do
        dbus list "merlinclash_$prefix" >> "$MC_WORK/clash_backup/$category/dbus.txt" || return 1
    done
    dest="$MC_WORK/clash_backup/$category"
    case "$category" in
        set) copy_optional "$MC_DIR/yaml_basic/head.yaml" "$dest/" || return 1;;
        yaml)
            for entry in yaml_bak yaml_use mark; do copy_optional "$MC_DIR/$entry" "$dest/" || return 1; done;;
        dns)
            copy_optional "$MC_DIR/yaml_dns" "$dest/" || return 1
            for entry in sniffer.yaml hosts.yaml; do copy_optional "$MC_DIR/yaml_basic/$entry" "$dest/" || return 1; done;;
        rule)
            copy_optional "$MC_DIR/rule_custom" "$dest/" || return 1
            for entry in ipsetproxyarround.yaml ipsetproxy.yaml; do copy_optional "$MC_DIR/yaml_basic/$entry" "$dest/" || return 1; done;;
        db)
            for entry in ChinaIPv6.yaml ChinaIP.yaml; do copy_optional "$MC_DIR/yaml_basic/$entry" "$dest/" || return 1; done
            for entry in "$MC_DIR"/*.dat "$MC_DIR"/*.mmdb "$MC_DIR"/*.db; do copy_optional "$entry" "$dest/" || return 1; done;;
    esac
}
restore_records() {
    file=$1
    [ -f "$file" ] || return 0
    while IFS= read -r record || [ -n "$record" ]; do
        [ -n "$record" ] || continue
        case "${record%%=*}" in merlinclash_enable|merlinclash_recovery_wanted|merlinclash_stop_token) continue;; esac
        dbus set "$record" || return 1
    done < "$file"
}
clear_restore_keys() {
    [ -f "$MC_WORK/restore-keys" ] || return 0
    while IFS= read -r key; do dbus remove "$key" || return 1; done < "$MC_WORK/restore-keys"
}
finish() {
    status=$?
    off_cleanup_ok=1
    trap - EXIT HUP INT TERM
    if [ "$MC_DONE" != 1 ]; then
        if [ "$MC_SWAPPED" = 1 ]; then
            sh /jffs/softcenter/scripts/clash_config.sh maintenance stop >/dev/null 2>&1 || status=1
            # Preserve the rejected tree for diagnosis until the old tree is back.
            mv "$MC_DIR" "$MC_STAGE" && mv "$MC_ROLLBACK" "$MC_DIR" || {
                log "还原失败，回滚目录保留在 $MC_ROLLBACK。"; status=1;
            }
        elif [ "$MC_OLD_MOVED" = 1 ]; then
            mv "$MC_ROLLBACK" "$MC_DIR" || status=1
        fi
        if [ "$MC_DB_CHANGED" = 1 ]; then
            clear_restore_keys && restore_records "$MC_WORK/old-dbus" || status=1
        fi
        if [ "$MC_STOPPED" = 1 ]; then
            if [ "$MC_RUNNING" = 1 ] && restart_requested; then
                restart_with_checkpoint "$MC_CAPTURED_MARK_PROFILE" >/dev/null 2>&1 || { restart_requested && status=1; }
            fi
        fi
    fi
    cleanup_off_state || { status=1; off_cleanup_ok=0; }
    [ -z "$MC_WORK" ] || rm -rf "$MC_WORK"
    [ -z "$MC_STAGE" ] || rm -rf "$MC_STAGE"
    if [ "$MC_DONE" = 1 ] && [ "$off_cleanup_ok" = 1 ] && [ -n "$MC_ROLLBACK" ]; then rm -rf "$MC_ROLLBACK"; fi
    [ "$off_cleanup_ok" = 1 ] || log "Off cleanup failed; rollback retained at $MC_ROLLBACK."
    mc_unlock
    log BBABBBBC
    exit "$status"
}
archive_check() {
    archive=$1
    tar -tzf "$archive" > "$MC_WORK/members" || return 1
    tar -tvzf "$archive" > "$MC_WORK/types" || return 1
    # Reject links/devices and path ambiguity before tar can write anything.
    awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END {exit bad}' "$MC_WORK/types" || return 1
    [ -s "$MC_WORK/members" ] || return 1
    while IFS= read -r member; do
        member=${member#./}
        case "$member" in
            ''|/*|*'//'*) return 1;;
        esac
        case "/$member/" in */../*|*/./*) return 1;; esac
        case "$member" in *[!A-Za-z0-9_./-]*) return 1;; esac
        case "$member" in
            clash_backup|clash_backup/|clash_backup/version|clash_backup/set/*|clash_backup/yaml/*|clash_backup/dns/*|clash_backup/rule/*|clash_backup/db/*|clash_backup/acl/*) ;;
            *) return 1;;
        esac
    done < "$MC_WORK/members"
}
preflight_restore() {
    archive=/tmp/upload/mc_backup.tar.gz
    archive_check "$archive" || { log '备份压缩包不完整或包含不安全路径。'; return 1; }
    inflated=$(gzip -dc "$archive" | wc -c | awk '{print $1}')
    tmp_free=$(df -Pk /tmp | awk 'END {print $4}')
    case "$inflated:$tmp_free" in *[!0-9:]*|:*|*:) return 1;; esac
    [ "$inflated" -lt "$((tmp_free * 1024 - 4194304))" ] || { log '临时空间不足。'; return 1; }
    tar -xzf "$archive" -C "$MC_WORK" || return 1
    [ "$(cat "$MC_WORK/clash_backup/version" 2>/dev/null)" = 1.0 ] || { log '不支持的备份版本。'; return 1; }
    : > "$MC_WORK/restore-keys" || return 1
    for category in set yaml dns rule db acl; do
        file="$MC_WORK/clash_backup/$category/dbus.txt"
        [ ! -f "$file" ] || while IFS= read -r record || [ -n "$record" ]; do
            [ -n "$record" ] || continue
            valid_record "$record" "$category" || return 1
            if [ "$(dbus get merlinclash_bak_$category)" = 1 ]; then printf '%s\n' "${record%%=*}" >> "$MC_WORK/restore-keys" || return 1; fi
        done < "$file"
    done
    # Flash must hold the old working tree plus the full staged replacement.
    free=$(df -Pk /jffs/softcenter | awk 'END {print $4}')
    old_size=$(du -sk "$MC_DIR" | awk '{print $1}')
    add_size=$(du -sk "$MC_WORK/clash_backup" | awk '{print $1}')
    case "$free:$old_size:$add_size" in *[!0-9:]*|::*|:*|*:) return 1;; esac
    [ "$free" -gt "$((old_size + add_size + 4096))" ] || { log '空间不足，原设置保持不变。'; return 1; }
    MC_STAGE=$(mc_mktemp -d /jffs/softcenter/.mc-restore.XXXXXX) || return 1
    cp -pRL "$MC_DIR/." "$MC_STAGE/" || return 1
    for category in set yaml dns rule db acl; do
        [ "$(dbus get merlinclash_bak_$category)" = 1 ] || continue
        src="$MC_WORK/clash_backup/$category"
        [ -d "$src" ] || continue
        case "$category" in
            set) copy_optional "$src/head.yaml" "$MC_STAGE/yaml_basic/" || return 1;;
            yaml) for entry in yaml_bak yaml_use mark; do copy_optional "$src/$entry" "$MC_STAGE/" || return 1; done;;
            dns)
                copy_optional "$src/yaml_dns" "$MC_STAGE/" || return 1
                for entry in sniffer.yaml hosts.yaml; do copy_optional "$src/$entry" "$MC_STAGE/yaml_basic/" || return 1; done;;
            rule)
                copy_optional "$src/rule_custom" "$MC_STAGE/" || return 1
                for entry in ipsetproxyarround.yaml ipsetproxy.yaml; do copy_optional "$src/$entry" "$MC_STAGE/yaml_basic/" || return 1; done;;
            db)
                for entry in ChinaIPv6.yaml ChinaIP.yaml; do copy_optional "$src/$entry" "$MC_STAGE/yaml_basic/" || return 1; done
                for entry in "$src"/*.dat "$src"/*.mmdb "$src"/*.db; do copy_optional "$entry" "$MC_STAGE/" || return 1; done;;
        esac
    done
    # Check all restored complete profiles and all YAML fragments before stopping.
    find "$MC_STAGE/yaml_bak" "$MC_STAGE/yaml_use" -name '*.yaml' > "$MC_WORK/configs" || return 1
    while IFS= read -r file; do mc_validate_yaml "$file" || return 1; done < "$MC_WORK/configs"
    find "$MC_STAGE/yaml_basic" "$MC_STAGE/yaml_dns" "$MC_STAGE/rule_custom" -name '*.yaml' > "$MC_WORK/fragments" 2>/dev/null
    while IFS= read -r file; do /jffs/softcenter/bin/yq eval '.' "$file" >/dev/null 2>&1 || return 1; done < "$MC_WORK/fragments"
    selected=$(dbus get merlinclash_set_yamlsel_start)
    legacy_selected=$(dbus get merlinclash_yamlsel)
    if [ "$(dbus get merlinclash_bak_set)" = 1 ] && [ -f "$MC_WORK/clash_backup/set/dbus.txt" ]; then
        while IFS= read -r record || [ -n "$record" ]; do
            case "$record" in merlinclash_set_yamlsel_start=*) selected=${record#*=};; esac
        done < "$MC_WORK/clash_backup/set/dbus.txt"
    fi
    [ -n "$selected" ] || selected=$legacy_selected
    if [ -n "$selected" ]; then
        mc_valid_name "$selected" || return 1
        mc_validate_yaml "$MC_STAGE/yaml_bak/$selected.yaml" || return 1
    elif [ "$MC_RUNNING" = 1 ]; then
        return 1
    fi
    dbus list merlinclash_ > "$MC_WORK/old-dbus" || return 1
    MC_ROLLBACK="${MC_STAGE}.old"
    [ ! -e "$MC_ROLLBACK" ] || return 1
}
restore_run() {
    preflight_restore || return 1
    if [ "$MC_RUNNING" = 1 ]; then
        [ -f /jffs/softcenter/scripts/clash_node_mark.sh ] || return 1
        snapshot_profile=$(mc_active_name) && mc_valid_name "$snapshot_profile" || return 1
        sh /jffs/softcenter/scripts/clash_node_mark.sh setmark >/dev/null 2>&1 || return 1
        [ "$(dbus get merlinclash_stop_token)" = "$MC_STOP_TOKEN" ] || return 1
        if [ "$(dbus get merlinclash_enable)" = 1 ]; then
            [ "$(mc_active_name)" = "$snapshot_profile" ] || return 1
            MC_CAPTURED_MARK_PROFILE="$snapshot_profile"
        fi
        # The old tree becomes rollback below. Preserve fresh live choices in the
        # new tree unless this restore explicitly supplied archived choices.
        if [ "$(dbus get merlinclash_bak_yaml)" != 1 ] || [ ! -d "$MC_WORK/clash_backup/yaml/mark" ]; then
            copy_optional "$MC_DIR/mark" "$MC_STAGE/" || return 1
            MC_FORWARD_MARK_PROFILE="$MC_CAPTURED_MARK_PROFILE"
        fi
        MC_STOPPED=1
        sh /jffs/softcenter/scripts/clash_config.sh maintenance stop >/dev/null 2>&1 || return 1
    fi
    mv "$MC_DIR" "$MC_ROLLBACK" || return 1
    MC_OLD_MOVED=1
    mv "$MC_STAGE" "$MC_DIR" || return 1
    MC_SWAPPED=1
    MC_DB_CHANGED=1
    for category in set yaml dns rule db acl; do
        [ "$(dbus get merlinclash_bak_$category)" = 1 ] || continue
        file="$MC_WORK/clash_backup/$category/dbus.txt"
        restore_records "$file" || return 1
    done
    # An explicitly restored selected-profile record is an operation checkpoint,
    # even when native cache is enabled. Incidental older disk marks are not.
    archive_profile=$(mc_selected) || archive_profile=
    archive_mark="$MC_WORK/clash_backup/yaml/mark/$archive_profile.txt"
    if [ -n "$archive_profile" ] && [ "$(dbus get merlinclash_bak_yaml)" = 1 ] && [ -s "$archive_mark" ] &&
       cmp -s "$archive_mark" "$MC_DIR/mark/$archive_profile.txt" &&
       jq -e '(.mark | type == "object") and
           all(.mark[]; (type == "object") and (.now | type == "string")) and
           (.config.mode == "rule" or .config.mode == "global" or .config.mode == "direct")' "$archive_mark" >/dev/null 2>&1; then
        MC_FORWARD_MARK_PROFILE="$archive_profile"
    fi
    if [ "$MC_RUNNING" = 1 ] && restart_requested; then
        restart_with_checkpoint "$MC_FORWARD_MARK_PROFILE" >/dev/null 2>&1 || { restart_requested && return 1; }
        if restart_requested; then
            sh /jffs/softcenter/scripts/clash_watchdog.sh --check >/dev/null 2>&1 || return 1
        fi
    fi
    cleanup_off_state || return 1
    MC_DONE=1
    log '还原完成。'
}
backup_conf() {
    mkdir -p "$MC_WORK/clash_backup" || return 1
    printf '1.0\n' > "$MC_WORK/clash_backup/version" || return 1
    for category in set yaml dns rule db acl; do
        [ "$(dbus get merlinclash_bak_$category)" != 1 ] || export_category "$category" || return 1
    done
    tar -czf "$MC_WORK/mc_backup.tar.gz" -C "$MC_WORK" clash_backup || return 1
    [ -s "$MC_WORK/mc_backup.tar.gz" ] || return 1
    archive_check "$MC_WORK/mc_backup.tar.gz" || return 1
    mv "$MC_WORK/mc_backup.tar.gz" /tmp/upload/mc_backup.tar.gz || return 1
    cleanup_off_state || return 1
    MC_DONE=1
    log '备份完成。'
}
case "$2" in backup|restore) ;; *) exit 1;; esac
mkdir -p /tmp/upload || exit 1
printf '%s\n' '开始备份/还原' > "$LOG_FILE" || exit 1
http_response "$1"
check_backup || { log BBABBBBC; exit 1; }
mc_lock || { log BBABBBBC; exit 1; }
MC_STOP_TOKEN=$(dbus get merlinclash_stop_token)
MC_RUNNING=0
[ -z "$(mc_core_pids)" ] || MC_RUNNING=1
MC_WORK=$(mc_mktemp -d /tmp/mc-backup.XXXXXX) || { mc_unlock; exit 1; }
trap finish EXIT
trap 'exit 1' HUP INT TERM
case "$2" in
    backup) backup_conf || exit 1;;
    restore) [ -f /tmp/upload/mc_backup.tar.gz ] && restore_run || exit 1;;
esac
