#!/bin/bash
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c8-reqs
cd $S/mut
source $S/env.sh
# Space-sweep tests: the four new EngineSweepOrderTests, the cycle 5-7 R-SYN-11 sweep tests, and the cycle-7 probes.
F='spaceSweep|readSweep|VerifyC7CorrectProbes|VerifyC7ReqsProbes'
run(){ v=$1; n=$2; whole=$3
  cp $S/variants/EngineJobs.$v.swift Sources/ZTronAssetSync/Engine/EngineJobs.swift
  if [ -f $S/variants/EngineFollow.$v.swift ]; then cp $S/variants/EngineFollow.$v.swift Sources/ZTronAssetSync/Engine/EngineFollow.swift; else cp $S/variants/EngineFollow.head.swift Sources/ZTronAssetSync/Engine/EngineFollow.swift; fi
  ts "build $v"
  swift build --build-tests --scratch-path $S/mut-build > $S/logs/mut-build-$v.log 2>&1; ts "build $v exit $?"
  for i in $(seq 1 $n); do
    swift test --skip-build --scratch-path $S/mut-build --filter "$F" > $S/logs/mut-test-$v-$i.log 2>&1; ts "test $v run$i exit $?"
  done
  if [ "$whole" = 1 ]; then
    swift test --skip-build --scratch-path $S/mut-build --skip Benchmarks --filter ZTronAssetSyncTests > $S/logs/mut-sync-$v.log 2>&1; ts "sync bundle $v exit $?"
  fi
}
for spec in "$@"; do IFS=: read v n w <<< "$spec"; run $v $n $w; done
cp $S/variants/EngineJobs.head.swift Sources/ZTronAssetSync/Engine/EngineJobs.swift
cp $S/variants/EngineFollow.head.swift Sources/ZTronAssetSync/Engine/EngineFollow.swift
ts "mut DONE"
