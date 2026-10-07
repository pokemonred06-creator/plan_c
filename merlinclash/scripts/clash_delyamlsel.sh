#!/bin/sh
. /jffs/softcenter/scripts/base.sh
. /jffs/softcenter/scripts/clash_safe.sh
LOG_FILE=/tmp/upload/merlinclash_log.txt

delete_profile() {
    yamlname=$(dbus get merlinclash_set_yamlsel_edit)
    mc_valid_name "$yamlname" || { echo 'Invalid profile name' >> "$LOG_FILE"; return 1; }
    mc_lock || return 1
    trap 'mc_unlock' EXIT
    trap 'exit 1' HUP INT TERM
    selected=$(dbus get merlinclash_set_yamlsel_start)
    legacy_selected=$(dbus get merlinclash_yamlsel)
    active=$(mc_active_name) || active=
    if [ "$yamlname" = "$selected" ] || [ "$yamlname" = "$legacy_selected" ] || [ "$yamlname" = "$active" ]; then
        echo 'Select another profile before deleting this profile' >> "$LOG_FILE"
        return 1
    fi
    root=/jffs/softcenter/merlinclash
    # Remove only exact validated profile paths, never an empty directory prefix.
    rm -f "$root/yaml_use/$yamlname.yaml" "$root/yaml_bak/$yamlname.yaml" \
        "$root/yaml_bak/$yamlname.dlinks" "$root/rule_bak/${yamlname}_rules.yaml" \
        "$root/rule_custom/${yamlname}_custom_rule.yaml" "$root/mark/$yamlname.txt" \
        "/tmp/clash/mark/clash_web_save_${yamlname}.txt" || return 1
    rm -rf "$root/yaml_bak/$yamlname" || return 1
    list=$(mc_mktemp "$root/yaml_bak/.yamls.XXXXXX") || return 1
    for profile in "$root"/yaml_bak/*.yaml; do
        [ -f "$profile" ] || continue
        profile=${profile##*/}; profile=${profile%.yaml}
        mc_valid_name "$profile" && printf '%s\n' "$profile"
    done > "$list"
    mv -f "$list" "$root/yaml_bak/yamls.txt" || { rm -f "$list"; return 1; }
    ln -sf "$root/yaml_bak/yamls.txt" /tmp/upload/yamls.txt || return 1
}
case "$2" in
    0)
        http_response "$1"
        if delete_profile; then http_response success; else http_response failed; exit 1; fi
        echo BBABBBBC >> "$LOG_FILE"
        ;;
esac
