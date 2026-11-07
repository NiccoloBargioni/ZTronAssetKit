#!/bin/bash
# Cycle-23 reqs verifier: the iOS Simulator suite on MY simulator only (6BE15CAF..., iOS 27.0), then A-T-SD's 30
# iterations per argument, both under sim.lock; shuts the simulator down and releases the lock.
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
R=$W/.build-verify-s3f-c23-reqs
L=$R/logs
T=$R/tmp
SIM=6BE15CAF-7E02-4060-9338-9DAC025EDF0B
LOCK=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/sim.lock
export TMPDIR=$T CLANG_MODULE_CACHE_PATH=$T/module-cache LLVM_PROFILE_FILE=$T/sim-%p.profraw
stamp() { echo "$(date +%H:%M:%S) $1 load $(sysctl -n vm.loadavg)" >> $L/sim.times; }
cd $W || exit 1
stamp "start head $(git rev-parse --short HEAD) dirty $(git status --short | wc -l | tr -d ' ')"
caffeinate -i xcodebuild build-for-testing -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-verify-s3f-c23-reqs/xcode-sim OTHER_SWIFT_FLAGS='-warnings-as-errors' > $L/sim-build.log 2>&1
stamp "build-for-testing rc=$?"
stamp "waiting for lock"
until mkdir $LOCK 2>/dev/null; do sleep 15; done
echo "s3f cycle-23 reqs verifier: iOS Simulator suite + A-T-SD x30 on $SIM, taken $(date +%H:%M:%S)" > $LOCK/owner
stamp "lock taken"
( while [ ! -e $L/sim.stop ]; do echo "$(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $L/sim-load.txt; sleep 5; done ) &
caffeinate -i xcodebuild test -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-verify-s3f-c23-reqs/xcode-sim -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never OTHER_SWIFT_FLAGS='-warnings-as-errors' > $R/sim.log 2>&1
stamp "suite rc=$?"
caffeinate -i xcodebuild test-without-building -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-verify-s3f-c23-reqs/xcode-sim -only-testing:"ZTronAssetSyncTests/EngineFollowBarrierTests/shutdownClearsTheJoinsBehindAVerdict(_:)" -test-iterations 30 -collect-test-diagnostics never > $L/sim-atsd30.log 2>&1
stamp "atsd x30 rc=$?"
touch $L/sim.stop
xcrun simctl shutdown $SIM > $L/sim-shutdown.log 2>&1; echo "shutdown exit $?" >> $L/sim-shutdown.log
rm -rf $LOCK
stamp "lock released"
for b in $(ls -d $R/xcode-sim/Logs/Test/*.xcresult 2>/dev/null); do
  echo "== $b" >> $L/sim-summaries.txt
  xcrun xcresulttool get test-results summary --path "$b" >> $L/sim-summaries.txt 2>&1
done
stamp "done dirty $(git status --short | wc -l | tr -d ' ')"
