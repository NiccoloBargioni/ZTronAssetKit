#!/bin/bash
cd /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=.build-verify-s3f-c20-correct
export TMPDIR=$PWD/$S/tmp
SIM=5B940E6E-490F-4E9E-A917-A6456A18225E
echo "rep start $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" > $S/logs/simrep.meta
caffeinate -i xcodebuild test-without-building -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $S/xcode-sim "-only-testing:ZTronAssetSyncTests/EngineFollowBarrierTests/barrierReadmitsBehindTheOwedVisitsPlaces(_:)" -test-iterations 30 -collect-test-diagnostics never -resultBundlePath $S/flake/sim-rep30.xcresult > $S/logs/sim-rep30.log 2>&1
echo "rep end rc=$? $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $S/logs/simrep.meta
xcrun xcresulttool get test-results summary --path $S/flake/sim-rep30.xcresult > $S/flake/sim-rep30-summary.json 2>&1
echo "summary rc=$?" >> $S/logs/simrep.meta
