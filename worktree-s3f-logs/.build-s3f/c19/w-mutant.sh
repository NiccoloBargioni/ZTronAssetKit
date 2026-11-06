#!/bin/bash
# Applies one mutant to the worktree's copy of a file, builds in .build-s3f, runs a filter twice, and restores the file
# (trap), then rebuilds. Usage: w-mutant.sh <name> <file> <old-file> <new-file> <filter>
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
cd "$W" || exit 1
export TMPDIR=$W/.build-s3f/tmp CLANG_MODULE_CACHE_PATH=$W/.build-s3f/tmp/mc LLVM_PROFILE_FILE=$W/.build-s3f/tmp/%p.profraw
NAME=$1; F=$2; OLD=$3; NEW=$4; FLT=$5
L=$W/.build-s3f/c19/wmut; mkdir -p $L
cp "$F" $L/$NAME.orig
restore() { cp $L/$NAME.orig "$F"; }
trap restore EXIT
python3 - "$F" "$OLD" "$NEW" <<'PY'
import sys
p, o, n = sys.argv[1], open(sys.argv[2]).read(), open(sys.argv[3]).read()
s = open(p).read()
assert s.count(o) == 1, s.count(o)
open(p, 'w').write(s.replace(o, n))
PY
[ $? -eq 0 ] || { echo "$NAME: edit failed"; exit 1; }
swift build --build-tests --scratch-path .build-s3f -Xswiftc -warnings-as-errors > $L/$NAME-build.log 2>&1 || { echo "$NAME: BUILD FAILED"; exit 1; }
for r in run1 run2; do
  swift test --scratch-path .build-s3f --skip-build --skip Benchmarks --filter "$FLT" > $L/$NAME-$r.log 2>&1
  echo "$NAME $r: $(grep 'Test run with' $L/$NAME-$r.log | tail -1) | $(grep 'recorded an issue' $L/$NAME-$r.log | sed 's/.* at //' | cut -d: -f1-2 | sort -u | head -4 | tr '\n' ' ') | load $(sysctl -n vm.loadavg)"
done
restore
trap - EXIT
cmp -s $L/$NAME.orig "$F" && echo "$NAME: restored"
swift build --build-tests --scratch-path .build-s3f -Xswiftc -warnings-as-errors > $L/$NAME-rebuild.log 2>&1; echo "$NAME: rebuild exit $?"
