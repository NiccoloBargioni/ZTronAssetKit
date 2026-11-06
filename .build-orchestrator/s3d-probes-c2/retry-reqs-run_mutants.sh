#!/bin/bash
# Usage: bash run_mutants.sh <phase-tag> <with-probe:0|1> <filter> <mutant>...
# Runs from the worktree; everything stays under .build-verify-s3d-c2-reqs.
set -u
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3d
S=$W/.build-verify-s3d-c2-reqs
M=$S/mutpkg
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/module-cache LLVM_PROFILE_FILE=$S/tmp/stray-%p.profraw
TAG="$1"; PROBE="$2"; FILTER="$3"; shift 3
OUT=$S/logs/mutants.out
for name in "$@"; do
  rsync -a --delete "$W/Sources/" "$M/Sources/"
  rsync -a --delete --exclude '.build-*' "$W/Tests/" "$M/Tests/"
  if [ "$PROBE" = "1" ]; then cp "$S/S3DC2ReqsRetryProbeTests.swift" "$M/Tests/ZTronAssetTransportTests/"; fi
  python3 "$S/mutate_reqs.py" "$M" "$name" >>"$OUT" || { echo "== $name-$TAG not applied" >>"$OUT"; continue; }
  log="$S/logs/mut-$name-$TAG.log"
  (cd "$M" && swift build --build-tests --scratch-path .build-mut >"$log" 2>&1)
  b=$?
  echo "== $name-$TAG build-exit=$b $(grep -c 'error:' "$log") errors" >>"$OUT"
  [ $b -eq 0 ] || continue
  start=$(date +%s)
  (cd "$M" && swift test --scratch-path .build-mut --skip Benchmarks --filter "$FILTER" >>"$log" 2>&1)
  t=$?
  end=$(date +%s)
  echo "== $name-$TAG test-exit=$t $(grep -E 'Test run with .* (passed|failed)' "$log" | tail -1) | wall $((end-start))s | $(uptime | sed 's/.*load/load/')" >>"$OUT"
done
# Leave the copy pristine.
rsync -a --delete "$W/Sources/" "$M/Sources/"
rsync -a --delete --exclude '.build-*' "$W/Tests/" "$M/Tests/"
echo "== RUN DONE $TAG $*" >>"$OUT"
