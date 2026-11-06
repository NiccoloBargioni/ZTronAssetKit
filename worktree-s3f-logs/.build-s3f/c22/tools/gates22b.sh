#!/bin/bash
# Cycle 22's gates on the kept-interests test's commit (eca67b8; its Sources are f1b38c8's): every gate but the
# release benchmarks (no Sources or benchmark change since the first run), the purge suite three times, TSan on it,
# and the whole Sync bundle's three runs left to the quick and coverage stages. Stamps carry the three load averages.
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
source $W/.build-s3f/c20/env.sh
G=$W/.build-s3f/c22/gates-b
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
    echo "s3f WP-F gates-b $1 $(date +%H:%M:%S)" > $LOCK/owner
    stamp "$1 lock taken"
}
: > $T
stamp "start head $(git rev-parse --short HEAD) dirty $(git status --short | wc -l | tr -d ' ')"
sampler $G/all-load.txt & ALL=$!
SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick > $G/quick.log 2>&1; rc=$?; stamp "quick exit $rc"
swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors > $G/release.log 2>&1; rc=$?; stamp "release exit $rc"
SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --gates-only > $G/gates-only.log 2>&1; rc=$?; stamp "gates-only exit $rc"
git checkout -- docs/TRACEABILITY.md; stamp "traceability restored dirty $(git status --short | wc -l | tr -d ' ')"
python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md > $G/unsafe.log 2>&1; rc=$?; stamp "unsafe exit $rc"
python3 Scripts/gates.py docs --sources "$PWD/Sources" > $G/docs.log 2>&1; rc=$?; stamp "docs exit $rc"
for i in 1 2 3; do
    swift test --scratch-path .build-s3f --skip-build --filter EnginePurgeWithdrawalTests > $G/purge$i.log 2>&1; rc=$?; stamp "purge$i exit $rc"
done
swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter EnginePurgeWithdrawalTests > $G/tsan-purge.log 2>&1; rc=$?; stamp "tsan purge exit $rc"
xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet > $G/ios.log 2>&1; rc=$?; stamp "ios exit $rc"
takelock coverage
sampler $G/cov-load.txt & SAMP=$!
swift test --scratch-path .build-s3f --enable-code-coverage --skip Benchmarks > $G/cov.log 2>&1; rc=$?; stamp "cov exit $rc"
mkdir -p $G/covcopy
cp .build-s3f/out/Products/Debug/codecov/default.profdata $G/covcopy/default.profdata
for b in $(ls -d .build-s3f/out/Products/Debug/*.xctest | grep -v Benchmarks); do rm -rf $G/covcopy/$(basename $b); cp -Rp $b $G/covcopy/; done
BINS=$(ls -d $G/covcopy/*.xctest)
FIRST=""; OBJS=""
for b in $BINS; do n=$(basename $b .xctest); if [ -z "$FIRST" ]; then FIRST=$b/Contents/MacOS/$n; else OBJS="$OBJS -object $b/Contents/MacOS/$n"; fi; done
xcrun llvm-cov export -summary-only -instr-profile $G/covcopy/default.profdata $FIRST $OBJS > $G/cov.json 2> $G/cov-export.err; rc=$?; stamp "cov export exit $rc"
cp $G/cov.json .build-s3f/cov.json
python3 Scripts/gates.py coverage --json .build-s3f/cov.json > $G/cov-gate.log 2>&1; rc=$?; stamp "cov gate exit $rc"
kill $SAMP; wait $SAMP 2>/dev/null
rm -rf $LOCK; stamp "coverage lock released"
python3 $W/.build-s3f/c22/tools/covdiff22.py $G/covcopy/default.profdata $G/covcopy > $G/covdiff.txt 2>&1; rc=$?; stamp "covdiff exit $rc"
takelock simulator
sampler $G/sim-load.txt & SAMP=$!
caffeinate -i xcodebuild test -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-s3f/xcode-sim -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never -resultBundlePath $G/sim.xcresult OTHER_SWIFT_FLAGS='-warnings-as-errors' > .build-s3f/sim.log 2>&1; rc=$?; stamp "sim test exit $rc"
cp .build-s3f/sim.log $G/sim.log
kill $SAMP; wait $SAMP 2>/dev/null
xcrun simctl shutdown $SIM > $G/sim-shutdown.log 2>&1; echo "shutdown exit $?" >> $G/sim-shutdown.log
rm -rf $LOCK; stamp "simulator lock released"
xcrun xcresulttool get test-results summary --path $G/sim.xcresult > $G/sim-summary.json 2>&1
kill $ALL; wait $ALL 2>/dev/null
stamp "done dirty $(git status --short | wc -l | tr -d ' ')"
git status --short > $G/status-after.txt
