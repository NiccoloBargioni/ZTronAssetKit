#!/bin/bash
cd /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=.build-verify-s3f-c6-reqs
B=($(ls -d $S/out/Products/Debug/*.xctest))
first="${B[0]}/Contents/MacOS/$(basename ${B[0]} .xctest)"
objs=()
for b in "${B[@]:1}"; do objs+=(-object "$b/Contents/MacOS/$(basename $b .xctest)"); done
echo "first=$first objects=${#objs[@]}"
xcrun llvm-cov export -summary-only -instr-profile $S/out/Products/Debug/codecov/default.profdata "$first" "${objs[@]}" > $S/cov.json
python3 Scripts/gates.py coverage --json $S/cov.json
