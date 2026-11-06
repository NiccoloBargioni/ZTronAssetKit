#!/bin/bash
# Cycle-16 runs after gates2.sh: iOS Simulator tests, release benchmarks, S3-R13. Logs under .build-s3f/c16/final/.
# Nothing is removed: the S3-R13 export goes to a new folder, .build-s3f/t64-c16, built in .build-s3f/t64-c16-build.
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
G=$W/.build-s3f/c16/final
SIM=897F9D8D-B10D-4D91-8E22-417A2B9D70AA
cd "$W" || exit 1
stamp() { echo "$(date '+%H:%M:%S') $1 $(sysctl -n vm.loadavg)" >> $G/times.txt; }
export TMPDIR=$W/.build-s3f/tmp
stamp sim-start
xcrun simctl boot $SIM > $G/sim-boot.log 2>&1; echo "boot exit $?" >> $G/sim-boot.log
caffeinate -i xcodebuild test -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-s3f/xcode-sim -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never OTHER_SWIFT_FLAGS='-warnings-as-errors' > .build-s3f/sim.log 2>&1
echo "sim exit $?" >> $G/sim-boot.log
stamp sim-end
B=$(ls -td .build-s3f/xcode-sim/Logs/Test/*.xcresult | head -1)
echo "bundle $B" > $G/sim-summary.txt
xcrun xcresulttool get test-results summary --path "$B" > $G/sim-summary.json 2>&1
xcrun simctl shutdown $SIM >> $G/sim-boot.log 2>&1; echo "shutdown exit $?" >> $G/sim-boot.log
xcrun simctl list devices | grep $SIM >> $G/sim-boot.log
stamp bench-prebuild
export TMPDIR=$W/.build-s3f-perf/tmp CLANG_MODULE_CACHE_PATH=$W/.build-s3f-perf/tmp/mc
mkdir -p $TMPDIR
swift build -c release --build-tests --scratch-path .build-s3f-perf -Xswiftc -enable-testing > $G/bench-build.log 2>&1; echo "build exit $?" >> $G/bench-build.log
stamp bench-start
( while [ ! -f $G/bench.done ]; do echo "$(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $G/bench-load.txt; sleep 10; done ) &
swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter Benchmarks > $G/bench.log 2>&1; echo "test exit $?" >> $G/bench-build.log
touch $G/bench.done
stamp bench-end
# S3-R13: export HEAD, set tools 6.4 in the export only, build debug (tests, -warnings-as-errors) and release.
mkdir -p .build-s3f/t64-c16 .build-s3f/t64-c16-build/tmp/mc
git archive HEAD | tar -x -C .build-s3f/t64-c16
(
    cd .build-s3f/t64-c16 || exit 1
    sed -i '' '1s#.*#// swift-tools-version: 6.4#' Package.swift
    echo "HEAD $(git -C $W rev-parse --short HEAD); $(head -1 Package.swift); $(swift --version 2>&1 | head -1)"
    export TMPDIR=$W/.build-s3f/t64-c16-build/tmp/ CLANG_MODULE_CACHE_PATH=$W/.build-s3f/t64-c16-build/tmp/mc
    swift build --build-tests --scratch-path ../t64-c16-build -Xswiftc -warnings-as-errors > $G/t64-debug.log 2>&1
    echo "debug exit $? warnings $(grep -c 'warning:' $G/t64-debug.log) errors $(grep -c 'error:' $G/t64-debug.log)"
    sed 's/\x1b\[[0-9;]*m//g' $G/t64-debug.log | tail -1
    swift build -c release --scratch-path ../t64-c16-build > $G/t64-release.log 2>&1
    echo "release exit $? warnings $(grep -c 'warning:' $G/t64-release.log)"
    sed 's/\x1b\[[0-9;]*m//g' $G/t64-release.log | tail -1
) > $G/t64.txt 2>&1
stamp t64-end
echo final-done >> $G/times.txt
