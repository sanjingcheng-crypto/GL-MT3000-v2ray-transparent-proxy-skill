#!/bin/sh
# xray watchdog: second-layer safety net behind the supervisor loop in
# xray_standalone.sh. If the xray process is not running (e.g. supervisor
# subshell itself was killed), restart everything via the standalone script.
# Installed as a cron job (every minute) and survives router reboots because
# crond is enabled.
if ! pgrep -f 'xray run' >/dev/null 2>&1; then
  echo "[watchdog $(date)] xray not running, invoking xray_standalone.sh" >>/var/log/xray_watchdog.log
  /usr/bin/xray_standalone.sh >>/var/log/xray_watchdog.log 2>&1
fi
