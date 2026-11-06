#!/bin/bash
# Scratch runner: TSan run of ZTronAssetSyncTests with a 5 s load sampler (S3-R12 rule 1).
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=$W/.build-verify-s3f-c19-correct
L=$S/logs
cd "$W" || exit 2
: > "$L/tsan-load.txt"
touch "$L/tsan.running"
( while [ -f "$L/tsan.running" ]; do echo "$(date '+%s') $(sysctl -n vm.loadavg)" >> "$L/tsan-load.txt"; sleep 5; done ) &
echo "start $(date '+%H:%M:%S') epoch $(date '+%s') load $(sysctl -n vm.loadavg)" > "$L/tsan.log"
TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/modcache swift test --scratch-path .build-verify-s3f-c19-correct-tsan --sanitize=thread --skip Benchmarks --filter ZTronAssetSyncTests >> "$L/tsan.log" 2>&1
rc=$?
echo "exit $rc end $(date '+%H:%M:%S') epoch $(date '+%s') load $(sysctl -n vm.loadavg)" >> "$L/tsan.log"
rm -f "$L/tsan.running"
wait
exit $rc
