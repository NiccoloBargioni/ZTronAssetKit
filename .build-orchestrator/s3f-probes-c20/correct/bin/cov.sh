#!/bin/bash
cd /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=.build-verify-s3f-c20-correct
export TMPDIR=$PWD/$S/tmp
unset LLVM_PROFILE_FILE
echo "cov start $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" > $S/logs/cov.meta
swift test --scratch-path $S --enable-code-coverage --skip Benchmarks > $S/logs/cov-test.log 2>&1
echo "cov test end rc=$? $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $S/logs/cov.meta
bins=()
for b in $S/out/Products/Debug/*.xctest; do n=$(basename "$b" .xctest); bins+=("$b/Contents/MacOS/$n"); done
args=("${bins[0]}")
for o in "${bins[@]:1}"; do args+=(-object "$o"); done
xcrun llvm-cov export -summary-only -instr-profile $S/out/Products/Debug/codecov/default.profdata "${args[@]}" > $S/cov.json 2> $S/logs/cov-export.err
echo "export rc=$? $(date +%H:%M:%S)" >> $S/logs/cov.meta
python3 Scripts/gates.py coverage --json $S/cov.json > $S/logs/cov-gate.log 2>&1
echo "gate rc=$? $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $S/logs/cov.meta
