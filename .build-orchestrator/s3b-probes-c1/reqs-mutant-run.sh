#!/bin/bash
# Mutant runs over the scratch copy (env-gated mutants; S3MUT selects one).
R=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3b/.build-verify-s3b-c1-reqs
M=$R/mut
export TMPDIR=$R/tmp CLANG_MODULE_CACHE_PATH=$R/tmp/modcache-mut LLVM_PROFILE_FILE=$R/tmp/prof-%p.profraw
cd $M/src
run() { # name filter
  local name=$1 filter=$2
  echo "=== $name (filter $filter) load $(uptime | sed 's/.*averages: //')"
  if [ "$name" = base ]; then unset S3MUT; else export S3MUT=$name; fi
  swift test --scratch-path $M/build --skip Benchmarks --filter "$filter" > $M/logs/$name.log 2>&1
  echo "exit=$?"
  grep -aE '^.{0,3}(✔|✘) Test run|^.{0,3}✘ Test "|Expectation failed|unexpected signal|error:|Fatal error|arithmetic overflow' $M/logs/$name.log | head -12 | cut -c1-330
  unset S3MUT
}
ALL='availabilitySaturatesBytesMissing|contentChangeOntoLiveBlob|writeStagedNoSpace|purgedDoomNeverRescuedAtLaunch|pruneWhileEvictionCandidatesRun|launchEpochUniquePerLaunch|crashAtEveryBoundaryOfAnUpdate|killThenPowerLoss|DeletionUnitTests|reapStopsWhenBudgetIsSpent|StoreDeletionTests'
run base "$ALL"
run SECU availabilitySaturatesBytesMissing
run CONF6 contentChangeOntoLiveBlob
run MS11 writeStagedNoSpace
run P purgedDoomNeverRescuedAtLaunch
run OI14 pruneWhileEvictionCandidatesRun
run EPOCH launchEpochUniquePerLaunch
run A crashAtEveryBoundaryOfAnUpdate
run B crashAtEveryBoundaryOfAnUpdate
run I crashAtEveryBoundaryOfAnUpdate
run H killThenPowerLoss
run REAP 'DeletionUnitTests|StoreDeletionTests'
echo "=== done load $(uptime | sed 's/.*averages: //')"
