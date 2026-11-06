#!/bin/bash
cd /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=.build-verify-s3f-c6-reqs
export TMPDIR=$PWD/$S/tmp/ CLANG_MODULE_CACHE_PATH=$PWD/$S/tmp/mc LLVM_PROFILE_FILE=$PWD/$S/tmp/prof-%p.profraw
L=$S/logs
ts(){ echo "[$(date +%H:%M:%S) load $(sysctl -n vm.loadavg)] $*" >> $L/tsan.timeline; }
ts build-start
swift build --build-tests --scratch-path .build-verify-s3f-c6-reqs-tsan --sanitize=thread > $L/tsan-build.log 2>&1; ts "tsan build exit $?"
( while true; do echo "$(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $L/tsan-load.log; sleep 10; done ) &
LP=$!
ts tsan-test-start
swift test --scratch-path .build-verify-s3f-c6-reqs-tsan --sanitize=thread --skip Benchmarks --filter ZTronAssetSyncTests > $L/tsan.log 2>&1; ts "tsan test exit $?"
kill $LP
ts DONE
