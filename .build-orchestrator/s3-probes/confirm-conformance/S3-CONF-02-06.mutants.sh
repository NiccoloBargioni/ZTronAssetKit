#!/bin/bash
W=/Users/admin/Documents/ZTronAssetKit/.build-s3-confirm-conformance-wt
S=/Users/admin/Documents/ZTronAssetKit/.build-s3-confirm-conformance
P=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3-probes/conformance
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/module-cache LLVM_PROFILE_FILE=$S/tmp/default-%p.profraw
cd $W
for m in 02 03 04 05 06; do
  if [ $m = 06 ]; then F='ZTronAssetStorageTests|ZTronAssetSyncTests|ZTronAssetKitTests|ZTronAssetCompatibilityTests'; else F='ZTronAssetSyncTests|ZTronAssetKitTests|ZTronAssetCompatibilityTests'; fi
  git apply $P/S3-CONF-$m.mutant.diff || { echo "MUTANT $m: apply failed"; continue; }
  echo "=== MUTANT $m (load $(uptime | sed 's/.*averages: //'))"
  swift test --scratch-path $S --skip Benchmarks --filter "$F" > $S/mutant-$m.log 2>&1
  echo "exit=$?"
  grep -E '^(✔|✘) Test run|^✘ Test "|Expectation failed|error:' $S/mutant-$m.log | cut -c1-260
  git apply -R $P/S3-CONF-$m.mutant.diff
done
git status --short
echo "done (load $(uptime | sed 's/.*averages: //'))"
