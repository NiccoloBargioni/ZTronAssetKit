#!/bin/bash
# usage: relprobes.sh <tag> <filter> [env assignments...]
cd /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c20-correct/probesrc
export TMPDIR=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c20-correct/tmp
tag=$1; filter=$2; shift 2
for kv in "$@"; do export "$kv"; done
L=../logs/rel-$tag.log
echo "start $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" > $L.meta
export PROBE_LOAD="$(sysctl -n vm.loadavg)"
swift test -c release --skip-build --scratch-path ../pbrel -Xswiftc -enable-testing --filter "$filter" > $L 2>&1
echo "end rc=$? $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $L.meta
grep -E 'PROBE-|Test run with|✘|error' $L | cut -c1-400 | head -40
