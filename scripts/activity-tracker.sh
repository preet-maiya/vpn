#!/usr/bin/env bash
# Simple loop that observes iptables forward counters and updates last activity timestamp.
set -euo pipefail
TS_FILE=/var/lib/activity/last_activity
mkdir -p $(dirname "$TS_FILE")
[ -f "$TS_FILE" ] || date +%s > "$TS_FILE"
prev=$(iptables -nvx -L FORWARD 2>/dev/null | awk 'NR==3 {print $2 "+" $3}')
while true; do
  sleep 60
  curr=$(iptables -nvx -L FORWARD 2>/dev/null | awk 'NR==3 {print $2 "+" $3}')
  if [ "$curr" != "$prev" ]; then
    date +%s > "$TS_FILE"
    prev=$curr
  fi
done
