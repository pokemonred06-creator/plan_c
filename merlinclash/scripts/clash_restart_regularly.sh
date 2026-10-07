#!/bin/sh
. /jffs/softcenter/scripts/base.sh
MC_CRON_QUIET=0
[ "${1:-}" != --quiet ] || MC_CRON_QUIET=1
cron_reply() { [ "$MC_CRON_QUIET" = 1 ] || http_response "$1"; }

# cru takes one complete cron expression, including its command.
cron_number() {
    case "$1" in ''|*[!0-9]*) return 1;; esac
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}
mode=$(dbus get merlinclash_select_clash_restart)
minute=$(dbus get merlinclash_select_clash_restart_minute)
hour=$(dbus get merlinclash_select_clash_restart_hour)
week=$(dbus get merlinclash_select_clash_restart_week)
day=$(dbus get merlinclash_select_clash_restart_day)
interval=$(dbus get merlinclash_select_clash_restart_minute_2)
command='/bin/sh /jffs/softcenter/scripts/clash_restart_update.sh'
case "$mode" in
    2|3|4)
        cron_number "$minute" 0 59 && cron_number "$hour" 0 23 || exit 1
        case "$mode" in
            2) schedule="$minute $hour * * *";;
            3) cron_number "$week" 0 7 || exit 1; schedule="$minute $hour * * $week";;
            4) cron_number "$day" 1 31 || exit 1; schedule="$minute $hour $day * *";;
        esac
        ;;
    5)
        case "$interval" in
            2|5|10|15|20|25|30) schedule="*/$interval * * * *";;
            1|3|6|12) schedule="0 */$interval * * *";;
            *) exit 1;;
        esac
        ;;
    *) cru d clash_restart || exit 1; cron_reply close; exit 0;;
esac
cru a clash_restart "$schedule $command" || exit 1
cron_reply open
