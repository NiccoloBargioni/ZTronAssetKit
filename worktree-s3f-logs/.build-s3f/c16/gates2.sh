#!/bin/bash
# Cycle-16 gate runs, one at a time. Logs under .build-s3f/c16/gates/.
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
G=$W/.build-s3f/c16/final
cd "$W" || exit 1
export TMPDIR=$W/.build-s3f/tmp CLANG_MODULE_CACHE_PATH=$W/.build-s3f/tmp/mc LLVM_PROFILE_FILE=$W/.build-s3f/tmp/%p.profraw
stamp() { echo "$(date '+%H:%M:%S') $1 $(sysctl -n vm.loadavg)" >> $G/times.txt; }
sample() { while true; do echo "$(date '+%H:%M:%S') $(sysctl -n vm.loadavg)" >> "$1"; sleep 10; done; }
stamp quick-start
SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick > $G/quick.log 2>&1
stamp quick-end
swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors > $G/release.log 2>&1; echo "exit $?" >> $G/release.log
stamp release-end
(python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3 Scripts/gates.py docs --sources "$PWD/Sources") > $G/gates.log 2>&1
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
swift test --scratch-path .build-s3f --enable-code-coverage --skip Benchmarks > $G/cov-test.log 2>&1
stamp cov-test-end
P=.build-s3f/out/Products/Debug
FIRST=""; OTHERS=""
for b in $(ls -d $P/*.xctest); do n=$(basename $b .xctest); bin=$b/Contents/MacOS/$n; if [ -z "$FIRST" ]; then FIRST=$bin; else OTHERS="$OTHERS -object $bin"; fi; done
xcrun llvm-cov export -summary-only -instr-profile $P/codecov/default.profdata $FIRST $OTHERS > .build-s3f/cov.json 2> $G/cov-export.err
python3 Scripts/gates.py coverage --json .build-s3f/cov.json > $G/cov-gate.log 2>&1
stamp cov-end
xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-s3f/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet > $G/ios-build.log 2>&1; echo "exit $?" >> $G/ios-build.log
stamp ios-build-end
echo done >> $G/times.txt
