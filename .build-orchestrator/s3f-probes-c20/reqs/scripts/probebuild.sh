#!/bin/bash
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c20-reqs
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/modcache
cd $S/probesrc || exit 2
echo "$(date +%H:%M:%S) probebuild start load $(sysctl -n vm.loadavg)" >> $S/logs/gates/times.txt
swift build --build-tests -c release --scratch-path $S/probebuild -Xswiftc -enable-testing > $S/logs/probebuild.log 2>&1
echo "$(date +%H:%M:%S) probebuild exit $? load $(sysctl -n vm.loadavg)" >> $S/logs/gates/times.txt
