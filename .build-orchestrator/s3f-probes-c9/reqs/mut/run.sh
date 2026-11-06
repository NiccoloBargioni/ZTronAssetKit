#!/bin/bash
R=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c9-reqs
export TMPDIR=$R/tmp CLANG_MODULE_CACHE_PATH=$R/tmp/mc
# 1. The original defect: 7626a07 = 40ecd95's sources + the failing-first tests.
cd $R/copy-base
echo "base build $(date +%T) $(sysctl -n vm.loadavg)"
swift build --build-tests --scratch-path $R/b-base > $R/mut/base-build.log 2>&1; echo "base build exit $?"
for i in 1 2; do
  swift test --scratch-path $R/b-base --skip-build --filter 'sweepJudgesADroppedHolderAtItsFollowedPlace|spaceSweepJudgesAJobRaisedFromAHolderInFlightAtItsUserPlace' > $R/mut/base-test-$i.log 2>&1; echo "base test $i exit $?"
done
# 2. Mutants on HEAD.
cd $R/copy-head
for n in sweepNoBarrier pumpOwedOnly pumpNoBarrier dropFront dropAskedBefore resortOwed visitForward joinNoDefer enospcNoDefer enqueueNoDefer; do
  python3 $R/mut/apply.py $R/mut/mutants.py . $n apply
  F=$(python3 $R/mut/apply.py $R/mut/mutants.py . $n filter)
  swift build --build-tests --scratch-path $R/b-head > $R/mut/build-$n.log 2>&1; echo "$n build exit $? $(date +%T)"
  for i in 1 2; do
    swift test --scratch-path $R/b-head --skip-build --filter "$F" > $R/mut/test-$n-$i.log 2>&1; echo "$n test $i exit $?"
  done
  python3 $R/mut/apply.py $R/mut/mutants.py . $n revert
done
diff -r /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources $R/copy-head/Sources && echo "copy-head restored"
# 3. HEAD (unmutated) control for the same filters.
swift build --build-tests --scratch-path $R/b-head > $R/mut/build-head.log 2>&1; echo "head build exit $?"
swift test --scratch-path $R/b-head --skip-build --filter 'EngineFollowBarrier|EngineSweepOrder|probeC9R' > $R/mut/test-head.log 2>&1; echo "head test exit $?"
echo "done $(date +%T)"
