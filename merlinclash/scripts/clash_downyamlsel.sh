#!/bin/sh
. /jffs/softcenter/scripts/base.sh
. /jffs/softcenter/scripts/clash_safe.sh
[ "${2:-}" = downyaml ] || exit 2
name=$(dbus get merlinclash_set_yamlsel_edit)
mc_valid_name "$name" || exit 1
mc_lock || exit $?
trap 'mc_unlock' EXIT
src="$MC_ROOT/yaml_use/$name.yaml"
[ -s "$src" ] || exit 1
out=$(mc_mktemp "/tmp/upload/.download.XXXXXX") || exit 1
trap 'rm -f "$out"; mc_unlock' EXIT
cp "$src" "$out" && chmod 600 "$out" && mv -f "$out" "/tmp/upload/$name.yaml" || exit 1
http_response "$name.yaml"
