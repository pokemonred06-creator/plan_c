#!/bin/sh
. /jffs/softcenter/scripts/base.sh
. /jffs/softcenter/scripts/clash_base.sh
. /jffs/softcenter/scripts/clash_safe.sh
LOG_FILE=/tmp/upload/merlinclash_log.txt
case "$2" in save|del|use|push|validate|publish) ;; *) exit 1 ;; esac
acl_finish() {
    status=$?; failed=0
    trap - EXIT HUP INT TERM
    [ "$dbus_pending" != 1 ] || restore_acl_dbus || failed=1
    [ "$source_pending" != 1 ] || restore_acl_file || failed=1
    if [ "$failed" = 0 ]; then
        [ -z "$acl_stage" ] || rm -rf "$acl_stage"
        [ -z "$acl_tmp" ] || rm -f "$acl_tmp"
    else
        echo "ACL rollback incomplete; recovery files retained at $acl_stage" >> "$LOG_FILE"
        status=1
    fi
    mc_unlock
    exit "$status"
}
mc_lock || exit 75
trap 'acl_finish' EXIT
trap 'exit 1' HUP INT TERM
if [ "${MC_REQUEST_PROFILE+x}" = x ]; then yamlname=$MC_REQUEST_PROFILE
else yamlname=$(mc_selected) || exit 1; fi
mc_valid_name "$yamlname" || exit 1
rulecusfile="/jffs/softcenter/merlinclash/rule_custom/${yamlname}_custom_rule.yaml"
acl_indices() {
    entries=$(dbus list merlinclash_acl_type_) || return 1
    printf '%s\n' "$entries" | cut -d= -f1 | sed -n 's/^merlinclash_acl_type_\([0-9][0-9]*\)$/\1/p' | sort -n
}
acl_urldecode() {
    printf '%s\n' "$1" | awk '
    function h(c){return index("0123456789abcdef",tolower(c))-1}
    {out="";for(j=1;j<=length($0);j++){
        c=substr($0,j,1);if(c=="+")c=" "
        else if(c=="%"){
            a=h(substr($0,j+1,1));b=h(substr($0,j+2,1))
            if(j+2>length($0)||a<0||b<0||a*16+b==0)exit 1
            c=sprintf("%c",a*16+b);j+=2
        }
        out=out c
    }print out}'
}
parse_acl_rule() {
    case "$line" in *,*) ;; *) return 1 ;; esac
    case "$line" in *"$(printf '\r')"*) return 1 ;; esac
    type=${line%%,*}; remaining=${line#*,}
    case "$type" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
    # Only logical rules use parenthesized nesting. Ordinary regex content
    # can contain literal, escaped or character-class parentheses.
    case "$type" in
        AND|OR|NOT|SUB-RULE)
            printf '%s\n' "$remaining" | awk '
            {
                if ($0 !~ /^[[:space:]]*\(/) exit 1
                depth=0; escaped=0; bracket=0; found=0
                for(j=1;j<=length($0);j++) {
                    c=substr($0,j,1)
                    if(escaped) {escaped=0; continue}
                    if(c=="\\") {escaped=1; continue}
                    if(bracket) {if(c=="]")bracket=0; continue}
                    if(c=="[") {bracket=1; continue}
                    if(c=="(") depth++
                    else if(c==")") {if(--depth<0)exit 1}
                    else if(c=="," && depth==0) {
                        content=substr($0,1,j-1)
                        if(content !~ /\)[[:space:]]*$/)exit 1
                        print content; print substr($0,j+1); found=1; break
                    }
                }
                if(!found || depth!=0)exit 1
            }' > "$acl_stage/fields" || return 1
            content=$(sed -n '1p' "$acl_stage/fields") || return 1
            lianjie=$(sed -n '2p' "$acl_stage/fields") || return 1
            ;;
        MATCH) content=; lianjie=$remaining ;;
        *)
            case "$remaining" in *,*) ;; *) return 1 ;; esac
            content=${remaining%%,*}; lianjie=${remaining#*,}
            [ -n "$content" ] || return 1
            ;;
    esac
    # Optional rule parameters remain part of the destination field, but its
    # first value must name a policy rather than be empty or whitespace.
    destination=${lianjie%%,*}
    [ -n "$(printf '%s' "$destination" | tr -d '[:space:]')" ] || return 1
}
stage_acl_records() {
    [ -f "$1" ] || return 1
    [ -n "$acl_stage" ] || acl_stage=$(mc_mktemp -d /tmp/clash-acls.XXXXXX) || return 1
    record_count=0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ] || continue
        parse_acl_rule || return 1
        record_count=$((record_count + 1))
        [ "$type" = MATCH ] && empty_content=1 || empty_content=0
        type=$(urlencode "$type") || return 1
        content=$(urlencode "$content") || return 1
        lianjie=$(urlencode "$lianjie") || return 1
        type=$(encode_url_link "$type") || return 1
        content=$(encode_url_link "$content") || return 1
        lianjie=$(encode_url_link "$lianjie") || return 1
        [ -n "$type" ] && [ -n "$lianjie" ] || return 1
        [ "$empty_content" = 1 ] || [ -n "$content" ] || return 1
        case "$type$content$lianjie" in *[!A-Za-z0-9_-]*) return 1 ;; esac
        printf '%s' "$type" > "$acl_stage/$record_count.type" &&
            printf '%s' "$content" > "$acl_stage/$record_count.content" &&
            printf '%s' "$lianjie" > "$acl_stage/$record_count.lianjie" || return 1
    done < "$1"
}
save_yaml() {
    mkdir -p /jffs/softcenter/merlinclash/rule_custom || return 1
    acl_tmp=$(mc_mktemp "${rulecusfile}.XXXXXX") || return 1
    indices=$(acl_indices) || return 1
    for acl in $indices; do
        type=$(dbus get "merlinclash_acl_type_$acl")
        content=$(dbus get "merlinclash_acl_content_$acl")
        lianjie=$(dbus get "merlinclash_acl_lianjie_$acl")
        type=$(decode_url_link "$type") || return 1
        content=$(decode_url_link "$content") || return 1
        lianjie=$(decode_url_link "$lianjie") || return 1
        type=$(acl_urldecode "$type") || return 1
        content=$(acl_urldecode "$content") || return 1
        lianjie=$(acl_urldecode "$lianjie") || return 1
        # A database item must remain one rule, rather than inject extra records.
        case "$type$content$lianjie" in *'
'*|*"$(printf '\r')"*) return 1 ;; esac
        if [ "$type" = MATCH ]; then printf '%s,%s\n' "$type" "$lianjie" >> "$acl_tmp" || return 1
        else printf '%s,%s,%s\n' "$type" "$content" "$lianjie" >> "$acl_tmp" || return 1; fi
    done
    stage_acl_records "$acl_tmp" || return 1
    mv -f "$acl_tmp" "$rulecusfile"
}
snapshot_acl_dbus() {
    # Snapshot exact indexed ACL fields, including incomplete/orphaned rows.
    # Plan/settings keys sharing this prefix are outside this transaction.
    dbus list merlinclash_acl_ > "$acl_stage/old-list" || return 1
    cut -d= -f1 "$acl_stage/old-list" | awk '/^merlinclash_acl_(type|content|lianjie)_[0-9]+$/' > "$acl_stage/old-keys" || return 1
    while IFS= read -r key; do
        dbus get "$key" > "$acl_stage/old.$key" || return 1
    done < "$acl_stage/old-keys"
    : > "$acl_stage/new-keys" || return 1
    i=1
    while [ "$i" -le "$record_count" ]; do
        printf 'merlinclash_acl_type_%s\nmerlinclash_acl_content_%s\nmerlinclash_acl_lianjie_%s\n' "$i" "$i" "$i" >> "$acl_stage/new-keys" || return 1
        i=$((i + 1))
    done
    cat "$acl_stage/old-keys" "$acl_stage/new-keys" > "$acl_stage/all-keys" || return 1
    sort -u "$acl_stage/all-keys" > "$acl_stage/affected-keys" || return 1
}
restore_acl_dbus() {
    restored=0
    while IFS= read -r key; do dbus remove "$key" || restored=1; done < "$acl_stage/affected-keys"
    while IFS= read -r key; do
        value=$(cat "$acl_stage/old.$key") || { restored=1; continue; }
        dbus set "$key=$value" || restored=1
    done < "$acl_stage/old-keys"
    [ "$restored" = 0 ]
}
restore_acl_file() {
    if [ "$old_file_present" = 1 ]; then
        restore_tmp=$(mc_mktemp "${rulecusfile}.XXXXXX") || return 1
        cp -p "$acl_stage/source.old" "$restore_tmp" &&
            cmp -s "$acl_stage/source.old" "$restore_tmp" &&
            mv -f "$restore_tmp" "$rulecusfile" || { rm -f "$restore_tmp"; return 1; }
    else rm -f "$rulecusfile"; fi
}
replace_acl_dbus() {
    dbus_pending=1
    while IFS= read -r key; do
        dbus remove "$key" || return 1
    done < "$acl_stage/old-keys"
    i=1
    while [ "$i" -le "$record_count" ]; do
        type=$(cat "$acl_stage/$i.type") || return 1
        content=$(cat "$acl_stage/$i.content") || return 1
        lianjie=$(cat "$acl_stage/$i.lianjie") || return 1
        dbus set "merlinclash_acl_type_$i=$type" || return 1
        dbus set "merlinclash_acl_content_$i=$content" || return 1
        dbus set "merlinclash_acl_lianjie_$i=$lianjie" || return 1
        i=$((i + 1))
    done
}
push_dbus() {
    # Parse and encode every record and snapshot every old field before clear.
    if [ -f "$rulecusfile" ]; then stage_acl_records "$rulecusfile" || return 1
    else acl_stage=$(mc_mktemp -d /tmp/clash-acls.XXXXXX) || return 1; record_count=0; fi
    snapshot_acl_dbus && replace_acl_dbus || return 1
    dbus_pending=0
}
publish_acl() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ ! -L "$rulecusfile" ] || return 1
    stage_acl_records "$1" && snapshot_acl_dbus || return 1
    old_file_present=0
    if [ -e "$rulecusfile" ]; then
        [ -f "$rulecusfile" ] && cp -p "$rulecusfile" "$acl_stage/source.old" &&
            cmp -s "$rulecusfile" "$acl_stage/source.old" || return 1
        old_file_present=1
    fi
    mkdir -p /jffs/softcenter/merlinclash/rule_custom || return 1
    acl_tmp=$(mc_mktemp "${rulecusfile}.XXXXXX") || return 1
    cp "$1" "$acl_tmp" && chmod 600 "$acl_tmp" || return 1
    source_pending=1
    mv -f "$acl_tmp" "$rulecusfile" && replace_acl_dbus || return 1
    # One shell assignment commits both resources before their cleanup trap.
    dbus_pending=0 source_pending=0
}
case "$2" in
    save|del) save_yaml || exit 1; http_response "$1" ;;
    use) [ "$(dbus get merlinclash_set_yamlsel_startchange)" != 1 ] || push_dbus ;;
    push) push_dbus ;;
    validate) [ "$#" = 3 ] && [ -f "$3" ] && [ ! -L "$3" ] && stage_acl_records "$3" ;;
    publish) [ "$#" = 3 ] && publish_acl "$3" ;;
esac
