#!/bin/bash
# Runs each env-switched mutant against the targeted tests in the scratch copy. usage: run-mutants.sh
M=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3c/.build-verify-s3c-c1-reqs/mut
export TMPDIR=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3c/.build-verify-s3c-c1-reqs/tmp
export CLANG_MODULE_CACHE_PATH=$TMPDIR/mc LLVM_PROFILE_FILE=$TMPDIR/prof-%p.profraw
cd $M/src
run() { # name filter
  local name=$1 filter=$2
  echo "=== $name ($filter) $(date +%T) $(uptime | sed 's/.*load/load/')" >> $M/results.txt
  S3MUT=$name swift test --skip-build --scratch-path ../build --filter "$filter" > $M/log-$name.log 2>&1
  echo "exit $?" >> $M/results.txt
  grep -E '✘ Test run|✔ Test run|Fatal error|Expectation failed|Time limit|recorded an issue' $M/log-$name.log | grep -v '^\s*$' | head -12 >> $M/results.txt
}
run BASE 'ZTronAssetStorageTests.(PollReleaseTests|LargeBlobTests|LeaseTests|GarbageCollectionTests|IntegrityTests|OracleTests|CleanupFlowCrashTests)|CrashPairTests/osPurgeAfterCrash'
run P1 'ZTronAssetStorageTests.PollReleaseTests'
run M7 'ZTronAssetStorageTests.LeaseTests'
run M8 'ZTronAssetStorageTests.LeaseTests'
run M20 'ZTronAssetStorageTests.GarbageCollectionTests'
run R9 'ZTronAssetStorageTests.IntegrityTests'
run K8 'CrashPairTests/osPurgeAfterCrash'
run Z 'ZTronAssetStorageTests.OracleTests'
run X 'ZTronAssetStorageTests.CleanupFlowCrashTests'
run G 'ZTronAssetStorageTests.(OracleTests|CleanupFlowCrashTests)'
run E1 'ZTronAssetStorageTests.LargeBlobTests'
run U1 'ZTronAssetStorageTests.LargeBlobTests'
echo DONE >> $M/results.txt
