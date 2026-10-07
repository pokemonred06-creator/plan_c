#!/bin/sh
. /jffs/softcenter/scripts/base.sh
# A schedule must never turn an intentional Off back on.
[ "$(dbus get merlinclash_enable)" = 1 ] || exit 0
exec /bin/sh /jffs/softcenter/scripts/clash_config.sh recovery restart
