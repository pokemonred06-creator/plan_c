#!/bin/sh
# Shared checked update operations. Callers hold the lifecycle lock until exit.
. /jffs/softcenter/scripts/clash_safe.sh
MC_SOFT=/jffs/softcenter
MC_DATA=$MC_SOFT/merlinclash
MC_UPDATE_STAGE=
MC_UPDATE_TMP=
MC_UPDATE_DEST=
MC_UPDATE_REPLACED=0
MC_UPDATE_STOPPED=0
MC_UPDATE_COMMITTED=0
MC_UPDATE_RUNNING=0
MC_UPDATE_STOP_TOKEN=
MC_UPDATE_MAINTENANCE=0
MC_PROBE_PID=
MC_FETCH_PID=
unset MC_FRESH_MARK_PROFILE
MC_OLD_VERSION=
MC_OLD_VERSION_TMP=
MC_OLD_BINARY_VER=

mc_update_log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }

mc_update_begin() {
    umask 077
    # Capture intent before any running/enabled eligibility read. A stop that
    # arrives before the selector helper can otherwise hide behind a later On.
    MC_UPDATE_STOP_TOKEN=$(dbus get merlinclash_stop_token)
    mkdir -p /tmp/upload || return 1
    mc_lock || { mc_update_log 'Another plugin operation is running; update deferred.'; return 1; }
    trap 'mc_update_cleanup $?' 0
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    MC_UPDATE_TMP=$(mc_mktemp -d /tmp/mc-update.XXXXXX) || return 1
}

mc_update_restart() {
    # The lock descriptor is inherited; recovery does not change intentional Off.
    if mc_update_off_requested; then
        sh "$MC_SOFT/scripts/clash_config.sh" stop stop
        return $?
    fi
    if [ "${MC_REQUEST_PROFILE+x}" = x ]; then _mc_restart_profile=$MC_REQUEST_PROFILE
    else _mc_restart_profile=$(mc_selected) || return 1; fi
    _mc_fresh_profile=
    if [ -n "${MC_FRESH_MARK_PROFILE:-}" ] && [ "$MC_FRESH_MARK_PROFILE" = "$_mc_restart_profile" ]; then
        _mc_fresh_profile=$MC_FRESH_MARK_PROFILE
    fi
    MC_FRESH_MARK_PROFILE="$_mc_fresh_profile" sh "$MC_SOFT/scripts/clash_config.sh" recovery restart || return 1
    mc_update_health
}

mc_update_off_requested() {
    [ "$(dbus get merlinclash_enable)" != 1 ] && [ "$(dbus get merlinclash_recovery_wanted)" != 1 ]
}

mc_update_health() {
    _mc_i=0
    while [ "$_mc_i" -lt 15 ]; do
        if mc_update_off_requested; then
            sh "$MC_SOFT/scripts/clash_config.sh" stop stop
            return $?
        fi
        sh "$MC_SOFT/scripts/clash_watchdog.sh" --check >/dev/null 2>&1 && return 0
        sleep 1
        _mc_i=$((_mc_i + 1))
    done
    return 1
}

mc_update_stop_core() {
    _mc_pids=$(mc_core_pids)
    [ -z "$_mc_pids" ] && return 0
    kill $_mc_pids 2>/dev/null || return 1
    _mc_i=0
    while [ "$_mc_i" -lt 10 ]; do
        [ -z "$(mc_core_pids)" ] && return 0
        sleep 1
        _mc_i=$((_mc_i + 1))
    done
    # A stuck engine is a transaction failure; leave its executable intact.
    return 1
}

mc_update_cleanup_child() {
 _mc_child_pid=$1
 [ -n "$_mc_child_pid" ] || return 0
 # Requests and probes may ignore TERM. Bound the grace period and reap only
 # this owner's exact child before removing its files or releasing the mutex.
 kill "$_mc_child_pid" 2>/dev/null
 _mc_child_ticks=0
 while kill -0 "$_mc_child_pid" 2>/dev/null && [ "$_mc_child_ticks" -lt 4 ]; do
 sleep 1
 _mc_child_ticks=$((_mc_child_ticks + 1))
 done
 kill -KILL "$_mc_child_pid" 2>/dev/null
 wait "$_mc_child_pid" 2>/dev/null || true
}

