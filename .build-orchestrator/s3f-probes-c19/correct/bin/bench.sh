#!/bin/bash
# Scratch runner: release benchmarks with a 5 s load sampler.
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=$W/.build-verify-s3f-c19-correct
L=$S/logs
cd "$W" || exit 2
: > "$L/bench-load.txt"
touch "$L/bench.running"
( while [ -f "$L/bench.running" ]; do echo "$(date '+%s') $(sysctl -n vm.loadavg)" >> "$L/bench-load.txt"; sleep 5; done ) &
echo "start $(date '+%H:%M:%S') epoch $(date '+%s') load $(sysctl -n vm.loadavg)" > "$L/bench.log"
TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/modcache swift test -c release --skip-build --scratch-path .build-verify-s3f-c19-correct-perf -Xswiftc -enable-testing --filter Benchmarks >> "$L/bench.log" 2>&1
rc=$?
echo "exit $rc end $(date '+%H:%M:%S') epoch $(date '+%s') load $(sysctl -n vm.loadavg)" >> "$L/bench.log"
rm -f "$L/bench.running"
wait
exit $rc
