#!/bin/bash
# Cycle-23 reqs verifier: run one command from the worktree with my TMPDIR/module cache/profile paths, logging to
# logs/<tag>.log, with start/end load stamps in logs/<tag>.times and a 10 s load sample in logs/<tag>-load.txt.
# Usage: bash run.sh <tag> <command...>
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
R=$W/.build-verify-s3f-c23-reqs
T=$R/tmp
TAG="$1"; shift
cd "$W" || exit 1
(while true; do echo "$(date '+%H:%M:%S') $(sysctl -n vm.loadavg)"; sleep 10; done) > "$R/logs/$TAG-load.txt" 2>&1 &
LP=$!
echo "start $(date '+%H:%M:%S') load $(sysctl -n vm.loadavg) head $(git rev-parse --short HEAD) cmd: $*" > "$R/logs/$TAG.times"
TMPDIR=$T CLANG_MODULE_CACHE_PATH=$T/module-cache LLVM_PROFILE_FILE=${PROFILE_OVERRIDE:-$T/prof-%p.profraw} "$@" > "$R/logs/$TAG.log" 2>&1
rc=$?
kill $LP
echo "end $(date '+%H:%M:%S') load $(sysctl -n vm.loadavg) rc=$rc" >> "$R/logs/$TAG.times"
exit $rc