mc_update_cleanup() {
 _mc_rc=$1
 trap - 0 HUP INT TERM
 mc_update_cleanup_child "$MC_PROBE_PID"
 MC_PROBE_PID=
 mc_update_cleanup_child "$MC_FETCH_PID"
 MC_FETCH_PID=
    if [ "$MC_UPDATE_COMMITTED" != 1 ]; then
        if [ "$MC_UPDATE_REPLACED" = 1 ]; then
            if [ "$MC_UPDATE_DEST" = "$MC_SOFT/bin/clash" ]; then mc_update_stop_core || _mc_rc=1; fi
            if [ -f "$MC_UPDATE_STAGE/previous" ]; then
                _mc_restore=0
                mv -f "$MC_UPDATE_STAGE/previous" "$MC_UPDATE_DEST" || _mc_restore=1
            else
                _mc_restore=0
                rm -f "$MC_UPDATE_DEST" || _mc_restore=1
            fi
            if [ "$_mc_restore" != 0 ]; then
                mc_update_log "ERROR: rollback retained at $MC_UPDATE_STAGE/previous; replacement could not be restored."
                MC_UPDATE_STAGE=
                _mc_rc=1
            fi
            if [ "$MC_UPDATE_DEST" = "$MC_SOFT/bin/clash" ]; then
                mc_update_restore_version merlinclash_clash_version "$MC_OLD_VERSION" || _mc_rc=1
                mc_update_restore_version merlinclash_clash_version_tmp "$MC_OLD_VERSION_TMP" || _mc_rc=1
                mc_update_restore_version merlinclash_binary_ver "$MC_OLD_BINARY_VER" || _mc_rc=1
            fi
        fi
        if [ "$MC_UPDATE_STOPPED" = 1 ] && [ "$MC_UPDATE_RUNNING" = 1 ] && ! mc_update_off_requested; then
            mc_update_restart || { mc_update_log 'ERROR: previous engine restart failed after rollback.'; _mc_rc=1; }
        fi
    fi
    # An Off request can arrive while this owner holds the mutex, so its caller
    # cannot run stop immediately. Download failures precede the transaction's
    # running-state capture. A core may also exit while its owned routes/DNS
    # remain, so include current runtime ownership as well as the captured core.
    if mc_update_off_requested && { [ "$MC_UPDATE_RUNNING" = 1 ] || [ -n "$(mc_core_pids)" ] || mc_owned_state_present; }; then
        sh "$MC_SOFT/scripts/clash_config.sh" stop stop || {
            mc_update_log 'ERROR: pending intentional stop could not be completed.'
            _mc_rc=1
        }
    fi
    if [ "$MC_UPDATE_MAINTENANCE" = 1 ]; then
        dbus remove merlinclash_maintenance >/dev/null 2>&1 || _mc_rc=1
    fi
    [ -z "$MC_UPDATE_STAGE" ] || rm -rf "$MC_UPDATE_STAGE"
    [ -z "$MC_UPDATE_TMP" ] || rm -rf "$MC_UPDATE_TMP"
    mc_unlock
    exit "$_mc_rc"
}

mc_update_restore_version() {
    if [ -n "$2" ]; then dbus set "$1=$2"; else dbus remove "$1"; fi
}

mc_update_curl_exec() {
 # Exec keeps the recorded request PID identical to curl; a background shell
 # function around mc_curl would leave its grandchild alive on cancellation.
 if [ -x /opt/bin/curl ]; then exec /opt/bin/curl "$@"; else exec /usr/sbin/curl "$@"; fi
}

mc_update_fetch() {
 case "$1" in https://*) ;; *) return 1 ;; esac
 (ulimit -f 131072 || exit 1
 mc_update_curl_exec -fSsL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 "$1" -o "$2"
 ) 9>&- &
 MC_FETCH_PID=$!
 # A builtin wait is interruptible, so the owner's signal traps can promptly
 # terminate and reap the request instead of waiting behind a stalled download.
 wait "$MC_FETCH_PID"
 _mc_fetch_status=$?
 MC_FETCH_PID=
 [ "$_mc_fetch_status" = 0 ] || return 1
 [ -s "$2" ]
}

mc_update_digest() {
    _mc_expected=$2
    [ "${#_mc_expected}" -eq 64 ] || return 1
    case "$_mc_expected" in *[!0-9a-fA-F]*) return 1 ;; esac
    if which sha256sum >/dev/null 2>&1; then
        _mc_actual=$(sha256sum "$1" | awk '{print $1}') || return 1
    elif which openssl >/dev/null 2>&1; then
        _mc_actual=$(openssl dgst -sha256 "$1" | awk '{print $NF}') || return 1
    else
        mc_update_log 'No SHA256 verifier is installed; authenticated update deferred.'
        return 1
    fi
    [ "$(printf '%s' "$_mc_actual" | tr A-F a-f)" = "$(printf '%s' "$_mc_expected" | tr A-F a-f)" ]
}

