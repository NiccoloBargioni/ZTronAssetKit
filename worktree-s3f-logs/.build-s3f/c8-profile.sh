#!/bin/bash
# usage: c8-profile.sh <tag> <filter> ; runs one TSan test alone, samples it 3 times for 15 s
WT=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
cd $WT
TAG=$1; F=$2
echo "start $(date +%T) $(sysctl -n vm.loadavg)" > .build-s3f/logs/c8-$TAG-time.log
bash .build-s3f/run-direct.sh .build-s3f-tsan ZTronAssetSyncTests .build-s3f/logs/c8-$TAG.log --filter "$F" &
RUNNER=$!
sleep 8
PID=$(pgrep -n -f "swiftpm-testing-helper --test-bundle-path .build-s3f-tsan")
for i in 1 2 3; do
  [ -n "$PID" ] && sample $PID 15 -file .build-s3f/logs/c8-$TAG-sample-$i.txt > /dev/null 2>&1
done
wait $RUNNER
echo "end $(date +%T) $(sysctl -n vm.loadavg)" >> .build-s3f/logs/c8-$TAG-time.log
