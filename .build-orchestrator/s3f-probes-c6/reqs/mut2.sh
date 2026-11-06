#!/bin/bash
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c6-reqs
cd $S/pkg
export TMPDIR=$S/tmp/ CLANG_MODULE_CACHE_PATH=$S/tmp/mc LLVM_PROFILE_FILE=$S/tmp/prof-%p.profraw
F='VerifyC6ReqsProbes|spaceSweepJudgesAFollowedJobOnItsNewLane'
ts(){ echo "[$(date +%H:%M:%S) load $(sysctl -n vm.loadavg)] $*" >> $S/logs/mut2.timeline; }
for v in head skipNotFit requeueNoAhead; do
  cp $S/variants/EngineJobs.$v.swift Sources/ZTronAssetSync/Engine/EngineJobs.swift
  swift build --build-tests --scratch-path $S/pkg-build -Xswiftc -warnings-as-errors > $S/logs/mut2-build-$v.log 2>&1; ts "build $v exit $?"
  for i in 1 2; do
    swift test --skip-build --scratch-path $S/pkg-build --filter "$F" > $S/logs/mut2-test-$v-$i.log 2>&1; ts "test $v run$i exit $?"
  done
  if [ $v != head ]; then
    swift test --skip-build --scratch-path $S/pkg-build --filter ZTronAssetSyncTests --skip 'VerifyC' > $S/logs/mut2-sync-$v.log 2>&1; ts "sync bundle $v exit $?"
  fi
done
cp $S/variants/EngineJobs.head.swift Sources/ZTronAssetSync/Engine/EngineJobs.swift
ts DONE
