#!/bin/bash
# After an e2-A1/A2 part commit ($1 the rev, $2 a tag): the worktree's release build with -enable-testing into
# .build-s3f-perf, purgeWhileOwedTurns (wt-bench.sh), then PROBE-C21-PURGE-PARTS on the commit (probe-parts.sh), and
# any extra wt-bench pairs given after the tag. Progress lines go to .build-s3f/c22/$2.meta.
source /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-s3f/c20/env.sh
C=$W/.build-s3f/c22
rev=$1; tag=$2; shift 2
echo "build start $(date +%H:%M:%S) load $(sysctl -n vm.loadavg) rev $rev HEAD $(git -C $W rev-parse --short HEAD)"
swift build -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --build-tests > $C/$tag-build.log 2>&1
echo "build exit $? $(date +%H:%M:%S) load $(sysctl -n vm.loadavg)"
echo "BUILT"
bash $C/tools/wt-bench.sh $tag pwo=purgeWhileOwedTurns "$@"
echo "bench done $(date +%H:%M:%S)"
bash $C/tools/probe-parts.sh $rev $tag
echo "probe exit $? $(date +%H:%M:%S)"
echo "DONE"