mc_update_space() {
    _mc_new=$(du -k "$1" | awk '{print $1}')
    _mc_old=0
    [ ! -f "$2" ] || _mc_old=$(du -k "$2" | awk '{print $1}')
    _mc_avail=$(df -k "$(dirname "$2")" | tail -n 1 | awk '{print $4}')
    case "$_mc_new:$_mc_old:$_mc_avail" in *[!0-9:]*|::*|*::*) return 1 ;; esac
    [ -n "$_mc_new" ] && [ -n "$_mc_old" ] && [ -n "$_mc_avail" ] || return 1
    [ "$_mc_avail" -ge "$((_mc_new + _mc_old + 1024))" ] || {
        mc_update_log 'Insufficient destination space for expanded data, staging and rollback.'
        return 1
    }
}

mc_update_run() {
    # Bound version/config probes without relying on firmware timeout syntax.
    "$@" 9>&- > "$MC_UPDATE_TMP/probe-output" 2>&1 &
    MC_PROBE_PID=$!
    _mc_ticks=0
    while kill -0 "$MC_PROBE_PID" 2>/dev/null; do
        if [ "$_mc_ticks" -ge 30 ]; then
            kill "$MC_PROBE_PID" 2>/dev/null
            sleep 1
            kill -KILL "$MC_PROBE_PID" 2>/dev/null
            wait "$MC_PROBE_PID" 2>/dev/null
            MC_PROBE_PID=
            return 1
        fi
        sleep 1
        _mc_ticks=$((_mc_ticks + 1))
    done
    wait "$MC_PROBE_PID"
    _mc_status=$?
    MC_PROBE_PID=
    return "$_mc_status"
}

mc_update_validate_core() {
    _mc_bin=$1
    mc_update_run "$_mc_bin" -v || return 1
    grep -Eq '^(Mihomo|Clash)([[:space:]]|$)' "$MC_UPDATE_TMP/probe-output" || return 1
    MC_UPDATE_VERSION=$(head -n 1 "$MC_UPDATE_TMP/probe-output")
    _mc_name=$(dbus get merlinclash_set_yamlsel_start)
    [ -n "$_mc_name" ] || _mc_name=$(dbus get merlinclash_yamlsel)
    mc_valid_name "$_mc_name" || return 1
    _mc_runtime=
    for _mc_pid in $(mc_core_pids); do
        [ -r "/proc/$_mc_pid/cmdline" ] || continue
        _mc_runtime=$(tr '\000' '\n' < "/proc/$_mc_pid/cmdline" 2>/dev/null | awk '$0 == "-f" {getline; print; exit}')
        [ -z "$_mc_runtime" ] || break
    done
    _mc_checked=0
    for _mc_cfg in "$MC_DATA/yaml_use/$_mc_name.yaml" "$MC_DATA/yaml_bak/$_mc_name.yaml" "$_mc_runtime"; do
        [ -f "$_mc_cfg" ] || continue
        mc_update_run "$_mc_bin" -t -d "$MC_DATA" -f "$_mc_cfg" || return 1
        _mc_checked=$((_mc_checked + 1))
    done
    [ "$_mc_checked" -gt 0 ]
}

mc_update_stage_file() {
    [ -s "$1" ] && [ -d "$(dirname "$2")" ] || return 1
    mc_update_space "$1" "$2" || return 1
    MC_UPDATE_STAGE=$(mc_mktemp -d "$(dirname "$2")/.mc-update.XXXXXX") || return 1
    MC_UPDATE_DEST=$2
    cp "$1" "$MC_UPDATE_STAGE/candidate" || return 1
    cmp -s "$1" "$MC_UPDATE_STAGE/candidate" || return 1
    if [ -f "$2" ]; then
        cp -p "$2" "$MC_UPDATE_STAGE/previous" && cmp -s "$2" "$MC_UPDATE_STAGE/previous" || return 1
    fi
}

