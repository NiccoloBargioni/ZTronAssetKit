#!/bin/bash
# Cycle-19 gate runs on the last code and test commit, one at a time. Logs under .build-s3f/c19/final/, with stage
# times and the three load averages in times.txt (S3-R23 item 1). The coverage and simulator runs take the shared
# sim.lock (S3-R22 item 3). The S3-R13 export goes to .build-s3f/t64-c19, built in .build-s3f/t64-c19-build.
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
G=$W/.build-s3f/c19/final
LOCK=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/sim.lock
SIM=897F9D8D-B10D-4D91-8E22-417A2B9D70AA
mkdir -p "$G"
cd "$W" || exit 1
export TMPDIR=$W/.build-s3f/tmp CLANG_MODULE_CACHE_PATH=$W/.build-s3f/tmp/mc LLVM_PROFILE_FILE=$W/.build-s3f/tmp/%p.profraw
stamp() { echo "$(date '+%H:%M:%S') $1 $(sysctl -n vm.loadavg)" >> $G/times.txt; }
sample() { while true; do echo "$(date '+%H:%M:%S') $(sysctl -n vm.loadavg)" >> "$1"; sleep 10; done; }
take_lock() {
    while ! mkdir "$LOCK" 2>/dev/null; do
        if [ -d "$LOCK" ] && [ $(( $(date +%s) - $(stat -f %m "$LOCK") )) -gt 2700 ]; then
            stamp "lock-stale-removed"
            rmdir "$LOCK" 2>/dev/null
        fi
        sleep 20
    done
    stamp "lock-taken-$1"
}
drop_lock() { rmdir "$LOCK"; stamp "lock-dropped-$1"; }
echo "HEAD $(git rev-parse --short HEAD) status [$(git status --short | wc -l | tr -d ' ') changes]" > $G/times.txt
stamp quick-start
SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick > $G/quick.log 2>&1
stamp quick-end
swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors > $G/release.log 2>&1; echo "exit $?" >> $G/release.log
stamp release-end
(python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3 Scripts/gates.py docs --sources "$PWD/Sources") > $G/gates.log 2>&1; echo "exit $?" >> $G/gates.log
stamp gates-end
for i in 1 2 3; do
    stamp syncx-$i-start
    swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests > $G/syncx-$i.log 2>&1
    stamp syncx-$i-end
done
stamp tsan-start
sample $G/tsan-load.txt & SP=$!
swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter ZTronAssetSyncTests > $G/tsan.log 2>&1
kill $SP
stamp tsan-end
take_lock coverage
swift test --scratch-path .build-s3f --enable-code-coverage --skip Benchmarks > $G/cov-test.log 2>&1
stamp cov-test-end
P=.build-s3f/out/Products/Debug
FIRST=""; OTHERS=""
for b in $(ls -d $P/*.xctest); do n=$(basename $b .xctest); bin=$b/Contents/MacOS/$n; if [ -z "$FIRST" ]; then FIRST=$bin; else OTHERS="$OTHERS -object $bin"; fi; done
xcrun llvm-cov export -summary-only -instr-profile $P/codecov/default.profdata $FIRST $OTHERS > .build-s3f/cov.json 2> $G/cov-export.err
drop_lock coverage
python3 Scripts/gates.py coverage --json .build-s3f/cov.json > $G/cov-gate.log 2>&1
stamp cov-end
xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet > $G/ios-build.log 2>&1; echo "exit $?" >> $G/ios-build.log
stamp ios-build-end
take_lock simulator
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
drop_lock simulator
stamp bench-prebuild
export TMPDIR=$W/.build-s3f-perf/tmp CLANG_MODULE_CACHE_PATH=$W/.build-s3f-perf/tmp/mc
mkdir -p $TMPDIR
swift build -c release --build-tests --scratch-path .build-s3f-perf -Xswiftc -enable-testing > $G/bench-build.log 2>&1; echo "build exit $?" >> $G/bench-build.log
stamp bench-start
( while [ ! -f $G/bench.done ]; do echo "$(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $G/bench-load.txt; sleep 10; done ) &
swift test -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --filter Benchmarks > $G/bench.log 2>&1; echo "test exit $?" >> $G/bench-build.log
touch $G/bench.done
stamp bench-end
mkdir -p .build-s3f/t64-c19 .build-s3f/t64-c19-build/tmp/mc
git archive HEAD | tar -x -C .build-s3f/t64-c19
(
    cd .build-s3f/t64-c19 || exit 1
    sed -i '' '1s#.*#// swift-tools-version: 6.4#' Package.swift
    echo "HEAD $(git -C $W rev-parse --short HEAD); $(head -1 Package.swift); $(swift --version 2>&1 | head -1)"
    export TMPDIR=$W/.build-s3f/t64-c19-build/tmp/ CLANG_MODULE_CACHE_PATH=$W/.build-s3f/t64-c19-build/tmp/mc
    swift build --build-tests --scratch-path ../t64-c19-build -Xswiftc -warnings-as-errors > $G/t64-debug.log 2>&1
    echo "debug exit $? warnings $(grep -c 'warning:' $G/t64-debug.log) errors $(grep -c 'error:' $G/t64-debug.log)"
    sed 's/\x1b\[[0-9;]*m//g' $G/t64-debug.log | tail -1
) > $G/t64.txt 2>&1
stamp t64-end
echo all-done >> $G/times.txt
