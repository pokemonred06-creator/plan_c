#!/bin/sh
. /jffs/softcenter/scripts/base.sh
. /jffs/softcenter/scripts/clash_safe.sh
mc_lock || exit $?
trap 'mc_unlock' EXIT
trap 'exit 1' HUP INT TERM
# A pending UI selection may have a different controller or secret. Read the
# profile actually serving the API while lifecycle changes are serialized.
cfg=$(mc_active_config) || exit 1
[ -s "$cfg" ] && [ -n "$(mc_core_pids)" ] || exit 1
exec 8>/tmp/clash-proxygroup.lock
flock -n 8 || exit 75
stage=$(mc_mktemp -d /tmp/clash-proxygroups.XXXXXX) || exit 1
trap 'rm -rf "$stage"; mc_unlock' EXIT
secret=$(yq e -r '.secret // ""' "$cfg") || exit 1
control=$(yq e -r '.external-controller' "$cfg") || exit 1
case "$control" in 0.0.0.0:*) control="127.0.0.1:${control##*:}" ;; :*) control="127.0.0.1$control" ;; esac
mc_curl --noproxy '*' -fsS --connect-timeout 2 --max-time 5 -H "Authorization: Bearer $secret" "http://$control/proxies" > "$stage/proxies.json" || exit 1
jq -e '.proxies | type == "object"' "$stage/proxies.json" >/dev/null || exit 1
{
    printf '%s\n' DIRECT REJECT
    # Automatic groups are valid rule destinations too. The API exposes their
    # members in "all"; individual proxies and the controller GLOBAL are omitted.
    jq -r '.proxies | to_entries[] | select((.value.all | type) == "array" and .key != "GLOBAL") | .key' "$stage/proxies.json"
} > "$stage/groups" || exit 1
printf '%s\n' DOMAIN DOMAIN-SUFFIX DOMAIN-KEYWORD DOMAIN-WILDCARD DOMAIN-REGEX GEOSITE IP-CIDR SRC-IP-CIDR IP-ASN SRC-IP-ASN IP-SUFFIX SRC-IP-SUFFIX GEOIP SRC-GEOIP DST-PORT SRC-PORT IN-TYPE IN-PORT IN-USER IN-NAME AND OR NOT NETWORK DSCP SUB-RULE > "$stage/types" || exit 1
cp "$stage/groups" /tmp/upload/proxygroups.txt.new && mv -f /tmp/upload/proxygroups.txt.new /tmp/upload/proxygroups.txt || exit 1
cp "$stage/types" /tmp/upload/proxytype.txt.new && mv -f /tmp/upload/proxytype.txt.new /tmp/upload/proxytype.txt || exit 1
http_response "$1"
