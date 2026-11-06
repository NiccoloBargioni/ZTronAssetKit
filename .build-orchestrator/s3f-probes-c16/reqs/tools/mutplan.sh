#!/bin/bash
# Scratch: the mutant plan (s3f cycle-16 verification, requirements lens).
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c16-reqs
export TMPDIR="$S/tmp" CLANG_MODULE_CACHE_PATH="$S/tmp/module-cache" LLVM_PROFILE_FILE="$S/tmp/prof-%p.profraw"
M="python3 $S/tmp/mut.py"
STALE='barrierSpendsTheRerouteForTheSameFollowsLaterVisits|barrierLeavesAnIdMovedBackAndAwayToThePublication|barrierSpendsTheRerouteOfAVisitThatFindsNothingMoved|probeC15RRerouteStale|VerifyC15CorrectNew'
$M staleOriginal "$STALE"
$M consumeDrop "$STALE"
$M followGenerationDrop "$STALE"
$M failedNeverPasses 'barrierAnswersAnIdALaterApplyMovedWith|probeC15RVerdictLaterApply|VerifyC15CorrectNew'
$M enospcOriginal 'barrierLeavesAPassedIdToAPublicationsSpaceRetry|VerifyC15CorrectNew'
$M publicationEndDrop 'barrierPassesAPublicationFailingInItsBookkeeping|barrierMovesTheIdsOfAnApplyInsideAPublicationFailure|barrierLeavesAPassedIdToAPublicationsSpaceRetry|VerifyC15CorrectWindow|VerifyC15CorrectNew'
$M spaceDeferralRecordDrop 'barrierLeavesAPassedIdToAPublicationsSpaceRetry|barrierAnswersAnIdALaterApplyMovedWithAWaitingSpaceVerdict|barrierMovesALaterApplysIdFromAJobItsWaitingSpaceRetryLeft|VerifyC15CorrectNew'
$M spaceFailureEpochDropped 'barrierGivesASpaceVerdictOnlyToTheJobThatFailed|probeC15RSpaceEpoch'
$M laneVisitOwedDrop 'barrierDecidesA429BetweenDrainTurnsOnItsJobsOwnInterests|probeC15RLaneWalk'
$M laneOriginal 'barrierDecidesA429BetweenDrainTurnsOnItsJobsOwnInterests|probeC15RLaneWalk'
$M laneJobsWalkAlways 'barrierDecidesA429|probeC15RLaneWalk'
echo "PLAN DONE $(date +%H:%M:%S)"
