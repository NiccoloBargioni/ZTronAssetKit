#!/bin/bash
# usage: covexport.sh <profdata> <out.json>
cd /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=.build-verify-s3f-c5-reqs
B=($(ls -d $S/out/Products/Debug/*.xctest))
first="${B[0]}/Contents/MacOS/$(basename ${B[0]} .xctest)"
objs=()
for b in "${B[@]:1}"; do objs+=(-object "$b/Contents/MacOS/$(basename $b .xctest)"); done
echo "first=$first objects=${#objs[@]}"
xcrun llvm-cov export -summary-only -instr-profile "$1" "$first" "${objs[@]}" > "$2"
python3 Scripts/gates.py coverage --json "$2"
