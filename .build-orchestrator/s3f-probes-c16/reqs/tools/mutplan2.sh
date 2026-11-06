#!/bin/bash
# Scratch: candidate survivors not in the fixer's table (s3f cycle-16 verification, requirements lens).
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c16-reqs
export TMPDIR="$S/tmp" CLANG_MODULE_CACHE_PATH="$S/tmp/module-cache" LLVM_PROFILE_FILE="$S/tmp/prof-%p.profraw"
M="python3 $S/tmp/mut.py"
$M followAfterVerdictEpochDrop 'EngineFollowBarrierTests/barrier'
$M deferralFollowOwedDrop 'EngineFollowBarrierTests/barrier'
echo "PLAN2 DONE $(date +%H:%M:%S)"
