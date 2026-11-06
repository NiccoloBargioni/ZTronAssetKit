#!/bin/bash
# cycle 12 gate battery, in sequence, on the committed head
WT=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
cd $WT
export TMPDIR=$WT/.build-s3f/tmp CLANG_MODULE_CACHE_PATH=$WT/.build-s3f/tmp/mc LLVM_PROFILE_FILE=$WT/.build-s3f/tmp/%p.profraw
echo "== HEAD $(git rev-parse --short HEAD) $(date +%T)"
echo "== quick $(date +%T) $(sysctl -n vm.loadavg)"
SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick > .build-s3f/c12-quick.log 2>&1
echo "quick exit $? $(date +%T) $(sysctl -n vm.loadavg)"
sed 's/\x1b\[[0-9;]*m//g' .build-s3f/c12-quick.log | grep -E '^VERIFY:|SUMMARY|Test run with' | tail -12
bash .build-s3f/c12-final.sh
bash .build-s3f/c12-tsan.sh
bash .build-s3f/c12-ios.sh
bash .build-s3f/c12-bench.sh
bash .build-s3f/c12-t64.sh
echo "== all done $(date +%T)"
