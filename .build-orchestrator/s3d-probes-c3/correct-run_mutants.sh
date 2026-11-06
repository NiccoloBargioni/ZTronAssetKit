#!/bin/bash
# s3d cycle-3 correctness verifier: mutant + amplifier runs in the scratch copy only.
set -u
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3d/.build-verify-s3d-c3-correct
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/modcache LLVM_PROFILE_FILE=$S/tmp/%p.profraw
OUT=$S/mutants.out
: > $OUT
summ() { grep -E '^(✘|✔ Test run|✘ Test run)|↳|PROBE ' "$1" | grep -v '✔ Test "' | head -${2:-14}; }
build() {
  python3 -I $S/mutate.py $S/pristine $S/mut "$1" >> $OUT || return 1
  swift build --package-path $S/mut --scratch-path $S/mut-build --build-tests > $S/build-$1.log 2>&1 || { echo "BUILD FAIL $1" >> $OUT; grep "error:" $S/build-$1.log | cut -c1-300 | head -5 >> $OUT; return 1; }
}
t() { swift test --package-path $S/mut --scratch-path $S/mut-build --skip-build --skip Benchmarks "$@"; }
for m in none R1J-serial-before-token R1K-if-not-while X1-no-second-token-check X2-no-serial-guard X3-finished-keeps-serial X4-no-entry-token-check MK-deinit-finishes-nothing; do
  echo "=== $m (whole ZTronAssetTransportTests) load: $(uptime | sed 's/.*averages: //')" >> $OUT
  build $m || continue
  t --filter ZTronAssetTransportTests > $S/test-$m.log 2>&1
  summ $S/test-$m.log 16 >> $OUT
done
echo "=== MG-task-inside-drain: handleControlsInOrder x10 load: $(uptime | sed 's/.*averages: //')" >> $OUT
if build MG-task-inside-drain; then
  for i in 1 2 3 4 5 6 7 8 9 10; do
    t --filter 'handleControlsInOrder' > $S/test-MG-$i.log 2>&1
    echo "-- run $i" >> $OUT; summ $S/test-MG-$i.log 4 >> $OUT
  done
  t --filter ZTronAssetTransportTests > $S/test-MG-all.log 2>&1
  echo "-- whole suite" >> $OUT; summ $S/test-MG-all.log 16 >> $OUT
fi
echo "=== AMP-delay-interval-end x3 load: $(uptime | sed 's/.*averages: //')" >> $OUT
if build AMP-delay-interval-end; then
  for i in 1 2 3; do
    t --filter 'noTaskOutlivesATransfer|edgesOldVersusNewOrder' > $S/test-AMP-$i.log 2>&1
    echo "-- run $i" >> $OUT; summ $S/test-AMP-$i.log 10 >> $OUT
  done
fi
echo "=== DONE $(uptime | sed 's/.*averages: //')" >> $OUT
python3 -I $S/mutate.py $S/pristine $S/mut none >> $OUT
