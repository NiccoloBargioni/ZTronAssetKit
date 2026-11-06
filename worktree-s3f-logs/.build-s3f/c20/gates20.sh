#!/bin/bash
# Cycle 20's gate run on the final code: every stage stamped with the three load averages (S3-R23 item 1).
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
source $W/.build-s3f/c20/env.sh
G=$W/.build-s3f/c20/gates
mkdir -p $G
T=$G/times.txt
LOCK=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/sim.lock
SIM=897F9D8D-B10D-4D91-8E22-417A2B9D70AA
stamp() { echo "$(date +%H:%M:%S) $1 load $(sysctl -n vm.loadavg)" >> $T; }
sampler() { while true; do echo "$(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $1; sleep 5; done; }
takelock() {
    stamp "$1 waiting for lock"
    until mkdir $LOCK 2>/dev/null; do
        if [ -n "$(find $LOCK -maxdepth 0 -mmin +45 2>/dev/null)" ]; then
            stamp "$1 stale lock (over 45 min) removed"
            rmdir $LOCK 2>/dev/null
        fi
        sleep 15
    done
    stamp "$1 lock taken"
}
: > $T
stamp "start head $(git rev-parse --short HEAD) dirty $(git status --short | wc -l | tr -d ' ')"
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
python3 Scripts/gates.py coverage --json $G/cov.json > $G/cov-gate.log 2>&1; rc=$?; stamp "cov gate exit $rc"
for i in 2 3; do
    swift test --scratch-path .build-s3f --enable-code-coverage --skip Benchmarks --filter ZTronAssetSyncTests > $G/covsync$i.log 2>&1; rc=$?; stamp "covsync$i exit $rc"
done
kill $SAMP; wait $SAMP 2>/dev/null
rmdir $LOCK; stamp "coverage lock released"
takelock simulator
sampler $G/sim-load.txt & SAMP=$!
caffeinate -i xcodebuild build-for-testing -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-s3f/xcode-sim OTHER_SWIFT_FLAGS='-warnings-as-errors' > $G/sim-build.log 2>&1; rc=$?; stamp "sim build exit $rc"
caffeinate -i xcodebuild test-without-building -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-s3f/xcode-sim -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never -resultBundlePath $G/sim.xcresult > $G/sim.log 2>&1; rc=$?; stamp "sim test exit $rc"
caffeinate -i xcodebuild test-without-building -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-s3f/xcode-sim "-only-testing:ZTronAssetSyncTests/EngineFollowBarrierTests/barrierReadmitsBehindTheOwedVisitsPlaces(_:)" -test-iterations 30 -collect-test-diagnostics never -resultBundlePath $G/sim-rep30.xcresult > $G/sim-rep30.log 2>&1; rc=$?; stamp "sim rep30 exit $rc"
kill $SAMP; wait $SAMP 2>/dev/null
xcrun simctl shutdown $SIM > $G/sim-shutdown.log 2>&1; echo "shutdown exit $?" >> $G/sim-shutdown.log
rmdir $LOCK; stamp "simulator lock released"
xcrun xcresulttool get test-results summary --path $G/sim.xcresult > $G/sim-summary.json 2>&1
xcrun xcresulttool get test-results summary --path $G/sim-rep30.xcresult > $G/sim-rep30-summary.json 2>&1
sampler $G/bench-load.txt & SAMP=$!
swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter Benchmarks > $G/bench.log 2>&1; rc=$?; stamp "bench exit $rc"
kill $SAMP; wait $SAMP 2>/dev/null
stamp "done"
