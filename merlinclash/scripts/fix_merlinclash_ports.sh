#!/bin/sh
# Permanent guard: ensure MerlinClash config has correct proxy nodes and rules.
# Protected canonical copies are stored alongside as .canonical backups.
RESTORE_CANONICAL=0

CANONICAL_PROXIES=/jffs/softcenter/merlinclash/yaml_bak/xraynew.yaml.canonical
CANONICAL_RULES=/jffs/softcenter/merlinclash/rule_bak/xraynew_rules.yaml.canonical
CURRENT_PROXIES=/jffs/softcenter/merlinclash/yaml_bak/xraynew.yaml
CURRENT_RULES=/jffs/softcenter/merlinclash/rule_bak/xraynew_rules.yaml

# Create canonical backups if they don't exist
if [ ! -f "$CANONICAL_PROXIES" ]; then
    cp "$CURRENT_PROXIES" "$CANONICAL_PROXIES"
    logger "fix_merlinclash: created canonical proxy backup"
fi
if [ ! -f "$CANONICAL_RULES" ]; then
    cp "$CURRENT_RULES" "$CANONICAL_RULES"
    logger "fix_merlinclash: created canonical rules backup"
fi

# Fix ports in current yaml_bak
fix_ports() {
    local f="$1"
    [ -f "$f" ] || return 0
    sed -i '/- name: bandwagon-xhttp3$/,/^  - name:/{s/    port: 1443/    port: 8443/}' "$f"
    sed -i '/- name: bandwagon-hy2$/,/^  - name:/{s/    port: 1443/    port: 31265/}' "$f"
}

fix_ports "$CURRENT_PROXIES"

# If yaml_bak was replaced by a UI upload, restore canonical proxies
CURRENT_NODES=$(grep -c 'name: bandwagon' "$CURRENT_PROXIES" 2>/dev/null | tr -d ' ')
CANONICAL_NODES=$(grep -c 'name: bandwagon' "$CANONICAL_PROXIES" 2>/dev/null | tr -d ' ')
if [ "$RESTORE_CANONICAL" = "1" ] && [ "$CURRENT_NODES" -lt 3 ] && [ "$CANONICAL_NODES" -ge 3 ]; then
    logger "fix_merlinclash: yaml_bak missing proxy nodes, restoring from canonical"
    cp "$CANONICAL_PROXIES" "$CURRENT_PROXIES"
fi

# If rule_bak was replaced by a UI upload, restore canonical rules
CURRENT_RULES_COUNT=$(grep -c 'DOMAIN\|IP-CIDR\|GEOIP\|MATCH' "$CURRENT_RULES" 2>/dev/null | tr -d ' ')
CANONICAL_RULES_COUNT=$(grep -c 'DOMAIN\|IP-CIDR\|GEOIP\|MATCH' "$CANONICAL_RULES" 2>/dev/null | tr -d ' ')
if [ "$RESTORE_CANONICAL" = "1" ] && [ "$CURRENT_RULES_COUNT" -lt 100 ] && [ "$CANONICAL_RULES_COUNT" -ge 200 ]; then
    logger "fix_merlinclash: rule_bak too few rules ($CURRENT_RULES_COUNT), restoring from canonical ($CANONICAL_RULES_COUNT)"
    cp "$CANONICAL_RULES" "$CURRENT_RULES"
fi

# Also fix yaml_use
fix_ports /jffs/softcenter/merlinclash/yaml_use/xraynew.yaml
