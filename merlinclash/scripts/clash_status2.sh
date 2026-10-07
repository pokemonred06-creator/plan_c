#!/bin/sh
. /jffs/softcenter/scripts/base.sh
. /jffs/softcenter/scripts/clash_safe.sh

html_escape() {
    printf '%s' "$1" | sed 's/\&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g'
}
pid_clash=$(mc_core_pids)
pid_d2s=$(pidof mc_dns2socks)
date_text=$(date '+%Y年%m月%d日 %X')
starttime=$(html_escape "$(dbus get merlinclash_clashstarttime)")
if [ -n "$pid_clash" ]; then
    text1="<span style='color: #6C0'>【${date_text}】Clash 进程运行正常！(PID: $pid_clash)</span>"
    text3="<span style='color: #6C0'>【Clash本次启动时间】：$starttime</span>"
else
    text1="<span style='color: red'>【${date_text}】Clash 进程未在运行！</span>"
    text3="<span style='color: red'>Clash 进程未在运行！</span>"
fi
if [ "$(dbus get merlinclash_enable)" = 1 ] && cru l | grep -Fq '/jffs/softcenter/scripts/clash_watchdog.sh'; then
    text2="<span style='color: #6C0'>Clash 定时健康守护已启用！</span>"
else
    text2="<span style='color: gold'>Clash 定时健康守护未启用！</span>"
fi
if [ -n "$pid_d2s" ]; then
    text4="<span style='color: #6C0'>Dns2Socks 进程运行正常！(PID: $pid_d2s)</span>"
else
    text4="<span style='color: gold'>Dns2Socks 进程未在运行！</span>"
fi
patchver=$(dbus get merlinclash_patch_version)
if [ -n "$patchver" ] && [ "$patchver" != 0 ]; then
    patchver=$(html_escape "$patchver")
    text5="<span style='display:table-cell;color:gold'>【已装补丁版本】：$patchver</span>"
    text6="<span style='display:table-cell;color:gold'>P:$patchver</span>"
else
    text5="<span style='display:none;'>【已装补丁版本】：</span>"
    text6="<span style='display:none;'></span>"
fi
http_response "$text1@$text2@$text3@$text4@$text5@$text6"
