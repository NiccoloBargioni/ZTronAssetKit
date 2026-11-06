#!/bin/bash
# usage: build.sh <key> <debug|release> ; logs to j-c2live/logs/build-<key>-<mode>.log
K=$1; M=$2
WT=/Users/admin/Documents/ZTronAssetKit/.build-s3f-j-c2live-$K-wt
L=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-design/j-c2live/logs/build-$K-$M.log
if [ $M = debug ]; then S=.build-x; else S=.build-x-rel; fi
mkdir -p $WT/$S/tmp/mc
export TMPDIR=$WT/$S/tmp/ CLANG_MODULE_CACHE_PATH=$WT/$S/tmp/mc
cd $WT
start=$(date +%s)
if [ $M = debug ]; then
  swift build --build-tests --scratch-path $S -Xswiftc -warnings-as-errors > $L 2>&1
else
  swift build -c release --build-tests --scratch-path $S -Xswiftc -enable-testing > $L 2>&1
fi
rc=$?
echo "BUILD $K $M exit $rc in $(( $(date +%s) - start )) s" >> $L
echo "BUILD $K $M exit $rc in $(( $(date +%s) - start )) s"
