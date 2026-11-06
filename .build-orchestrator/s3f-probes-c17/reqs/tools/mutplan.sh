#!/bin/bash
# Scratch: the mutant plan (s3f cycle-17 verification, requirements lens).
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c17-reqs
export TMPDIR="$S/tmp" CLANG_MODULE_CACHE_PATH="$S/tmp/module-cache" LLVM_PROFILE_FILE="$S/tmp/prof-%p.profraw"
M="python3 $S/tools/mut.py"
LANE='EngineFollowBarrierTests/barrierDecidesA429OnTheLaneAWaitingVerdictLeaves|EngineFollowBarrierTests/verdictAnswersMirrorTheReplays'
echo "PLAN START $(date +%H:%M:%S)"
# The original defects of the cycle-16 blocking findings.
$M retryAfterDrop "$LANE|VerifyC16Correct/rr11RetryLane|VerifyC16ReqsProbes/rr11RetryAfter"
$M throttleFailFastDrop "$LANE|VerifyC16Correct/throttleFailFastLane"
$M offlineFailFastDrop "$LANE"
$M spaceOriginal "$LANE"
$M takeOffDrop 'EngineFollowBarrierTests/barrierJoinsAnIDMappedBack|VerifyC16Correct/verdictMappedBack'
$M rule3Drop 'EngineFollowBarrierTests/barrierJoinsAnIDMappedBack|VerifyC16Correct/verdictMappedBack'
$M bringInboundDrop 'EngineFollowBarrierTests/barrierGivesAMovedInterestTheOutcomeOfTheAttemptThatEndsOnItsContent|VerifyC16Correct/intermediateHop'
$M startEndResetDrop 'EngineFollowBarrierTests/barrierRetriesAFailedPublicationWithNothingOfItsEnd'
$M startRerouteResetDrop 'EngineFollowBarrierTests/barrierRetriesAFailedPublicationWithNothingOfItsEnd'
# The fixer's table, re-checked.
$M vaKeptLane "$LANE"
$M flMovedBeforeDrop 'EngineFollowBarrierTests/barrierDecidesA429OnAnInterestTheDrainTakesOffBeforeAVerdict|EngineFollowBarrierTests/barrierDecidesA429OnTheLaneAWaitingVerdictLeaves'
$M relaneGuardRevert 'EngineFollowBarrierTests/barrierGivesAMovedInterestTheOutcomeOfTheAttemptThatEndsOnItsContent'
$M deferralFollowOwedDrop 'EngineFollowBarrierTests/barrierLeavesAnAdmittedUnlistedIDToTheVerdictThatWaits'
$M publishBringInboundDrop 'EngineFollowBarrierTests/barrierGivesAMovedInterestTheOutcomeOfTheAttemptThatEndsOnItsContent|VerifyC16Correct/intermediateHopServed'
$M spaceBringInboundDrop 'EngineFollowBarrierTests/barrierGivesAMovedInterestTheOutcomeOfTheAttemptThatEndsOnItsContent'
# New candidates: first the closest tests, then the whole serialized barrier suite.
$M vaStampDrop 'EngineFollowBarrierTests/barrier' 1
$M bringInboundStampDrop 'EngineFollowBarrierTests/barrier' 1
$M takeOffAssetsKeep 'EngineFollowBarrierTests/barrier' 1
$M rerouteOnPassKeepWhole 'EngineFollowBarrierTests/barrier' 1
echo "PLAN DONE $(date +%H:%M:%S)"
