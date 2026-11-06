#!/bin/bash
# usage: test.sh <key> <debug|release> <logname> <swift test args...>
K=$1; M=$2; N=$3; shift 3
WT=/Users/admin/Documents/ZTronAssetKit/.build-s3f-j-c2live-$K-wt
L=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-design/j-c2live/logs/$N.log
if [ $M = debug ]; then S=.build-x; X=""; else S=.build-x-rel; X="-c release -Xswiftc -enable-testing"; fi
export TMPDIR=$WT/$S/tmp/ CLANG_MODULE_CACHE_PATH=$WT/$S/tmp/mc
cd $WT
echo "load before: $(date +%T) $(sysctl -n vm.loadavg)" > $L.load
start=$(date +%s)
swift test $X --scratch-path $S --skip-build "$@" > $L 2>&1
rc=$?
echo "load after: $(date +%T) $(sysctl -n vm.loadavg)" >> $L.load
echo "TEST $K $N exit $rc in $(( $(date +%s) - start )) s" | tee -a $L.load
