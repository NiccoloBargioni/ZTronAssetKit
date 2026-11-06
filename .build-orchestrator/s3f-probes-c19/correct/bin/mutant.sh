#!/bin/bash
# Scratch mutant runner (probe tree copy only): mutant.sh NAME FILE OLD NEW FILTER
# Applies one exact replacement to the probe tree's copy of FILE, builds the tests in debug, runs FILTER twice, restores.
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=$W/.build-verify-s3f-c19-correct
P=$S/probesrc
NAME=$1; FILE=$2; OLD=$3; NEW=$4; FILTER=$5
LOG=$S/logs/mut-$NAME.log
restore() { cp "$W/$FILE" "$P/$FILE"; echo "restored $(cmp -s "$W/$FILE" "$P/$FILE" && echo identical || echo DIFFERENT)" >> "$LOG"; }
trap restore EXIT
cd "$P" || exit 2
echo "mutant $NAME start $(date '+%H:%M:%S') load $(sysctl -n vm.loadavg)" > "$LOG"
OLD="$OLD" NEW="$NEW" python3 -I - "$P/$FILE" >> "$LOG" 2>&1 <<'PY' || exit 3
import os, sys
path = sys.argv[1]
old, new = os.environ["OLD"], os.environ["NEW"]
text = open(path).read()
n = text.count(old)
print("occurrences", n)
if n != 1:
    sys.exit(1)
open(path, "w").write(text.replace(old, new))
PY
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/modcache
swift build --build-tests --scratch-path ../probebuild > "$S/logs/mut-$NAME-build.log" 2>&1
echo "build exit $? $(tail -1 "$S/logs/mut-$NAME-build.log") $(date '+%H:%M:%S') load $(sysctl -n vm.loadavg)" >> "$LOG"
for run in 1 2; do
  swift test --skip-build --scratch-path ../probebuild --filter "$FILTER" > "$S/logs/mut-$NAME-run$run.log" 2>&1
  echo "run $run exit $? $(grep -E '^(✔|✘) Test run' "$S/logs/mut-$NAME-run$run.log" | tail -1) $(date '+%H:%M:%S') load $(sysctl -n vm.loadavg)" >> "$LOG"
done
