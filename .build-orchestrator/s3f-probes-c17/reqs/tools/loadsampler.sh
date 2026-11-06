#!/bin/bash
# Samples the 1-minute load average every 5 s until the stop file exists.
OUT="$1"; STOP="$2"
while [ ! -f "$STOP" ]; do
  echo "$(date +%s) $(date +%H:%M:%S) $(sysctl -n vm.loadavg | awk '{print $2}')" >> "$OUT"
  sleep 5
done
