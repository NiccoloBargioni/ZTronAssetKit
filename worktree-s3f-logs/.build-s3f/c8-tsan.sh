#!/bin/bash
# usage: c7-tsan.sh <tag> <n bundles>
WT=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
TAG=$1; N=$2
cd $WT
( while true; do echo "$(date +%H:%M:%S) $(sysctl -n vm.loadavg)"; sleep 5; done ) > .build-s3f/c8-$TAG-load.log 2>&1 &
SAMPLER=$!
echo "start $(date +%H:%M:%S)" > .build-s3f/c8-$TAG-timeline.log
PIDS=""
for i in $(seq 1 $N); do
  bash .build-s3f/run-direct.sh .build-s3f-tsan ZTronAssetSyncTests .build-s3f/c8-$TAG-$i.log &
  PIDS="$PIDS $!"
done
for p in $PIDS; do wait $p; done
echo "end $(date +%H:%M:%S)" >> .build-s3f/c8-$TAG-timeline.log
kill $SAMPLER
