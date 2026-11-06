#!/bin/bash
# Cycle-20 reqs verifier gate runs (scratch only). Runs from the worktree; every scratch file stays under $S.
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=$W/.build-verify-s3f-c20-reqs
LOCK=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/sim.lock
SIM=6BE15CAF-7E02-4060-9338-9DAC025EDF0B
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/modcache
cd $W || exit 2
G=$S/logs/gates
mkdir -p $G
T=$G/times.txt
stamp() { echo "$(date +%H:%M:%S) $1 load $(sysctl -n vm.loadavg)" >> $T; }
sampler_start() { bash $S/scripts/loadsampler.sh "$1" 5 & SAMPLER=$!; }
sampler_stop() { kill $SAMPLER 2>/dev/null; wait $SAMPLER 2>/dev/null; }
takelock() {
  stamp "$1 waiting for lock"
  until mkdir $LOCK 2>/dev/null; do
    # S3-R22 item 3: a lock older than 45 minutes is stale
    if [ -d $LOCK ] && [ $(( $(date +%s) - $(stat -f %m $LOCK) )) -gt 2700 ]; then stamp "stale lock removed"; rmdir $LOCK; fi
    sleep 15
  done
  stamp "$1 lock taken"
}
droplock() { rmdir $LOCK; stamp "$1 lock released"; }

steps="${*:-debug}"
for step in $steps; do
  case $step in
    debug)
      stamp "debug start"
      swift build --scratch-path .build-verify-s3f-c20-reqs -Xswiftc -warnings-as-errors > $G/debug.log 2>&1
      stamp "debug exit $?"
      ;;
    covbuild)
      stamp "covbuild start"
      swift build --build-tests --enable-code-coverage --scratch-path .build-verify-s3f-c20-reqs > $G/covbuild.log 2>&1
      stamp "covbuild exit $?"
      ;;
    quick)
      takelock quick
      sampler_start $G/quick-load.txt
      SWIFTPM_SCRATCH=.build-verify-s3f-c20-reqs bash Scripts/verify.sh --quick > $G/quick.log 2>&1
      stamp "quick exit $?"
      sampler_stop
      droplock quick
      ;;
    release)
      stamp "release start"
      swift build -c release --scratch-path .build-verify-s3f-c20-reqs -Xswiftc -warnings-as-errors > $G/release.log 2>&1
      stamp "release exit $?"
      ;;
    sync)
      for i in 1 2 3; do
        stamp "sync$i start"
        sampler_start $G/sync$i-load.txt
        swift test --scratch-path .build-verify-s3f-c20-reqs --skip Benchmarks --filter ZTronAssetSyncTests > $G/sync-$i.log 2>&1
        stamp "sync$i exit $?"
        sampler_stop
      done
      ;;
    ios)
      stamp "ios start"
      LLVM_PROFILE_FILE=$S/tmp/prof-%p.profraw xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-verify-s3f-c20-reqs/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet > $G/ios-build.log 2>&1
      stamp "ios exit $?"
      ;;
    simbuild)
      stamp "simbuild start"
      LLVM_PROFILE_FILE=$S/tmp/prof-%p.profraw xcodebuild build-for-testing -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-verify-s3f-c20-reqs/xcode-sim OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet > $G/simbuild.log 2>&1
      stamp "simbuild exit $?"
      ;;
    sim)
      takelock sim
      sampler_start $G/sim-load.txt
      LLVM_PROFILE_FILE=$S/tmp/prof-%p.profraw caffeinate -i xcodebuild test -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-verify-s3f-c20-reqs/xcode-sim -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never OTHER_SWIFT_FLAGS='-warnings-as-errors' > .build-verify-s3f-c20-reqs/sim.log 2>&1
      stamp "sim exit $?"
      sampler_stop
      xcrun simctl shutdown $SIM >> $G/sim-shutdown.log 2>&1
      echo "shutdown exit $?" >> $G/sim-shutdown.log
      xcrun simctl list devices | grep $SIM >> $G/sim-shutdown.log 2>&1
      droplock sim
      B=$(find .build-verify-s3f-c20-reqs/xcode-sim/Logs/Test -maxdepth 1 -name '*.xcresult' | sort | tail -1)
      echo "$B" > $G/sim-bundle.txt
      xcrun xcresulttool get test-results summary --path "$B" > $G/sim-summary.json 2>&1
      ;;
    rep30)
      takelock rep30
      sampler_start $G/rep30-load.txt
      caffeinate -i xcodebuild test-without-building -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-verify-s3f-c20-reqs/xcode-sim -only-testing:"ZTronAssetSyncTests/EngineFollowBarrierTests/barrierReadmitsBehindTheOwedVisitsPlaces(_:)" -test-iterations 30 -collect-test-diagnostics never -resultBundlePath .build-verify-s3f-c20-reqs/xcode-sim/rep30.xcresult OTHER_SWIFT_FLAGS='-warnings-as-errors' > $G/rep30.log 2>&1
      stamp "rep30 exit $?"
      sampler_stop
      xcrun simctl shutdown $SIM >> $G/sim-shutdown.log 2>&1
      echo "rep30 shutdown exit $?" >> $G/sim-shutdown.log
      xcrun simctl list devices | grep $SIM >> $G/sim-shutdown.log 2>&1
      droplock rep30
      xcrun xcresulttool get test-results summary --path .build-verify-s3f-c20-reqs/xcode-sim/rep30.xcresult > $G/rep30-summary.json 2>&1
      ;;
    tsan)
      stamp "tsan start"
      sampler_start $G/tsan-load.txt
      swift test --scratch-path .build-verify-s3f-c20-reqs-tsan --sanitize=thread --skip Benchmarks --filter ZTronAssetSyncTests > $G/tsan.log 2>&1
      stamp "tsan exit $?"
      sampler_stop
      ;;
    benchbuild)
      stamp "benchbuild start"
      swift build --build-tests -c release --scratch-path .build-verify-s3f-c20-reqs-perf -Xswiftc -enable-testing > $G/benchbuild.log 2>&1
      stamp "benchbuild exit $?"
      ;;
    bench)
      stamp "bench start"
      sampler_start $G/bench-load.txt
      swift test -c release --scratch-path .build-verify-s3f-c20-reqs-perf -Xswiftc -enable-testing --filter Benchmarks > $G/bench.log 2>&1
      stamp "bench exit $?"
      sampler_stop
      ;;
    gatespy)
      stamp "gatespy start"
      ( python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3 Scripts/gates.py docs --sources "$PWD/Sources" ) > $G/gatespy.log 2>&1
      stamp "gatespy exit $?"
      ;;
  esac
done
stamp "gates done: $steps"
