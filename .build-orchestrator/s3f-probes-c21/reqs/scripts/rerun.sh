#!/bin/bash
# Re-runs the given BenchSync cases alone (release, the perf build), logging loads before and after.
cd /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=$PWD/.build-verify-s3f-c21-reqs
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/modcache
tag=$1; shift
args=()
for f in "$@"; do args+=(--filter "$f"); done
echo "$tag start $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $S/logs/rerun-times.txt
swift test -c release --scratch-path .build-verify-s3f-c21-reqs-perf -Xswiftc -enable-testing --skip-build "${args[@]}" > $S/logs/rerun-$tag.log 2>&1
echo "$tag exit $? $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $S/logs/rerun-times.txt
