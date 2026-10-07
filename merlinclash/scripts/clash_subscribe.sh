#!/bin/sh
. /jffs/softcenter/scripts/clash_base.sh
. /jffs/softcenter/scripts/clash_safe.sh
LOG_FILE=/tmp/upload/merlinclash_log.txt
fp=/jffs/softcenter/merlinclash/yaml_bak

# Preserve complete uploaded/downloaded profiles. DNS, TUN, controller and
# listeners are part of the profile and must not be removed by a field filter.
get_yaml_name() {
    subtype=$(dbus get merlinclash_sub_type)
    case "$subtype" in
        MCrule) _name=MC_; rule_file=rule_mc.yaml ;;
        MCrule_No) _name=MCN_; rule_file=rule_mc_noping.yaml ;;
        MCrule_Media) _name=MM_; rule_file=rule_mcmedia.yaml ;;
        MCrule_Media_No) _name=MMN_; rule_file=rule_mcmedia_noping.yaml ;;
        MCrule_Media_AreaU) _name=MMU_; rule_file=rule_mcmedia_area_urltest.yaml ;;
        MCrule_Media_AreaF) _name=MMF_; rule_file=rule_mcmedia_area_fallback.yaml ;;
        MCrule_Custom) _name=MCU_; rule_file=rule_mc_custom.yaml ;;
        APrule) _name=AP_; rule_file= ;;
        *) return 1 ;;
    esac
    rename=$(dbus get merlinclash_sub_rename)
    [ -n "$rename" ] || rename=$(date '+%Y%m%d-%H%M%S')
    subscribe_name="$_name$rename"
    mc_valid_name "$subscribe_name" || return 1
    rule_file="/jffs/softcenter/merlinclash/rule_configs/$rule_file"
}
get_settings() {
    UA=$(decode_url_link "$(dbus get merlinclash_sub_useragent)") || return 1
    include=$(decode_url_link "$(dbus get merlinclash_sub_include)") || return 1
    exclude=$(decode_url_link "$(dbus get merlinclash_sub_exclude)") || return 1
    cycle=$(dbus get merlinclash_sub_updatecycle)
    case "$cycle" in ''|*[!0-9]*) cycle=86400 ;; esac
    [ "$cycle" -gt 0 ] || return 1
}
yaml_upload() {
    uploadfilename=$(dbus get merlinclash_sub_upload_filename)
    mc_valid_name "$uploadfilename" || return 1
    case "$uploadfilename" in *.yaml) subscribe_name=${uploadfilename%.yaml} ;; *.yml) subscribe_name=${uploadfilename%.yml} ;; *) return 1 ;; esac
    mc_valid_name "$subscribe_name" || return 1
    [ -f "/tmp/upload/$uploadfilename" ] && [ ! -L "/tmp/upload/$uploadfilename" ] || return 1
    cp "/tmp/upload/$uploadfilename" "$SUB_TMP/profile.yaml"
}
yaml_download() {
    case "$merlinc_link" in http://*|https://*) ;; *) return 1 ;; esac
    download "$UA" "$merlinc_link" "$SUB_TMP/profile.yaml"
}
aprule_links() {
    printf '%s\n' "$1" | tr -d '\r\n' | tr '|' '\n' > "$SUB_TMP/links" || return 1
    merlinc_link=
    while IFS= read -r item || [ -n "$item" ]; do
        url=$(printf '%s\n' "$item" | sed 's/<[^>]*>//g;s/(.*//;s/[[:space:]]*$//;s/^[[:space:]]*//')
        case "$url" in http://*|https://*) merlinc_link=$url; break ;; esac
    done < "$SUB_TMP/links"
    [ -n "$merlinc_link" ]
}
process_http_link() {
    # Each URL must retain its own provider. Duplicate explicit or generated
    # names would otherwise replace an earlier dictionary entry silently.
    [ -f "$SUB_TMP/provider_names" ] || return 1
    if grep -Fqx -- "$2" "$SUB_TMP/provider_names"; then
        echo 'Subscription provider names must be unique' >&2
        return 1
    fi
    printf '%s\n' "$2" >> "$SUB_TMP/provider_names" || return 1
    PROVIDER_NAME=$2 PROVIDER_URL=$1 PROVIDER_PATH="./yaml_bak/$subscribe_name/AP$count.yaml" \
    PROVIDER_UA=$3 SUB_UA="$UA" SUB_INCLUDE="$include" SUB_EXCLUDE="$exclude" SUB_CYCLE="$cycle" \
    yq eval '
        .proxy-providers[strenv(PROVIDER_NAME)] = {
            "type":"http", "url":strenv(PROVIDER_URL), "path":strenv(PROVIDER_PATH),
            "interval":env(SUB_CYCLE), "proxy":"DIRECT",
            "override":{"additional-suffix":(" [" + strenv(PROVIDER_NAME) + "]")}
        }
        ' -i "$SUB_TMP/providers.yaml" || return 1
    # Supply user-controlled strings through environment values, not yq source.
    PROVIDER_NAME=$2 SUB_UA="$UA" SUB_INCLUDE="$include" SUB_EXCLUDE="$exclude" \
    yq eval '
        (select(strenv(SUB_INCLUDE) != "") | .proxy-providers[strenv(PROVIDER_NAME)].filter) = strenv(SUB_INCLUDE) |
        (select(strenv(SUB_EXCLUDE) != "") | .proxy-providers[strenv(PROVIDER_NAME)].exclude-filter) = strenv(SUB_EXCLUDE)
        ' -i "$SUB_TMP/providers.yaml" || return 1
    selected_ua=${3:-$UA}
    if [ -n "$selected_ua" ]; then
        PROVIDER_NAME=$2 SUB_UA="$selected_ua" yq eval '.proxy-providers[strenv(PROVIDER_NAME)].header.User-Agent = [strenv(SUB_UA)]' -i "$SUB_TMP/providers.yaml" || return 1
    fi
    for setting in scv udp tfo; do
        [ "$(dbus get "merlinclash_sub_$setting")" = 1 ] || continue
        case "$setting" in scv) field=skip-cert-verify ;; udp) field=udp ;; tfo) field=tfo ;; esac
        PROVIDER_NAME=$2 FIELD=$field yq eval '.proxy-providers[strenv(PROVIDER_NAME)].override[strenv(FIELD)] = true' -i "$SUB_TMP/providers.yaml" || return 1
    done
}
parse_and_process_urls() {
    printf '%s\n' "$1" | tr '|' '\n' > "$SUB_TMP/links" || return 1
    printf 'proxy-providers: {}\n' > "$SUB_TMP/providers.yaml" || return 1
    : > "$SUB_TMP/provider_names" || return 1
    count=0
    while IFS= read -r item || [ -n "$item" ]; do
        item=$(printf '%s\n' "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$item" ] || continue
        count=$((count + 1))
        provider_ua=$(printf '%s\n' "$item" | sed -n 's/.*<\([^>]*\)>.*/\1/p')
        name=$(printf '%s\n' "$item" | sed -n 's/.*(\([^)]*\)).*/\1/p')
        [ -n "$name" ] || name="AP$count"
        url=$(printf '%s\n' "$item" | sed 's/<[^>]*>//g;s/(.*)$//;s/[[:space:]]*$//')
        case "$url" in
            http://*|https://*) process_http_link "$url" "$name" "$provider_ua" || return 1 ;;
            [a-zA-Z0-9]*://*) printf '%s\n' "$url" >> "$SUB_TMP/Custom.yaml" || return 1 ;;
            *) return 1 ;;
        esac
    done < "$SUB_TMP/links"
    [ "$count" -gt 0 ]
}
yaml_merge() {
    [ -s "$rule_file" ] || return 1
    if [ -s "$SUB_TMP/Custom.yaml" ]; then
        # The raw-URI provider uses this fixed key. HTTP-only Custom remains
        # valid, but mixing both would discard the HTTP subscription.
        if grep -Fqx Custom "$SUB_TMP/provider_names"; then
            echo 'HTTP Custom provider conflicts with raw-URI subscription' >&2
            return 1
        fi
        CUSTOM_PATH="./yaml_bak/$subscribe_name/Custom.yaml" \
        yq eval '.proxy-providers.Custom = {"type":"file", "path":strenv(CUSTOM_PATH), "override":{"additional-suffix":" [Custom]"}}' -i "$SUB_TMP/providers.yaml" || return 1
        for setting in scv udp tfo; do
            [ "$(dbus get "merlinclash_sub_$setting")" = 1 ] || continue
            case "$setting" in scv) field=skip-cert-verify ;; udp) field=udp ;; tfo) field=tfo ;; esac
            FIELD=$field yq eval '.proxy-providers.Custom.override[strenv(FIELD)] = true' -i "$SUB_TMP/providers.yaml" || return 1
        done
    fi
    # Merge YAML objects with the validated rule template, avoiding duplicate keys.
    RULE_TEMPLATE="$rule_file" yq eval '. * load(strenv(RULE_TEMPLATE))' "$SUB_TMP/providers.yaml" > "$SUB_TMP/profile.yaml" || return 1
    if [ "$(dbus get merlinclash_sub_emoji)" = 1 ]; then
        # The installed emoji fragment contains anchors and is kept as a prefix.
        # A failed parser/anchor expansion will reject the candidate before publish.
        emoji=/jffs/softcenter/merlinclash/rule_configs/emoji.yaml
        [ -s "$emoji" ] || return 1
        yq eval '.proxy-providers.[].override.<< alias = "emoji_rename"' -i "$SUB_TMP/profile.yaml" || return 1
        cat "$emoji" "$SUB_TMP/profile.yaml" > "$SUB_TMP/emoji.yaml" || return 1
        mv -f "$SUB_TMP/emoji.yaml" "$SUB_TMP/profile.yaml" || return 1
    fi
}
yaml_prepare() {
    mc_valid_name "$subscribe_name" || return 1
    [ -s "$SUB_TMP/profile.yaml" ] || return 1
    yq eval '.' "$SUB_TMP/profile.yaml" >/dev/null || return 1
    # Validate and publish profiles plus staged provider/link files through one
    # durable journal. No sidecar can escape recovery after a killed importer.
    set -- "$subscribe_name" "$SUB_TMP/profile.yaml"
    [ ! -s "$SUB_TMP/Custom.yaml" ] || set -- "$@" --custom "$SUB_TMP/Custom.yaml"
    if [ "$_name" = AP_ ]; then
        printf '%s,%s,%s\n' "$cycle" "$subscribe_name" "$merlinc_link" > "$SUB_TMP/dlinks" || return 1
        set -- "$@" --dlinks "$SUB_TMP/dlinks"
    fi
    mc_atomic_profile "$@" || return 1
    list=$(mc_mktemp "$fp/.yamls.XXXXXX") || return 1
    for profile in "$fp"/*.yaml; do
        [ -f "$profile" ] || continue
        profile=${profile##*/}; profile=${profile%.yaml}
        mc_valid_name "$profile" && printf '%s\n' "$profile"
    done > "$list"
    mv -f "$list" "$fp/yamls.txt" && ln -sf "$fp/yamls.txt" /tmp/upload/yamls.txt || { rm -f "$list"; return 1; }
}
run_update() {
    if [ "$action" = cron ]; then subscribe_name=$(dbus get merlinclash_set_yamlsel_start)
    else subscribe_name=$(dbus get merlinclash_set_yamlsel_edit); fi
    mc_valid_name "$subscribe_name" || return 1
    yaml_dlinks_file="$fp/$subscribe_name.dlinks"
    [ -f "$yaml_dlinks_file" ] || return 1
    # Preserve commas inside subscription query values.
    merlinc_link=$(cut -d, -f3- "$yaml_dlinks_file" | sed -n '1p')
    yaml_download && yaml_prepare || return 1
    if [ "$subscribe_name" = "$(dbus get merlinclash_set_yamlsel_start)" ] && [ "$(dbus get merlinclash_enable)" = 1 ]; then restart_needed=1; fi
}
main() {
    action=$2
    case "$action" in upload|subscribe|update|cron) ;; *) return 1 ;; esac
    mc_lock || return 1
    SUB_TMP=$(mc_mktemp -d /tmp/clash-subscribe.XXXXXX) || { mc_unlock; return 1; }
    trap 'rm -rf "$SUB_TMP"; mc_unlock' EXIT
    trap 'exit 1' HUP INT TERM
    get_settings || return 1
    case "$action" in
        upload) yaml_upload && yaml_prepare || return 1 ;;
        subscribe)
            get_yaml_name || return 1
            subscribe_links=$(decode_url_link "$(dbus get merlinclash_sub_links)") || return 1
            if [ "$_name" = AP_ ]; then aprule_links "$subscribe_links" && yaml_download || return 1
            else parse_and_process_urls "$subscribe_links" && yaml_merge || return 1; fi
            yaml_prepare || return 1
            ;;
        update|cron) run_update || return 1 ;;
    esac
    mc_unlock
    if [ "$restart_needed" = 1 ]; then sh /jffs/softcenter/scripts/clash_config.sh recovery restart || return 1; fi
    http_response success
    echo BBABBBBC >> "$LOG_FILE"
}
http_response "$1"
if ! main "$@" >> "$LOG_FILE" 2>&1; then
    echo 'Profile operation failed; check validation, publish and restart results in the log' >> "$LOG_FILE"
    http_response failed
    exit 1
fi
