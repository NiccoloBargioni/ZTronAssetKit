#!/bin/bash
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c6-reqs
cd $S/pkg
export TMPDIR=$S/tmp/ CLANG_MODULE_CACHE_PATH=$S/tmp/mc LLVM_PROFILE_FILE=$S/tmp/prof-%p.profraw
F='spaceSweepJudgesAFollowedJobOnItsNewLane|spaceSweepParksAtMostOneTurnOfJobs|VerifyC5CorrectSyncProbes'
ts(){ echo "[$(date +%H:%M:%S) load $(sysctl -n vm.loadavg)] $*" >> $S/logs/mut.timeline; }
for v in head prefix noLaneRejudge noParkBound skipNotFit requeueNoAhead; do
  cp $S/variants/EngineJobs.$v.swift Sources/ZTronAssetSync/Engine/EngineJobs.swift
  ts "build $v"
  swift build --build-tests --scratch-path $S/pkg-build -Xswiftc -warnings-as-errors > $S/logs/mut-build-$v.log 2>&1; ts "build $v exit $?"
  for i in 1 2; do
    swift test --skip-build --scratch-path $S/pkg-build --filter "$F" > $S/logs/mut-test-$v-$i.log 2>&1; ts "test $v run$i exit $?"
  done
done
cp $S/variants/EngineJobs.head.swift Sources/ZTronAssetSync/Engine/EngineJobs.swift
ts DONE
