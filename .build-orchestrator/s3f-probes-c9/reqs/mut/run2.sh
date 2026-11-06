#!/bin/bash
R=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c9-reqs
export TMPDIR=$R/tmp CLANG_MODULE_CACHE_PATH=$R/tmp/mc
cd $R/copy-head
swift build --build-tests --scratch-path $R/b-head > $R/mut/build-probe2.log 2>&1; echo "probe2 build exit $?"
for i in 1 2 3; do swift test --scratch-path $R/b-head --skip-build --filter 'probeC9RThrottlePresent' > $R/probe-present-$i.log 2>&1; echo "present $i exit $?"; done
DROP='spaceSweepDoesNotAdmitAJobWhoseOnlyIDWasDropped|spaceSweepJudgesADroppedUserLaneAtItsPrefetchPlace|spaceSweepJudgesADroppedUserLaneOnItsOwnVolume'
python3 $R/mut/apply.py $R/mut/mutants.py . sweepNoBarrier apply
swift build --build-tests --scratch-path $R/b-head > $R/mut/build-sweepNoBarrier2.log 2>&1; echo "sweepNoBarrier2 build exit $?"
for i in 1 2; do swift test --scratch-path $R/b-head --skip-build --filter "$DROP" > $R/mut/test-sweepNoBarrier-dropped-$i.log 2>&1; echo "sweepNoBarrier dropped $i exit $?"; done
python3 $R/mut/apply.py $R/mut/mutants.py . sweepNoBarrier revert
python3 $R/mut/apply.py $R/mut/mutants.py . enospcNoDefer apply
python3 $R/mut/apply.py $R/mut/mutants.py . enqueueNoDefer apply
swift build --build-tests --scratch-path $R/b-head > $R/mut/build-enospcEnqueue.log 2>&1; echo "enospc+enqueue build exit $?"
swift test --scratch-path $R/b-head --skip-build --filter 'barrierDecidesAnENOSPCOnTheFollowedState' > $R/mut/test-enospcEnqueue-1.log 2>&1; echo "enospc+enqueue exit $?"
python3 $R/mut/apply.py $R/mut/mutants.py . enqueueNoDefer revert
python3 $R/mut/apply.py $R/mut/mutants.py . enospcNoDefer revert
diff -r /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources $R/copy-head/Sources && echo "copy-head restored"
echo "done $(date +%T)"
