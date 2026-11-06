#!/bin/bash
# Builds probesrc (HEAD plus the cited probes) in release with testing enabled, into probebuild.
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c21-reqs
cd $S/probesrc
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/modcache
echo "probebuild start $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $S/logs/probe-times.txt
swift build --build-tests -c release --scratch-path $S/probebuild -Xswiftc -enable-testing > $S/logs/probebuild.log 2>&1
echo "probebuild exit $? $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $S/logs/probe-times.txt
