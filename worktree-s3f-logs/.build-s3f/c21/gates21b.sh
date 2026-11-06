#!/bin/bash
# Cycle 21's gate run on the final code (step 8), again on the HEAD after the reservation-edge fix (a380c78, e599ae1):
# every stage stamped with the three load averages (S3-R23 item 1) and the whole run sampled every 5 s; then
# post21.sh's stages (the APM probe, S3-R13's tools-6.4 export, the Sync bundle twice more under coverage).
# The release benchmarks run first, under sim.lock, once the 1-minute load is 10 or less (S3-R23), before this run's
# own builds and suites raise the load.
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
source $W/.build-s3f/c20/env.sh
G=$W/.build-s3f/c21/gates-b
mkdir -p $G
T=$G/times.txt
LOCK=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/sim.lock
SIM=897F9D8D-B10D-4D91-8E22-417A2B9D70AA
stamp() { echo "$(date +%H:%M:%S) $1 load $(sysctl -n vm.loadavg)" >> $T; }
sampler() { while true; do echo "$(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $1; sleep 5; done; }
takelock() {
    stamp "$1 waiting for lock"
    until mkdir $LOCK 2>/dev/null; do
        sleep 15
    done
    echo "s3f WP-F gates $1 $(date +%H:%M:%S)" > $LOCK/owner
    stamp "$1 lock taken"
}
quiet() {
    local waited=0
    while :; do
        one=$(sysctl -n vm.loadavg | awk '{print $2}')
        if python3 -c "import sys; sys.exit(0 if float('$one') <= 10.0 else 1)"; then break; fi
        if [ $waited -ge 1800 ]; then stamp "$1 no quiet load after ${waited}s"; break; fi
        sleep 20; waited=$((waited+20))
    done
    stamp "$1 quiet after ${waited}s"
}
: > $T
sampler $G/all-load.txt & ALL=$!
stamp "start head $(git rev-parse --short HEAD) dirty $(git status --short | wc -l | tr -d ' ')"
swift build -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --build-tests > $G/bench-build.log 2>&1; rc=$?; stamp "bench build exit $rc"
takelock bench
quiet bench
sampler $G/bench-load.txt & SAMP=$!
swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter Benchmarks > $G/bench.log 2>&1; rc=$?; stamp "bench exit $rc"
kill $SAMP; wait $SAMP 2>/dev/null
rm -rf $LOCK; stamp "bench lock released"
SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick > $G/quick.log 2>&1; rc=$?; stamp "quick exit $rc"
swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors > $G/release.log 2>&1; rc=$?; stamp "release exit $rc"
python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md > $G/unsafe.log 2>&1; rc=$?; stamp "unsafe exit $rc"
python3 Scripts/gates.py docs --sources "$PWD/Sources" > $G/docs.log 2>&1; rc=$?; stamp "docs exit $rc"
for i in 1 2 3; do
    swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests > $G/sync$i.log 2>&1; rc=$?; stamp "sync$i exit $rc"
done
swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter ZTronAssetSyncTests > $G/tsan.log 2>&1; rc=$?; stamp "tsan exit $rc"
xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet > $G/ios.log 2>&1; rc=$?; stamp "ios exit $rc"
takelock coverage
sampler $G/cov-load.txt & SAMP=$!
swift test --scratch-path .build-s3f --enable-code-coverage --skip Benchmarks > $G/cov.log 2>&1; rc=$?; stamp "cov exit $rc"
cp .build-s3f/out/Products/Debug/codecov/default.profdata $G/cov.profdata
BINS=$(ls -d .build-s3f/out/Products/Debug/*.xctest | grep -v Benchmarks)
FIRST=""; OBJS=""
for b in $BINS; do n=$(basename $b .xctest); if [ -z "$FIRST" ]; then FIRST=$b/Contents/MacOS/$n; else OBJS="$OBJS -object $b/Contents/MacOS/$n"; fi; done
xcrun llvm-cov export -summary-only -instr-profile $G/cov.profdata $FIRST $OBJS > $G/cov.json 2> $G/cov-export.err; rc=$?; stamp "cov export exit $rc"
cp $G/cov.json .build-s3f/cov.json
python3 Scripts/gates.py coverage --json .build-s3f/cov.json > $G/cov-gate.log 2>&1; rc=$?; stamp "cov gate exit $rc"
kill $SAMP; wait $SAMP 2>/dev/null
rm -rf $LOCK; stamp "coverage lock released"
takelock simulator
sampler $G/sim-load.txt & SAMP=$!
caffeinate -i xcodebuild test -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-s3f/xcode-sim -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never -resultBundlePath $G/sim.xcresult OTHER_SWIFT_FLAGS='-warnings-as-errors' > .build-s3f/sim.log 2>&1; rc=$?; stamp "sim test exit $rc"
cp .build-s3f/sim.log $G/sim.log
caffeinate -i xcodebuild test-without-building -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-s3f/xcode-sim "-only-testing:ZTronAssetSyncTests/EngineFollowBarrierTests/barrierMakesAMoveOntoAJobItsDrainedPublicationReQueued(_:)" "-only-testing:ZTronAssetSyncTests/EngineFollowBarrierTests/drainSpendsTheSpaceVerdictsTurnOnATakeOffThatOwes(_:)" "-only-testing:ZTronAssetSyncTests/EngineFollowBarrierTests/barrierGivesATransferENOSPCsVerdictAtTheCapAfterTheFollowsJoinInItsRead(_:)" "-only-testing:ZTronAssetSyncTests/EngineFollowBarrierTests/takeOffAtTheReservationsEdgeRejoinsItsJobWithItsRetryState(_:_:)" -test-iterations 30 -collect-test-diagnostics never -resultBundlePath $G/sim-rep30.xcresult > $G/sim-rep30.log 2>&1; rc=$?; stamp "sim rep30 exit $rc"
kill $SAMP; wait $SAMP 2>/dev/null
xcrun simctl shutdown $SIM > $G/sim-shutdown.log 2>&1; echo "shutdown exit $?" >> $G/sim-shutdown.log
rm -rf $LOCK; stamp "simulator lock released"
xcrun xcresulttool get test-results summary --path $G/sim.xcresult > $G/sim-summary.json 2>&1
xcrun xcresulttool get test-results summary --path $G/sim-rep30.xcresult > $G/sim-rep30-summary.json 2>&1
stamp "gates done dirty $(git status --short | wc -l | tr -d ' ')"
git status --short > $G/status-after.txt
stamp "post start head $(git rev-parse --short HEAD) dirty $(git status --short | wc -l | tr -d ' ')"
# PROBE-C21-APM (scratch, .build-s3f/c21/apm, not committed): answerPresentMembers' answer turn at 10,000 present
# ids, in release, under sim.lock, once the 1-minute load is 10 or less (S3-R23).
takelock apm
quiet apm
sampler $G/apm-load.txt & SAMP=$!
(cd $W/.build-s3f/c21/apm && swift test -c release --scratch-path ../apm-build -Xswiftc -enable-testing --skip-build --filter ProbeC21APM) > $G/apm.log 2>&1; rc=$?; stamp "apm exit $rc"
kill $SAMP; wait $SAMP 2>/dev/null
rm -rf $LOCK; stamp "apm lock released"
# S3-R13's tools-6.4 check ran on its own, before this run (tools/t64-c21b.sh, gates-b/t64.txt).
takelock covsync
sampler $G/covsync-load.txt & SAMP=$!
for i in 2 3; do
    swift test --scratch-path .build-s3f --enable-code-coverage --skip Benchmarks --filter ZTronAssetSyncTests > $G/covsync$i.log 2>&1; rc=$?; stamp "covsync$i exit $rc"
done
kill $SAMP; wait $SAMP 2>/dev/null
rm -rf $LOCK; stamp "covsync lock released"
stamp "post done dirty $(git status --short | wc -l | tr -d ' ')"
git status --short > $G/status-post.txt
kill $ALL; wait $ALL 2>/dev/null
