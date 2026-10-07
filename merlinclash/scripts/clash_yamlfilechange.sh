#!/bin/sh
. /jffs/softcenter/scripts/base.sh
. /jffs/softcenter/scripts/clash_safe.sh
# httpd does not define KSROOT; the installation root is explicit.
KSROOT=/jffs/softcenter
DNS_PATH="$KSROOT/merlinclash/yaml_dns"
BASIC_PATH="$KSROOT/merlinclash/yaml_basic"
LOG_FILE=/tmp/upload/dnsfile.log

decode_percent() {
    # Decode bytes as data. Backslashes in content cannot become printf escapes.
    awk '
    function h(c) { return index("0123456789abcdef",tolower(c))-1 }
    { out=""; for(i=1;i<=length($0);i++) {
        c=substr($0,i,1)
        if(c=="+") c=" "
        else if(c=="%") {
            a=h(substr($0,i+1,1)); b=h(substr($0,i+2,1))
            if(i+2>length($0)||a<0||b<0||a*16+b==0) exit 1
            c=sprintf("%c",a*16+b); i+=2
        }
        out=out c
    } print out }'
}
clear_dbus_content() {
    dbus list merlinclash_yamledit_content_ | cut -d= -f1 | while IFS= read -r key; do
        dbus remove "$key" || exit 1
    done
}
write_yaml_file() {
    tag=$1
    case "$tag" in
        redirhost) outfile="$DNS_PATH/redirhost.yaml" ;;
        fakeip) outfile="$DNS_PATH/fakeip.yaml" ;;
        sniffer) outfile="$BASIC_PATH/sniffer.yaml" ;;
        hosts) outfile="$BASIC_PATH/hosts.yaml" ;;
        head) outfile="$BASIC_PATH/head.yaml" ;;
        acl)
            yamlname=$(dbus get merlinclash_set_yamlsel_start)
            mc_valid_name "$yamlname" || return 1
            outfile="$KSROOT/merlinclash/rule_custom/${yamlname}_custom_rule.yaml"
            ;;
        iptblack) outfile="$BASIC_PATH/ipsetproxyarround.yaml" ;;
        iptwhite) outfile="$BASIC_PATH/ipsetproxy.yaml" ;;
        *) echo 'Unknown editor tag' >> "$LOG_FILE"; return 1 ;;
    esac
    case "$tag" in
        acl)
            # Validate and encode every private record before publishing the
            # source file or allowing its ACL child to replace the UI rows.
            MC_REQUEST_PROFILE="$yamlname" /bin/sh "$KSROOT/scripts/clash_saveacls.sh" validate validate "$TMP_DIR/clean" || return 1
            # One child owns the source and UI rollback if publication fails.
            MC_REQUEST_PROFILE="$yamlname" /bin/sh "$KSROOT/scripts/clash_saveacls.sh" publish publish "$TMP_DIR/clean"
            return $?
            ;;
        iptblack|iptwhite) ;;
        *)
            [ -s "$TMP_DIR/clean" ] || return 1
            yq eval '.' "$TMP_DIR/clean" >/dev/null 2>>"$LOG_FILE" || return 1
            [ "$(yq eval 'tag' "$TMP_DIR/clean" 2>>"$LOG_FILE")" = '!!map' ] || return 1
            case "$tag" in redirhost|fakeip) fragment=dns ;; sniffer|hosts) fragment=$tag ;; *) fragment= ;; esac
            if [ -n "$fragment" ]; then
                [ "$(FRAGMENT_KEY="$fragment" yq eval '.[strenv(FRAGMENT_KEY)] | tag' "$TMP_DIR/clean" 2>>"$LOG_FILE")" = '!!map' ] || return 1
            fi
            duplicate_check=$(yq eval '.. | select(tag == "!!map") | ((keys | length) == (keys | unique | length))' "$TMP_DIR/clean" 2>>"$LOG_FILE") || return 1
            printf '%s\n' "$duplicate_check" | grep -q false && return 1
            ;;
    esac
    # Publish only after each decoder/parser succeeded, on the destination filesystem.
    dst_tmp=$(mc_mktemp "${outfile}.XXXXXX") || return 1
    cp "$TMP_DIR/clean" "$dst_tmp" || { rm -f "$dst_tmp"; return 1; }
    chmod 600 "$dst_tmp" || { rm -f "$dst_tmp"; return 1; }
    mv -f "$dst_tmp" "$outfile" || { rm -f "$dst_tmp"; return 1; }
}
main() {
    count=$(dbus get merlinclash_yamledit_content_count)
    case "$count" in ''|*[!0-9]*) return 1 ;; esac
    [ "$count" -gt 0 ] || { http_response "$1"; return 0; }
    [ "$count" -le 4096 ] || return 1
    tag=$(dbus get merlinclash_yamledit_tag)
    mc_lock || return 1
    TMP_DIR=$(mc_mktemp -d /tmp/edityaml.XXXXXX) || { mc_unlock; return 1; }
    trap 'rm -rf "$TMP_DIR"; mc_unlock' EXIT
    trap 'exit 1' HUP INT TERM
    : > "$TMP_DIR/b64" || return 1
    i=0
    while [ "$i" -lt "$count" ]; do
        chunk=$(dbus get "merlinclash_yamledit_content_$i")
        [ -n "$chunk" ] || return 1
        printf '%s' "$chunk" >> "$TMP_DIR/b64" || return 1
        i=$((i + 1))
    done
    # A blank text entry deliberately clears list/rule templates.
    if [ "$(cat "$TMP_DIR/b64")" = ' ' ]; then
        case "$tag" in acl|iptblack|iptwhite) : > "$TMP_DIR/clean" ;; *) return 1 ;; esac
    else
        if [ -x "$KSROOT/bin/base64_decode" ]; then
            "$KSROOT/bin/base64_decode" < "$TMP_DIR/b64" > "$TMP_DIR/decoded" 2>>"$LOG_FILE" || return 1
        elif [ -x /bin/base64 ]; then
            /bin/base64 -d < "$TMP_DIR/b64" > "$TMP_DIR/decoded" 2>>"$LOG_FILE" || return 1
        else
            return 1
        fi
        decode_percent < "$TMP_DIR/decoded" > "$TMP_DIR/percent" || return 1
        awk '{ sub(/\r$/, ""); print }' "$TMP_DIR/percent" > "$TMP_DIR/clean" || return 1
    fi
    write_yaml_file "$tag" || return 1
    clear_dbus_content || return 1
    http_response "$1"
}
if ! main "$@"; then
    echo 'Editor operation did not complete; decoder/parser failures retain the previous file' >> "$LOG_FILE"
    http_response failed
    exit 1
fi
