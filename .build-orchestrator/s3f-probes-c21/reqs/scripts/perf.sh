#!/bin/bash
# Builds the release benchmarks, then runs them alone, logging start/end loads.
cd /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=$PWD/.build-verify-s3f-c21-reqs
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/modcache
echo "build start $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" > $S/logs/perf-times.txt
swift build -c release --scratch-path .build-verify-s3f-c21-reqs-perf -Xswiftc -enable-testing --build-tests > $S/logs/perf-build.log 2>&1
echo "build exit $? $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $S/logs/perf-times.txt
echo "bench start $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $S/logs/perf-times.txt
swift test -c release --scratch-path .build-verify-s3f-c21-reqs-perf -Xswiftc -enable-testing --filter Benchmarks --skip-build > $S/logs/perf-run.log 2>&1
echo "bench exit $? $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $S/logs/perf-times.txt
