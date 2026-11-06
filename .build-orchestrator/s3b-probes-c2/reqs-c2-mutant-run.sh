#!/bin/bash
R=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3b/.build-verify-s3b-c2-reqs
M=$R/mut
export TMPDIR=$R/tmp CLANG_MODULE_CACHE_PATH=$R/tmp/modcache-mut LLVM_PROFILE_FILE=$R/tmp/prof-%p.profraw
cd $M/src
run() { # name filter
  local name=$1 filter=$2
  echo "=== $name (filter $filter) load $(uptime | sed 's/.*averages: //')"
  if [ "$name" = base ]; then unset S3MUT; else export S3MUT=$name; fi
  swift test --scratch-path $M/build --skip Benchmarks --filter "$filter" > $M/logs/$name.log 2>&1
  echo "exit=$?"
  grep -aE '^.{0,3}(✔|✘) Test run|^.{0,3}✘ Test .* (recorded an issue|failed)|unexpected signal|error:|Fatal error' $M/logs/$name.log | head -14 | cut -c1-360
  unset S3MUT
}
OI='StoreApplyTests|EvictionOverlapTests|StoreDeletionTests|DeletionUnitTests|StorePublishTests'
run base "$OI"
run REAP 'DeletionUnitTests|StoreDeletionTests'
run REAPSTAT 'DeletionUnitTests|StoreDeletionTests'
run NOTAKE "$OI"
run OI14B "$OI"
run DETACH "$OI"
echo "=== done load $(uptime | sed 's/.*averages: //')"
