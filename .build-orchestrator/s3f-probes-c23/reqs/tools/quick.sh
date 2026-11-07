#!/bin/bash
# Cycle-23 reqs verifier: verify.sh --quick on MY scratch path, then the coverage export/gate/S1 lines from its
# profile, all under sim.lock (a coverage run); copies .verify-logs' step logs to my logs; releases the lock.
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
R=$W/.build-verify-s3f-c23-reqs
L=$R/logs
T=$R/tmp
LOCK=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/sim.lock
stamp() { echo "$(date +%H:%M:%S) $1 load $(sysctl -n vm.loadavg)" >> $L/quick.times; }
cd $W || exit 1
stamp "start head $(git rev-parse --short HEAD) dirty $(git status --short | wc -l | tr -d ' ')"
until mkdir $LOCK 2>/dev/null; do sleep 15; done
echo "s3f cycle-23 reqs verifier: verify --quick + coverage export, taken $(date +%H:%M:%S)" > $LOCK/owner
stamp "lock taken"
( while [ ! -e $L/quick.stop ]; do echo "$(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $L/quick-load.txt; sleep 10; done ) &
TMPDIR=$T CLANG_MODULE_CACHE_PATH=$T/module-cache LLVM_PROFILE_FILE=$T/q-%p.profraw SWIFTPM_SCRATCH=.build-verify-s3f-c23-reqs bash Scripts/verify.sh --quick > $L/quick.log 2>&1
stamp "quick rc=$?"
mkdir -p $L/quick-logs && cp .verify-logs/harness.log .verify-logs/toolchain.log .verify-logs/build-debug.log .verify-logs/tests.log $L/quick-logs/ 2>/dev/null
TMPDIR=$T bash $R/tools/cov.sh > $L/cov.log 2>&1
stamp "cov rc=$?"
touch $L/quick.stop
rm -rf $LOCK
stamp "lock released dirty $(git status --short | wc -l | tr -d ' ')"
