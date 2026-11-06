#!/bin/bash
cd /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=.build-verify-s3f-c6-reqs
export TMPDIR=$PWD/$S/tmp/ CLANG_MODULE_CACHE_PATH=$PWD/$S/tmp/mc LLVM_PROFILE_FILE=$PWD/$S/tmp/prof-%p.profraw
L=$S/logs
ts(){ echo "[$(date +%H:%M:%S) load $(sysctl -n vm.loadavg)] $*" >> $L/jobA.timeline; }
ts start-quick
SWIFTPM_SCRATCH=$S bash Scripts/verify.sh --quick > $L/quick.log 2>&1; ts "quick exit $?"
swift build -c release --scratch-path $S -Xswiftc -warnings-as-errors > $L/release.log 2>&1; ts "release exit $?"
{ python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md && python3 Scripts/gates.py docs --sources "$PWD/Sources"; } > $L/gates.log 2>&1; ts "gates exit $?"
for i in 1 2 3; do
  ts start-sync$i
  swift test --scratch-path $S --skip Benchmarks --filter ZTronAssetSyncTests > $L/sync$i.log 2>&1; ts "sync$i exit $?"
done
unset LLVM_PROFILE_FILE
ts start-cov
swift test --scratch-path $S --enable-code-coverage --skip Benchmarks > $L/cov.log 2>&1; ts "cov exit $?"
ts DONE
