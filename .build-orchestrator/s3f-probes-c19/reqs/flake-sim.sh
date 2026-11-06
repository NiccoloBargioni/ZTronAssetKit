#!/bin/bash
# Re-runs the simulator's failing test alone on MY simulator, repeated (scratch only), under the sim lock.
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=$W/.build-verify-s3f-c19-reqs
LOCK=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/sim.lock
SIM=6BE15CAF-7E02-4060-9338-9DAC025EDF0B
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/modcache
cd $W || exit 2
F=$S/logs/flake
T=$F/times.txt
stamp() { echo "$(date +%H:%M:%S) $1 load $(sysctl -n vm.loadavg)" >> $T; }
stamp "sim waiting for lock"
until mkdir $LOCK 2>/dev/null; do sleep 15; done
stamp "sim lock taken"
bash $S/loadsampler.sh $F/sim-load.txt 5 & SAMPLER=$!
caffeinate -i xcodebuild test-without-building -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-verify-s3f-c19-reqs/xcode-sim "-only-testing:ZTronAssetSyncTests/EngineFollowBarrierTests/barrierReadmitsBehindTheOwedVisitsPlaces(_:)" -test-iterations 30 -collect-test-diagnostics never -resultBundlePath $F/sim-rep30.xcresult > $F/sim-rep30.log 2>&1
stamp "sim rep30 exit $?"
kill $SAMPLER 2>/dev/null; wait $SAMPLER 2>/dev/null
xcrun simctl shutdown $SIM >> $F/sim-shutdown.log 2>&1
echo "shutdown exit $?" >> $F/sim-shutdown.log
xcrun simctl list devices | grep $SIM >> $F/sim-shutdown.log 2>&1
rmdir $LOCK
stamp "sim lock released"
xcrun xcresulttool get test-results summary --path $F/sim-rep30.xcresult > $F/sim-rep30-summary.json 2>&1
xcrun xcresulttool get test-results tests --path $F/sim-rep30.xcresult > $F/sim-rep30-tests.json 2>&1
stamp "sim done"
