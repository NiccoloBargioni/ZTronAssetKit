#!/bin/bash
# Close-out cycle 2: the oracle (reaps not counted among the 40 operations) against mutants Z and G.
M=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3c/.build-s3c/mut
export TMPDIR=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3c/.build-s3c/tmp
export CLANG_MODULE_CACHE_PATH=$TMPDIR/module-cache
R=$M/results-c2.txt
: > $R
cd $M/src
swift build --build-tests --scratch-path $M/build > $M/build-c2.log 2>&1 || { echo "BUILD FAILED" >> $R; tail -20 $M/build-c2.log >> $R; exit 1; }
for z in baseline Z G; do
  env S3MUT=$z swift test --scratch-path $M/build --skip Benchmarks --skip-build --filter OracleTests > $M/oracle-c2-$z.log 2>&1
  echo "oracle-$z exit=$? :: $(grep -E 'Test run with|Fatal error' $M/oracle-c2-$z.log | head -2 | tr '\n' ' ' | cut -c1-300)" >> $R
  grep -E 'Fatal error|I-3:' $M/oracle-c2-$z.log | head -2 | cut -c1-300 >> $R
done
echo DONE >> $R
