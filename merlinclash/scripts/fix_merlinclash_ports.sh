#!/bin/sh
# Retired implicit port/rule rewrites. Repairs belong in validated profile transactions.
. /jffs/softcenter/scripts/clash_safe.sh
name=$(mc_selected) || exit 1
mc_lock || exit $?
trap 'mc_unlock' EXIT
mc_validate_yaml "$MC_ROOT/yaml_use/$name.yaml" && mc_validate_yaml "$MC_ROOT/yaml_bak/$name.yaml"
