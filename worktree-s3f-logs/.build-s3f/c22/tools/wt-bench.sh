#!/bin/bash
# Runs release benchmark filters in the worktree (already built into .build-s3f-perf), one after another: $1 a tag
# prefix, then "tag=filter" pairs. Each waits (at most 30 minutes) for a 1-minute load of 10 or less, runs with a
# watchdog, and records the loads before and after.
source /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-s3f/c20/env.sh
C=$W/.build-s3f/c22
prefix=$1; shift 1
out=$C/each/$prefix.out
echo "start $(date +%H:%M:%S) load $(sysctl -n vm.loadavg) HEAD $(git -C $W rev-parse --short HEAD)" >> $out
for pair in "$@"; do
  tag=${pair%%=*}; rest=${pair#*=}
  waited=0
  while python3 -c "import os,sys; sys.exit(0 if os.getloadavg()[0] <= 10 else 1)"; [ $? -ne 0 ] && [ $waited -lt 1800 ]; do
    python3 -c "import time; time.sleep(5)"; waited=$((waited+5))
  done
  log=$C/each/$prefix-$tag.log
  echo "$tag: start $(date +%H:%M:%S) after ${waited}s wait, load $(sysctl -n vm.loadavg)" >> $out
  (cd $W && swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --skip-build --filter "$rest" > "$log" 2>&1) &
  pid=$!
  secs=0
  while kill -0 $pid 2>/dev/null; do
    python3 -c "import time; time.sleep(2)"; secs=$((secs+2))
    if [ $secs -ge 2400 ]; then echo "$tag: HUNG after ${secs}s" >> $out; pkill -P $pid; kill $pid; break; fi
  done
  echo "$tag: end $(date +%H:%M:%S) load $(sysctl -n vm.loadavg); $(grep -a 'Test run with' $log | tail -1)" >> $out
done
echo "done $(date +%H:%M:%S)" >> $out