mc_update_core() {
    unset MC_FRESH_MARK_PROFILE
    [ -f "$MC_SOFT/bin/clash" ] && [ ! -L "$MC_SOFT/bin/clash" ] || return 1
    MC_OLD_VERSION=$(dbus get merlinclash_clash_version)
    MC_OLD_VERSION_TMP=$(dbus get merlinclash_clash_version_tmp)
    MC_OLD_BINARY_VER=$(dbus get merlinclash_binary_ver)
    mc_update_stage_file "$1" "$MC_SOFT/bin/clash" || return 1
    chmod 755 "$MC_UPDATE_STAGE/candidate" || return 1
    mc_update_validate_core "$MC_UPDATE_STAGE/candidate" || { mc_update_log 'Candidate engine or profile validation failed; current engine retained.'; return 1; }
    [ -z "$(mc_core_pids)" ] || MC_UPDATE_RUNNING=1
    if [ "$MC_UPDATE_RUNNING" = 1 ]; then
        [ -n "$_mc_runtime" ] && [ "$(readlink -f "$_mc_runtime")" = "$(readlink -f "$MC_DATA/yaml_use/$_mc_name.yaml")" ] || {
            mc_update_log 'Active engine and selected profile differ; apply the profile selection before replacing its engine.'
            return 1
        }
    fi
    _mc_enabled=$(dbus get merlinclash_enable)
    _mc_recovery=$(dbus get merlinclash_recovery_wanted)
    # A live engine with intentional Off is inconsistent; do not restart it.
    if [ "$MC_UPDATE_RUNNING" = 1 ] && [ "$_mc_enabled" != 1 ] && [ "$_mc_recovery" != 1 ]; then
        mc_update_log 'Engine is running while the plugin is Off; defer replacement.'
        return 1
    fi
    if [ "$MC_UPDATE_RUNNING" = 1 ]; then
        # The controller cannot snapshot an engine already stopped by this
        # transaction. Save its current choices while the old API is available.
        _mc_capture_profile=$(mc_active_name) || return 1
        [ "$_mc_capture_profile" = "$_mc_name" ] || {
            mc_update_log 'Active profile changed before selector capture; engine retained.'
            return 1
        }
        sh "$MC_SOFT/scripts/clash_node_mark.sh" setmark || {
            mc_update_log 'Current selectors could not be saved; engine retained.'
            return 1
        }
        [ "$(dbus get merlinclash_stop_token)" = "$MC_UPDATE_STOP_TOKEN" ] || {
            mc_update_log 'A stop request interrupted selector capture; engine retained.'
            return 1
        }
        # A contending Off can make the helper intentionally skip its capture.
        # Only an enabled, successfully captured running profile supplies freshness.
        if [ "$(dbus get merlinclash_enable)" = 1 ]; then MC_FRESH_MARK_PROFILE=$_mc_capture_profile; fi
    fi
    dbus set merlinclash_maintenance=1 || return 1
    MC_UPDATE_MAINTENANCE=1
    if [ "$MC_UPDATE_RUNNING" = 1 ]; then
        MC_UPDATE_STOPPED=1
        mc_update_stop_core || return 1
    fi
    MC_UPDATE_REPLACED=1
    mv -f "$MC_UPDATE_STAGE/candidate" "$MC_UPDATE_DEST" || return 1
    if [ "$MC_UPDATE_RUNNING" = 1 ]; then
        mc_update_restart || { mc_update_log 'Replacement did not become healthy; rolling back.'; return 1; }
    fi
    dbus set "merlinclash_clash_version=$MC_UPDATE_VERSION" || return 1
    dbus set "merlinclash_clash_version_tmp=$MC_UPDATE_VERSION" || return 1
    dbus set "merlinclash_binary_ver=$MC_UPDATE_VERSION" || return 1
    MC_UPDATE_COMMITTED=1
    mc_update_log 'Engine replacement verified successfully.'
}

mc_update_subconverter() {
    _mc_dest=$MC_DATA/subconverter/subconverter
    mc_update_stage_file "$1" "$_mc_dest" || return 1
    chmod 755 "$MC_UPDATE_STAGE/candidate" || return 1
    mc_update_run "$MC_UPDATE_STAGE/candidate" -v || return 1
    grep -Eqi '^subconverter[[:space:]]+v?[0-9]+\.[0-9]+' "$MC_UPDATE_TMP/probe-output" || return 1
    # Atomic executable replacement preserves any already running old instance.
    MC_UPDATE_REPLACED=1
    mv -f "$MC_UPDATE_STAGE/candidate" "$_mc_dest" || return 1
    MC_UPDATE_COMMITTED=1
    mc_update_log 'Subconverter version validated and executable replaced.'
}

mc_update_publish_data() {
    mc_update_stage_file "$1" "$2" || return 1
    chmod 644 "$MC_UPDATE_STAGE/candidate" || return 1
    # Invalidating a derived cache before publish is safe even if rename fails:
    # it is rebuilt from the unchanged old source on the next startup.
    [ -z "$3" ] || rm -f "$3" || return 1
    mv -f "$MC_UPDATE_STAGE/candidate" "$2" || return 1
    rm -rf "$MC_UPDATE_STAGE" || return 1
    MC_UPDATE_STAGE=
    MC_UPDATE_DEST=
}
