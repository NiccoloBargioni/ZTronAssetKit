#!/bin/bash
# Usage: bash run_mutants.sh <tag> <filter> <repeats> <mutant>...   (scratch copy only)
set -u
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3d
S=$W/.build-verify-s3d-c3-reqs
M=$S/mutpkg
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/module-cache LLVM_PROFILE_FILE=$S/tmp/stray-%p.profraw
TAG="$1"; FILTER="$2"; REP="$3"; shift 3
OUT=$S/logs/mutants.out
for name in "$@"; do
  cp "$W/Package.swift" "$M/Package.swift"
  rsync -a --delete "$W/Sources/" "$M/Sources/"
  rsync -a --delete --exclude '.build-*' "$W/Tests/" "$M/Tests/"
  python3 "$S/mutate.py" "$M" "$name" >>"$OUT" || { echo "== $name-$TAG not applied" >>"$OUT"; continue; }
  log="$S/logs/mut-$name-$TAG.log"
  (cd "$M" && swift build --build-tests --scratch-path .build-mut >"$log" 2>&1)
  b=$?
  echo "== $name-$TAG build-exit=$b $(grep -c 'error:' "$log") errors" >>"$OUT"
  [ $b -eq 0 ] || continue
  for i in $(seq 1 "$REP"); do
    start=$(date +%s)
    (cd "$M" && swift test --scratch-path .build-mut --skip Benchmarks --filter "$FILTER" >"$log.run$i" 2>&1)
    t=$?
    end=$(date +%s)
    echo "== $name-$TAG run$i test-exit=$t $(grep -E 'Test run with .* (passed|failed)' "$log.run$i" | tail -1) | wall $((end-start))s | $(uptime | sed 's/.*load/load/')" >>"$OUT"
    grep -E '^✘ Test .*recorded an issue|↳' "$log.run$i" | head -8 >>"$OUT"
  done
done
cp "$W/Package.swift" "$M/Package.swift"
rsync -a --delete "$W/Sources/" "$M/Sources/"
rsync -a --delete --exclude '.build-*' "$W/Tests/" "$M/Tests/"
echo "== RUN DONE $TAG $*" >>"$OUT"
