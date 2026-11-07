#!/bin/bash
# Cycle-23 reqs verifier: release Benchmarks run (perf scratch path), load sampled every 5 s.
# Usage: bash bench.sh <tag> <filter>
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
R=$W/.build-verify-s3f-c23-reqs
T=$R/tmp
TAG="$1"
FILTER="${2:-Benchmarks}"
cd "$W" || exit 1
(while true; do echo "$(date '+%H:%M:%S') $(sysctl -n vm.loadavg)"; sleep 5; done) > "$R/logs/bench-$TAG-load.txt" 2>&1 &
LP=$!
echo "start $(date '+%H:%M:%S') load $(sysctl -n vm.loadavg) head $(git rev-parse --short HEAD)" > "$R/logs/bench-$TAG.times"
TMPDIR=$T CLANG_MODULE_CACHE_PATH=$T/module-cache LLVM_PROFILE_FILE=$T/prof-%p.profraw \
  swift test -c release --scratch-path .build-verify-s3f-c23-reqs-perf -Xswiftc -enable-testing --filter "$FILTER" > "$R/logs/bench-$TAG.log" 2>&1
rc=$?
kill $LP
echo "end $(date '+%H:%M:%S') load $(sysctl -n vm.loadavg) rc=$rc" >> "$R/logs/bench-$TAG.times"
