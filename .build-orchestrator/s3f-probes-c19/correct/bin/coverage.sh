#!/bin/bash
# Scratch runner: coverage run, export and gate; removes sim.lock right after the run (S3-R22 item 3).
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=$W/.build-verify-s3f-c19-correct
L=$S/logs
LOCK=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/sim.lock
cd "$W" || exit 2
echo "start $(date '+%H:%M:%S') load $(sysctl -n vm.loadavg)" > "$L/cov.log"
TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/modcache LLVM_PROFILE_FILE=$S/tmp/prof/default-%p.profraw swift test --scratch-path .build-verify-s3f-c19-correct --enable-code-coverage --skip Benchmarks >> "$L/cov.log" 2>&1
rc=$?
echo "test exit $rc end $(date '+%H:%M:%S') load $(sysctl -n vm.loadavg)" >> "$L/cov.log"
rmdir "$LOCK" && echo "lock removed $(date '+%H:%M:%S')" >> "$L/cov.log"
B=.build-verify-s3f-c19-correct/out/Products/Debug
ls -d $B/*.xctest >> "$L/cov.log" 2>&1
bins=()
for x in $B/*.xctest; do
  if [ -d "$x/Contents/MacOS" ]; then bins+=("$x/Contents/MacOS/$(basename "$x" .xctest)"); else bins+=("$x"); fi
done
first=${bins[0]}
objs=()
for b in "${bins[@]:1}"; do objs+=(-object "$b"); done
xcrun llvm-cov export -summary-only -instr-profile $B/codecov/default.profdata "$first" "${objs[@]}" > .build-verify-s3f-c19-correct/cov.json 2>> "$L/cov.log"
echo "export exit $?" >> "$L/cov.log"
python3 Scripts/gates.py coverage --json .build-verify-s3f-c19-correct/cov.json >> "$L/cov.log" 2>&1
echo "gate exit $?" >> "$L/cov.log"
