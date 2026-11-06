#!/bin/bash
# Runs the given probe filters (release, probebuild, --skip-build), logging loads before and after.
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c21-reqs
cd $S/probesrc
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/modcache
tag=$1; shift
args=()
for f in "$@"; do args+=(--filter "$f"); done
echo "$tag start $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $S/logs/probe-times.txt
swift test -c release --scratch-path $S/probebuild -Xswiftc -enable-testing --skip-build "${args[@]}" > $S/logs/probe-$tag.log 2>&1
echo "$tag exit $? $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $S/logs/probe-times.txt
