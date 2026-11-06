#!/bin/bash
# usage: run-rel.sh <scratch-dir-name> <log> <filter> [--skip-build]   release + -enable-testing; records the 1-minute load before and after
WT=/Users/admin/Documents/ZTronAssetKit/.build-s3f-d-root-wt
S=$1; LOG=$2; FILTER=$3; shift 3
mkdir -p $WT/$S/tmp/mc
export TMPDIR=$WT/$S/tmp/ CLANG_MODULE_CACHE_PATH=$WT/$S/tmp/mc
cd $WT
echo "load before: $(date +%T) $(sysctl -n vm.loadavg)" > $LOG.load
swift test -c release --scratch-path $S -Xswiftc -enable-testing "$@" --filter "$FILTER" > $LOG 2>&1
RC=$?
echo "load after: $(date +%T) $(sysctl -n vm.loadavg)" >> $LOG.load
echo "exit $RC"
