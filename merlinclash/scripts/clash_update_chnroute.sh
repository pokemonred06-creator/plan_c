#!/bin/sh
. /jffs/softcenter/scripts/base.sh
. /jffs/softcenter/scripts/clash_update_safe.sh
LOG_FILE=/tmp/upload/merlinclash_log.txt

validate_cidrs() {
    yq -e '.payload | tag == "!!seq"' "$1" >/dev/null 2>&1 || return 1
    yq -r '.payload[]' "$1" > "$MC_UPDATE_TMP/cidrs" || return 1
    awk -v version="$2" '
    function v4(s, a,n,i) {
        n=split(s,a,"."); if(n!=4) return 0
        for(i=1;i<=4;i++) if(a[i]!~/^[0-9]+$/ || a[i]+0>255) return 0
        return 1
    }
    function hexpart(s, a,n,i) {
        if(s=="") return 0
        n=split(s,a,":")
        for(i=1;i<=n;i++) if(a[i]=="" || length(a[i])>4 || a[i]!~/^[0-9a-fA-F]+$/) return -100
        return n
    }
    function v6(s, pos,left,right,n) {
        if(s!~/^[0-9a-fA-F:]+$/) return 0
        pos=index(s,"::")
        if(pos) {
            left=substr(s,1,pos-1); right=substr(s,pos+2)
            if(index(right,"::")) return 0
            if(left!="" && (substr(left,1,1)==":" || substr(left,length(left),1)==":")) return 0
            if(right!="" && (substr(right,1,1)==":" || substr(right,length(right),1)==":")) return 0
            n=hexpart(left)+hexpart(right)
            return n>=0 && n<8
        }
        return hexpart(s)==8
    }
    {
        n=split($0,c,"/")
        if(n!=2 || c[2]!~/^[0-9]+$/) exit 1
        if(version==4 && (!v4(c[1]) || c[2]+0>32)) exit 1
        if(version==6 && (!v6(c[1]) || c[2]+0>128)) exit 1
        count++
    }
    END { if(count==0) exit 1 }
    ' "$MC_UPDATE_TMP/cidrs"
}

update_cidrs() {
    _chn_ver=$1
    _chn_file=$MC_UPDATE_TMP/ChinaIPv$_chn_ver.yaml
    _chn_dest=$2
    mc_update_fetch "https://raw.githubusercontent.com/fernvenue/chn-cidr-list/master/ipv$_chn_ver.yaml" "$_chn_file" || return 1
    validate_cidrs "$_chn_file" "$_chn_ver" || { mc_update_log "IPv$_chn_ver CIDR database validation failed; existing rules retained."; return 1; }
    if [ -f "$_chn_dest" ] && cmp -s "$_chn_file" "$_chn_dest"; then
        mc_update_log "IPv$_chn_ver CIDRs are already current."
        return 0
    fi
    mc_update_publish_data "$_chn_file" "$_chn_dest" "$3" || return 1
    mc_update_log "IPv$_chn_ver CIDRs validated and published."
}

main() {
    [ "$2" = 25 ] || return 0
    mc_update_begin || return 1
    http_response "$1"
    status=0
    update_cidrs 4 "$MC_DATA/yaml_basic/ChinaIP.yaml" "$MC_SOFT/res/china_ip_route.ipset" || status=1
    update_cidrs 6 "$MC_DATA/yaml_basic/ChinaIPv6.yaml" "$MC_SOFT/res/china_ip_route6.ipset" || status=1
    return "$status"
}
main "$@"
status=$?
printf '%s\n' BBABBBBC >> "$LOG_FILE"
exit "$status"
