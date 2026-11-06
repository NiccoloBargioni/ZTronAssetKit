#!/bin/bash
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c10-correct
cd $S
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/mcache LLVM_PROFILE_FILE=$S/tmp/prof-%p.profraw
for m in "$@"; do
  python3 mut/mutants.py $m apply >> logs/mut.time
  echo "$(date +%T) $m build" >> logs/mut.time
  swift build --build-tests --package-path src --scratch-path $S/pbuild > logs/mut-build-$m.log 2>&1
  echo "build exit $?" >> logs/mut-build-$m.log
  echo "$(date +%T) $m test" >> logs/mut.time
  swift test --package-path src --scratch-path $S/pbuild --skip-build --filter EngineFollowBarrierTests > logs/mut-test-$m.log 2>&1
  python3 mut/mutants.py $m revert >> logs/mut.time
done
echo "$(date +%T) rebuild clean" >> logs/mut.time
swift build --build-tests --package-path src --scratch-path $S/pbuild > logs/mut-build-clean.log 2>&1
echo "$(date +%T) done" >> logs/mut.time
