#!/bin/bash
# Cycle-21 reqs verifier gate runs (scratch only). Runs from the worktree; every scratch file stays under $S.
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=$W/.build-verify-s3f-c21-reqs
LOCK=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/sim.lock
SIM=6BE15CAF-7E02-4060-9338-9DAC025EDF0B
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/modcache
unset LLVM_PROFILE_FILE
cd $W || exit 2
G=$S/logs/gates
mkdir -p $G $S/tmp $S/modcache
T=$G/times.txt
stamp() { echo "$(date +%H:%M:%S) $1 load $(sysctl -n vm.loadavg)" >> $T; }
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

for step in "$@"; do
  case $step in
    release)
      stamp "release start"
      swift build -c release --scratch-path .build-verify-s3f-c21-reqs -Xswiftc -warnings-as-errors > $G/release.log 2>&1
      stamp "release exit $?"
      ;;
    gatespy)
      stamp "gatespy start"
      ( python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3 Scripts/gates.py docs --sources "$PWD/Sources" ) > $G/gatespy.log 2>&1
      stamp "gatespy exit $?"
      ;;
    quick)
      takelock quick
      SWIFTPM_SCRATCH=.build-verify-s3f-c21-reqs bash Scripts/verify.sh --quick > $G/quick.log 2>&1
      stamp "quick exit $?"
      cp .verify-logs/tests.log $G/quick-tests.log 2>/dev/null
      droplock quick
      ;;
    cov)
      json="$(swift test --scratch-path .build-verify-s3f-c21-reqs --show-codecov-path 2>/dev/null | tail -1)"
      dir="$(dirname "$json")"; prof="$dir/default.profdata"; products="$(dirname "$dir")"
      echo "$prof" > $G/cov-paths.txt; echo "$products" >> $G/cov-paths.txt
      first=""; objs=()
      while IFS= read -r bundle; do
        bin="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
        [ -f "$bin" ] || continue
        if [ -z "$first" ]; then first="$bin"; else objs+=(-object "$bin"); fi
      done < <(find "$products" -maxdepth 1 -name '*.xctest' -type d | sort)
      stamp "cov export start: $(( ${#objs[@]} / 2 + 1 )) bundles"
      mkdir -p $S/cov && cp "$prof" $S/cov/default.profdata
      xcrun llvm-cov export -summary-only -instr-profile "$prof" "$first" "${objs[@]}" > $S/cov.json 2> $G/cov-export.err
      stamp "cov export exit $?"
      python3 Scripts/gates.py coverage --json $S/cov.json --config Scripts/quality-gates.json > $G/cov-gate.log 2>&1
      stamp "cov gate exit $?"
      python3 $S/tools/covdiff21.py 8e1fb24 $S/cov/default.profdata "$products" \
        Sources/ZTronAssetSync/Engine/EngineFollow.swift:1581 Sources/ZTronAssetSync/Engine/EngineFollow.swift:1582 \
        Sources/ZTronAssetSync/Engine/EngineDispatch.swift:1176 Sources/ZTronAssetSync/Engine/EngineDispatch.swift:1164 \
        Sources/ZTronAssetSync/Engine/EngineDispatch.swift:1165 Sources/ZTronAssetSync/Engine/EngineDispatch.swift:1152 \
        Sources/ZTronAssetSync/Engine/EngineDispatch.swift:1153 > $G/covdiff.txt 2>&1
      stamp "covdiff exit $?"
      ;;
    sync)
      for i in 1 2 3; do
        stamp "sync$i start"
        swift test --scratch-path .build-verify-s3f-c21-reqs --skip Benchmarks --filter ZTronAssetSyncTests > $G/sync-$i.log 2>&1
        stamp "sync$i exit $?"
      done
      ;;
    tsan)
      stamp "tsan start"
      swift test --scratch-path .build-verify-s3f-c21-reqs-tsan --sanitize=thread --skip Benchmarks --filter ZTronAssetSyncTests > $G/tsan.log 2>&1
      stamp "tsan exit $?"
      ;;
    ios)
      stamp "ios start"
      LLVM_PROFILE_FILE=$S/tmp/prof-%p.profraw xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-verify-s3f-c21-reqs/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet > $G/ios-build.log 2>&1
      stamp "ios exit $?"
      ;;
    simbuild)
      stamp "simbuild start"
      LLVM_PROFILE_FILE=$S/tmp/prof-%p.profraw xcodebuild build-for-testing -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-verify-s3f-c21-reqs/xcode-sim OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet > $G/simbuild.log 2>&1
      stamp "simbuild exit $?"
      ;;
    sim)
      takelock sim
      LLVM_PROFILE_FILE=$S/tmp/prof-%p.profraw caffeinate -i xcodebuild test -scheme ZTronAssetKit -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .build-verify-s3f-c21-reqs/xcode-sim -skip-testing:ZTronAssetKitBenchmarks -collect-test-diagnostics never OTHER_SWIFT_FLAGS='-warnings-as-errors' > $S/sim.log 2>&1
      stamp "sim exit $?"
      xcrun simctl shutdown $SIM >> $G/sim-shutdown.log 2>&1
      echo "shutdown exit $?" >> $G/sim-shutdown.log
      xcrun simctl list devices | grep $SIM >> $G/sim-shutdown.log 2>&1
      droplock sim
      B=$(find .build-verify-s3f-c21-reqs/xcode-sim/Logs/Test -maxdepth 1 -name '*.xcresult' | sort | tail -1)
      echo "$B" > $G/sim-bundle.txt
      xcrun xcresulttool get test-results summary --path "$B" > $G/sim-summary.json 2>&1
      stamp "sim summary exit $?"
      ;;
    tools64)
      T64=$S/tools64
      rm -rf $T64 && mkdir -p $T64/src
      git archive HEAD | tar -x -C $T64/src
      head -1 $T64/src/Package.swift > $G/tools64-line1-before.txt
      sed -i '' '1s#.*#// swift-tools-version: 6.4#' $T64/src/Package.swift
      head -1 $T64/src/Package.swift > $G/tools64-line1-after.txt
      stamp "tools64 build-tests start"
      ( cd $T64/src && swift build --build-tests --scratch-path $T64/build -Xswiftc -warnings-as-errors ) > $G/tools64-debug.log 2>&1
      stamp "tools64 build-tests exit $?"
      ( cd $T64/src && swift build -c release --scratch-path $T64/build ) > $G/tools64-release.log 2>&1
      stamp "tools64 release exit $?"
      ;;
  esac
done
stamp "gates done: $*"
