#!/bin/bash
# Runs release benchmark filters from a scratch copy, one after another: $1 copy dir, $2 its scratch path, $3 a tag
# prefix, then "tag=filter" (or "tag=ENV=1:filter") pairs. Each waits (at most 30 minutes) for a 1-minute load of 10
# or less, runs under a pty with a watchdog, and records the loads before and after.
source /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-s3f/c20/env.sh
C=$W/.build-s3f/c22
copy=$1; scratch=$2; prefix=$3; shift 3
out=$C/each/$prefix.out
echo "start $(date +%H:%M:%S) load $(sysctl -n vm.loadavg)" >> $out
for pair in "$@"; do
  tag=${pair%%=*}; rest=${pair#*=}
  envset=""
  if [[ "$rest" == *":"* ]]; then envset=${rest%%:*}; rest=${rest#*:}; fi
  waited=0
  while python3 -c "import os,sys; sys.exit(0 if os.getloadavg()[0] <= 10 else 1)"; [ $? -ne 0 ] && [ $waited -lt 1800 ]; do
    python3 -c "import time; time.sleep(5)"; waited=$((waited+5))
  done
  log=$C/each/$prefix-$tag.log
  echo "$tag: start $(date +%H:%M:%S) after ${waited}s wait, load $(sysctl -n vm.loadavg)" >> $out
  (cd $C/$copy && env $envset script -q "$log" swift test -c release --scratch-path $C/$scratch -Xswiftc -enable-testing --skip-build --filter "$rest" > /dev/null 2>&1) &
  pid=$!
  secs=0
  while kill -0 $pid 2>/dev/null; do
    python3 -c "import time; time.sleep(2)"; secs=$((secs+2))
    if [ $secs -ge 2400 ]; then echo "$tag: HUNG after ${secs}s" >> $out; pkill -P $pid; kill $pid; break; fi
  done
  echo "$tag: end $(date +%H:%M:%S) load $(sysctl -n vm.loadavg); $(grep -a 'Test run with' $log | tail -1)" >> $out
done
echo "done $(date +%H:%M:%S)" >> $out
