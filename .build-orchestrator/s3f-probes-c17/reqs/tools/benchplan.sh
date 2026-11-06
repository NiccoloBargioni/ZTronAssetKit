#!/bin/bash
# Scratch (s3f cycle-17 verification, requirements lens; never committed): the S3-R20 concentration bench in the copy
# pc/ (HEAD plus VerifyC17ReqsConcentration.swift), then the official release benchmarks on the worktree, one at a time.
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c17-reqs
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
source $S/tools/env.sh
ld() { sysctl -n vm.loadavg | awk '{print $2}'; }
cd $S/pc
echo "conc start $(date +%s) $(date +%H:%M:%S) load=$(ld)" >> $S/logs/times.txt
swift test -c release --skip-build --scratch-path $S/pcperf -Xswiftc -enable-testing --filter VerifyC17ReqsConcentration > $S/logs/conc.log 2>&1
echo "conc rc=$? end $(date +%s) $(date +%H:%M:%S) load=$(ld)" >> $S/logs/times.txt
cd $W
echo "bench start $(date +%s) $(date +%H:%M:%S) load=$(ld)" >> $S/logs/times.txt
swift test -c release --scratch-path .build-verify-s3f-c17-reqs-perf -Xswiftc -enable-testing --filter Benchmarks > $S/logs/bench.log 2>&1
echo "bench rc=$? end $(date +%s) $(date +%H:%M:%S) load=$(ld)" >> $S/logs/times.txt
