#!/bin/bash
# Watchdog for the mutant lane only: a mutbuild test helper past 6 minutes (the item tests' limits are at most 3, the
# whole-suite spot checks are exempt) is a hang; stop it by PID and log it.
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c21-reqs
while ! grep -q "mutall done" $S/logs/mut/summary.txt 2>/dev/null; do
  if ! grep -q "f7-delisted-stays: build" $S/logs/mut/summary.txt 2>/dev/null; then
    ps -axo pid=,etime=,command= | grep "swiftpm-testing-helper" | grep "c21-reqs/mutbuild" | grep -v grep | while read pid et rest; do
      secs=$(echo "$et" | awk -F'[-:]' '{ if (NF==2) print $1*60+$2; else if (NF==3) print $1*3600+$2*60+$3; else print 99999 }')
      if [ "$secs" -gt 360 ]; then
        kill "$pid" 2>/dev/null && echo "$(date +%H:%M:%S) watchdog stopped hung mutant test helper $pid after ${et}" >> $S/logs/mut/summary.txt
      fi
    done
  fi
  sleep 15
done
