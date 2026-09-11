#!/bin/sh
# xray_healthcheck.sh — periodic health probe + auto-restart of a degraded xray process
# What it does:
#   Probe baidu through the local proxy port (which exercises the DIRECT outbound).
#   If HTTP code != 200 OR latency > THRESH_MS => kill the xray run main process.
#   The supervisor (xray_standalone.sh) auto-respawns it from the same config => clean restart.
# Designed to run from cron every minute. A cooldown window avoids false kills during cold start.
#
# Usage:
#   sh /usr/bin/xray_healthcheck.sh            # normal probe
#   sh /usr/bin/xray_healthcheck.sh force-kill # manually kill xray run once (for testing the restart loop)

SOCKS="socks5h://127.0.0.1:20170"
URL="https://www.baidu.com"
THRESH_MS=2000
LOCK="/tmp/.xray_hc_ts"
LOG="/tmp/xray_health.log"

# Manual test mode: kill xray run once, let supervisor respawn.
if [ "$1" = "force-kill" ]; then
  echo "[$(date)] FORCE-KILL (manual test) -> kill xray run" >>"$LOG"
  echo "$(date +%s)" >"$LOCK"
  for PID in $(pgrep -f 'config.fixed.json'); do
    kill -9 "$PID" 2>/dev/null
  done
  exit 0
fi

# xray main process not running? Leave it to the supervisor, do nothing.
if ! pgrep -f 'config.fixed.json' >/dev/null 2>&1; then
  exit 0
fi

# Cooldown: do not probe/kill within 120s after a restart (avoids cold-start jitter false kills).
now=$(date +%s)
if [ -f "$LOCK" ]; then
  last=$(cat "$LOCK" 2>/dev/null)
  if [ -n "$last" ]; then
    if [ $((now - last)) -lt 120 ]; then
      exit 0
    fi
  fi
fi

# Probe (use curl's own time_total so we don't depend on date %N).
out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" --connect-timeout 3 -m 3 -x "$SOCKS" "$URL" 2>/dev/null)
code=$(echo "$out" | awk '{print $1}')
tt=$(echo "$out" | awk '{print $2}')
if [ -z "$tt" ]; then
  cost=999999
else
  cost=$(echo "$tt" | awk '{printf "%d", $1 * 1000}')
fi

if [ "$code" != "200" ] || [ "$cost" -gt "$THRESH_MS" ]; then
  echo "[$(date)] FAIL code=$code cost=${cost}ms thr=${THRESH_MS}ms -> kill xray run" >>"$LOG"
  echo "$now" >"$LOCK"
  for PID in $(pgrep -f 'config.fixed.json'); do
    kill -9 "$PID" 2>/dev/null
  done
fi
