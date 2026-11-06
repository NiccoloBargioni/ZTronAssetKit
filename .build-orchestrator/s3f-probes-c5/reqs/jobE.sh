#!/bin/bash
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c5-reqs
export TMPDIR=$S/tmp/ CLANG_MODULE_CACHE_PATH=$S/tmp/mc
ts(){ echo "[$(date +%H:%M:%S) $(sysctl -n vm.loadavg)] $*" >> $S/logs/jobE.timeline; }
cd $S/pkg
ts probe-head start
swift test -c release --skip-build --scratch-path $S/pkg-perf --filter VerifyC4CorrectBench2 > $S/logs/probe-head.log 2>&1; ts "probe-head exit $?"
cd $S/pkg2
ts probe-prefix start
swift test -c release --skip-build --scratch-path $S/pkg2-perf --filter VerifyC4CorrectBench2 > $S/logs/probe-prefix.log 2>&1; ts "probe-prefix exit $?"
ts bench-prefix start
swift test -c release --skip-build --scratch-path $S/pkg2-perf --filter reclaimDuringFollowTurns > $S/logs/bench-prefix.log 2>&1; ts "bench-prefix exit $?"
cd $S/pkg
ts bench-head-pkg start
swift test -c release --skip-build --scratch-path $S/pkg-perf --filter reclaimDuringFollowTurns > $S/logs/bench-head-pkg.log 2>&1; ts "bench-head-pkg exit $?"
ts DONE
