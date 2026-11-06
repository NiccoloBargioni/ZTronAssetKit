#!/bin/bash
# Runs the hang probe's swift test with a scoped watchdog: only this script's own descendants are killed.
S=/Users/admin/Documents/ZTronAssetKit/.build-s3-confirm-stability
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/mc-hang SWIFTPM_MODULECACHE_OVERRIDE=$S/tmp/mc-hang
LIMIT=${1:-150}
cd $S/hangprobe
swift test --scratch-path $S/hangprobe-build > $S/hangprobe-run.log 2>&1 &
PID=$!
START=$(date +%s)
while kill -0 $PID 2>/dev/null; do
  NOW=$(date +%s)
  if [ $((NOW - START)) -ge $LIMIT ]; then
    echo "STILL RUNNING after ${LIMIT}s (pid $PID): descendants:"
    pgrep -P $PID | while read c; do ps -o pid=,command= -p $c | cut -c1-160; pgrep -P $c | while read g; do ps -o pid=,command= -p $g | cut -c1-160; done; done
    for c in $(pgrep -P $PID); do pkill -TERM -P $c; kill -TERM $c; done; kill -TERM $PID
    sleep 2; kill -0 $PID 2>/dev/null && kill -KILL $PID
    exit 2
  fi
  sleep 2
done
wait $PID; echo "swift test exited $? after $(( $(date +%s) - START ))s"
