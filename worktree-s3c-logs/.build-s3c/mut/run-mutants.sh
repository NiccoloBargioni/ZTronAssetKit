#!/bin/bash
# Mutant checks in the scratch copy (.build-s3c/mut/src), one build per diff; results in .build-s3c/mut/results.txt.
M=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3c/.build-s3c/mut
SRC=$M/src
export TMPDIR=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3c/.build-s3c/tmp
export CLANG_MODULE_CACHE_PATH=$TMPDIR/module-cache
R=$M/results.txt
: > $R
cd $SRC
run() { # label filter [env]
  local label=$1 filter=$2 env=$3
  env $env swift test --scratch-path $M/build --skip Benchmarks --skip-build --filter "$filter" > $M/$label.log 2>&1
  local code=$?
  local summary=$(grep -E 'Test run with|Fatal error|error:' $M/$label.log | head -2 | tr '\n' ' ' | cut -c1-300)
  echo "$label exit=$code :: $summary" >> $R
  grep -E 'Expectation failed|Fatal error|I-3:' $M/$label.log | head -3 | cut -c1-260 >> $R
}
build() {
  swift build --build-tests --scratch-path $M/build > $M/build-$1.log 2>&1 || { echo "BUILD FAILED $1" >> $R; tail -20 $M/build-$1.log >> $R; return 1; }
}
for m in M-S-07 M-S-08 M-S-20; do
  patch -p1 -s < /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3-mutants/storage/$m.diff
  build $m && case $m in
    M-S-07) run $m 'LeaseTests/applySkipsVictimLeasedAfterThePlan' ;;
    M-S-08) run $m 'LeaseTests/dryRunLeavesOutLeasedAssets' ;;
    M-S-20) run $m 'GarbageCollectionTests/orphanGraceBoundary' ;;
  esac
  patch -p1 -R -s < /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3-mutants/storage/$m.diff
done
patch -p1 -s < /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3-probes/confirm-crash/S3-CRAS-02-03-confirm-mutants.diff
build env || exit 0
run baseline-oracle 'OracleTests'
for z in Z C F S G; do run oracle-$z 'OracleTests' S3MUT=$z; done
run baseline-flows 'CleanupFlowCrashTests'
for z in X Z G S F; do run flows-$z 'CleanupFlowCrashTests' S3MUT=$z; done
echo DONE >> $R
