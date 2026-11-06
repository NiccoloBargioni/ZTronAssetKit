#!/bin/bash
# Cycle-19 reqs verifier gate runs (scratch only). Runs from the worktree; every scratch file stays under $S.
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=$W/.build-verify-s3f-c19-reqs
LOCK=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/sim.lock
SIM=6BE15CAF-7E02-4060-9338-9DAC025EDF0B
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/modcache LLVM_PROFILE_FILE=$S/tmp/prof-%p.profraw
cd $W || exit 2
G=$S/logs/gates
mkdir -p $G
T=$G/times.txt
stamp() { echo "$(date +%H:%M:%S) $1 load $(sysctl -n vm.loadavg)" >> $T; }
sampler_start() { bash $S/loadsampler.sh "$1" 5 & SAMPLER=$!; }
sampler_stop() { kill $SAMPLER 2>/dev/null; wait $SAMPLER 2>/dev/null; }

steps="${*:-release sync ios sim tsan bench}"
for step in $steps; do
  case $step in
    release)
      stamp "release start"
      swift build -c release --scratch-path .build-verify-s3f-c19-reqs -Xswiftc -warnings-as-errors > $G/release.log 2>&1
      stamp "release exit $?"
      ;;
    sync)
      for i in 1 2 3; do
        stamp "sync$i start"
        swift test --scratch-path .build-verify-s3f-c19-reqs --skip Benchmarks --filter ZTronAssetSyncTests > $G/sync-$i.log 2>&1
        stamp "sync$i exit $?"
      done
      ;;
    ios)
      stamp "ios start"
      xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-verify-s3f-c19-reqs/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet > $G/ios-build.log 2>&1
      stamp "ios exit $?"
      ;;
    sim)
      stamp "sim waiting for lock"
      until mkdir $LOCK 2>/dev/null; do sleep 15; done
      stamp "sim lock taken"
      sampler_start $G/sim-load.txt
      caffeinate -i xcodebuild test -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-verify-s3f-c19-reqs/xcode-sim -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never OTHER_SWIFT_FLAGS='-warnings-as-errors' > .build-verify-s3f-c19-reqs/sim.log 2>&1
      stamp "sim exit $?"
      sampler_stop
      xcrun simctl shutdown $SIM >> $G/sim-shutdown.log 2>&1
      echo "shutdown exit $?" >> $G/sim-shutdown.log
      xcrun simctl list devices | grep $SIM >> $G/sim-shutdown.log 2>&1
      rmdir $LOCK
      stamp "sim lock released"
      B=$(find .build-verify-s3f-c19-reqs/xcode-sim/Logs/Test -maxdepth 1 -name '*.xcresult' | sort | tail -1)
      echo "$B" > $G/sim-bundle.txt
      xcrun xcresulttool get test-results summary --path "$B" > $G/sim-summary.json 2>&1
      ;;
    tsan)
      stamp "tsan start"
      sampler_start $G/tsan-load.txt
      swift test --scratch-path .build-verify-s3f-c19-reqs-tsan --sanitize=thread --skip Benchmarks --filter ZTronAssetSyncTests > $G/tsan.log 2>&1
      stamp "tsan exit $?"
      sampler_stop
      ;;
    benchbuild)
      stamp "benchbuild start"
      swift build --build-tests -c release --scratch-path .build-verify-s3f-c19-reqs-perf -Xswiftc -enable-testing > $G/benchbuild.log 2>&1
      stamp "benchbuild exit $?"
      ;;
    bench)
      stamp "bench start"
      sampler_start $G/bench-load.txt
      bash $S/logwatch.sh $G/bench.log $G/bench-watch.txt & WATCH=$!
      swift test -c release --scratch-path .build-verify-s3f-c19-reqs-perf -Xswiftc -enable-testing --filter Benchmarks > $G/bench.log 2>&1
      stamp "bench exit $?"
      sampler_stop
      kill $WATCH 2>/dev/null; wait $WATCH 2>/dev/null
      ;;
  esac
done
stamp "gates done: $steps"
