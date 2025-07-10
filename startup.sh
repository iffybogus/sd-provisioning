#!/bin/bash

# Persistent loop to monitor instance health and shut down if outbid
WATCH_INTERVAL=30
MAX_FAILURES=3
FAIL_COUNT=0
URL_FILE="/workspace/share_url.txt"

while true; do
  if [ -s "$URL_FILE" ]; then
    SHARE_URL=$(cat "$URL_FILE")
    if curl --max-time 5 -s "$SHARE_URL" > /dev/null; then
      echo "[watchdog] Instance healthy — $SHARE_URL"
      FAIL_COUNT=0
    else
      echo "[watchdog] URL ping failed"
      ((FAIL_COUNT++))
    fi
  else
    echo "[watchdog] No URL found — counting as failure"
    ((FAIL_COUNT++))
  fi

  if [ "$FAIL_COUNT" -ge "$MAX_FAILURES" ]; then
    echo "[watchdog] Instance failed health check $MAX_FAILURES times — shutting down"
    shutdown -h now
    break
  fi

  sleep "$WATCH_INTERVAL"
done
