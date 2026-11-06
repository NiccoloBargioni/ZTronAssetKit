#!/bin/bash
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c7-reqs
cd $S/mut
export TMPDIR=$S/tmp/ CLANG_MODULE_CACHE_PATH=$S/tmp/mc LLVM_PROFILE_FILE=$S/tmp/prof-%p.profraw
F='spaceSweepRequeuesAFollowedJobItsNewLaneFits|spaceSweepJudgesAFollowedJobOnItsNewLane|readSweepJudgesAFollowedJobOnItsNewLane|spaceSweepParksAFollowedJobWithItsNewLanesFigures'
ts(){ echo "[$(date +%H:%M:%S) load $(sysctl -n vm.loadavg)] $*" >> $S/logs/mut.timeline; }
run(){ v=$1; n=$2; whole=$3
  cp $S/variants/EngineJobs.$v.swift Sources/ZTronAssetSync/Engine/EngineJobs.swift
  ts "build $v"
  swift build --build-tests --scratch-path $S/mut-build > $S/logs/mut-build-$v.log 2>&1; ts "build $v exit $?"
  for i in $(seq 1 $n); do
    swift test --skip-build --scratch-path $S/mut-build --filter "$F" > $S/logs/mut-test-$v-$i.log 2>&1; ts "test $v run$i exit $?"
  done
  if [ "$whole" = 1 ]; then
    swift test --skip-build --scratch-path $S/mut-build --skip Benchmarks --filter ZTronAssetSyncTests > $S/logs/mut-sync-$v.log 2>&1; ts "sync bundle $v exit $?"
  fi
}
run head 5 0
run prefixC6 2 0
run skipNotFit 4 0
run requeueNoAhead 4 0
run noLaneRejudge 2 0
run gainNoAhead 2 1
run gainNoBound 2 1
cp $S/variants/EngineJobs.head.swift Sources/ZTronAssetSync/Engine/EngineJobs.swift
ts DONE
