#!/bin/bash
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c5-reqs
cd $S/pkg
export TMPDIR=$S/tmp/ CLANG_MODULE_CACHE_PATH=$S/tmp/mc
for v in prefix noRequeueBudget noParkBudget offByOne head; do
  cp $S/variants/EngineJobs.$v.swift Sources/ZTronAssetSync/Engine/EngineJobs.swift
  echo "[$(date +%H:%M:%S) $(sysctl -n vm.loadavg)] build $v" >> $S/logs/mut.timeline
  swift build --build-tests --scratch-path $S/pkg-build > $S/logs/mut-build-$v.log 2>&1; echo "build $v exit $?" >> $S/logs/mut.timeline
  for i in 1 2; do
    swift test --skip-build --scratch-path $S/pkg-build --filter spaceSweepFollowsAtMostOneTurnOfJobs > $S/logs/mut-test-$v-$i.log 2>&1; echo "test $v run$i exit $? [$(date +%H:%M:%S) $(sysctl -n vm.loadavg)]" >> $S/logs/mut.timeline
  done
done
cmp $S/variants/EngineJobs.head.swift Sources/ZTronAssetSync/Engine/EngineJobs.swift && echo "restored head" >> $S/logs/mut.timeline
echo DONE >> $S/logs/mut.timeline
