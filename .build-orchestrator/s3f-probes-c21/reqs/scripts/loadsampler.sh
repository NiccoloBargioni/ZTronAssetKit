#!/bin/bash
# Samples the 1/5/15-minute load averages every 5 s into the given file.
out="$1"
while true; do
  echo "$(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> "$out"
  sleep 5
done
