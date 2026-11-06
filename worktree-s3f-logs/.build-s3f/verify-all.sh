#!/bin/bash
# The close-out's verification runs, in order; each log under .build-s3f, summary lines to stdout.
WT=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
cd $WT
export TMPDIR=$WT/.build-s3f/tmp CLANG_MODULE_CACHE_PATH=$WT/.build-s3f/tmp/mc LLVM_PROFILE_FILE=$WT/.build-s3f/tmp/default-%p.profraw
L=$WT/.build-s3f/v
mkdir -p $L
echo "== quick $(uptime)"
SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick > $L/quick.log 2>&1; grep -E 'VERIFY:' $L/quick.log; grep -E 'Test run with' $L/quick.log | cut -c1-120
echo "== release $(uptime)"
swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors > $L/release.log 2>&1; echo "release exit $?"; tail -1 $L/release.log
echo "== gates"
python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md > $L/gates.log 2>&1 && python3 Scripts/gates.py docs --sources "$PWD/Sources" >> $L/gates.log 2>&1; echo "gates exit $?"; tail -4 $L/gates.log
for i in 1 2 3; do
  echo "== sync $i $(uptime)"
  swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests > $L/sync$i.log 2>&1; grep -E 'Test run with|✘ Test' $L/sync$i.log | cut -c1-200 | head -5
done
echo "== tsan $(uptime)"
TMPDIR=$WT/.build-s3f-tsan/tmp CLANG_MODULE_CACHE_PATH=$WT/.build-s3f-tsan/tmp/mc swift test --scratch-path .build-s3f-tsan --sanitize=thread --skip Benchmarks --filter ZTronAssetSyncTests > $L/tsan.log 2>&1; grep -E 'Test run with|✘ Test|ThreadSanitizer' $L/tsan.log | cut -c1-200 | head -5
echo "== coverage $(uptime)"
swift test --scratch-path .build-s3f --enable-code-coverage --skip Benchmarks > $L/cov-test.log 2>&1; grep -E 'Test run with' $L/cov-test.log | cut -c1-120
D=.build-s3f/out/Products/Debug
[ -d $D ] || D=.build-s3f/debug
BINS=$(ls -d $D/*.xctest | sed -E 's#(.*)/([^/]*)\.xctest#\1/\2.xctest/Contents/MacOS/\2#')
FIRST=$(echo "$BINS" | head -1); OTHERS=$(echo "$BINS" | tail -n +2 | sed 's/^/-object /' | tr '\n' ' ')
xcrun llvm-cov export -summary-only -instr-profile $D/codecov/default.profdata $FIRST $OTHERS > .build-s3f/cov.json 2> $L/cov-export.err; echo "export exit $?"
python3 Scripts/gates.py coverage --json .build-s3f/cov.json > $L/cov-gate.log 2>&1; echo "coverage gate exit $?"; cat $L/cov-gate.log | tail -12
echo "== done $(uptime)"
