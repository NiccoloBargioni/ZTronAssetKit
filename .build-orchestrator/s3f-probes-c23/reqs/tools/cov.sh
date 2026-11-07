#!/bin/bash
# Cycle-23 reqs verifier: coverage export over every .xctest bundle of MY --quick run, the coverage gate, and the
# execution counts of S1's changed lines (EngineCommands.swift 975-977, 986, 1006-1013 at d88bdb1).
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
R=$W/.build-verify-s3f-c23-reqs
cd $W || exit 1
P=$R/out/Products/Debug
prof=$P/codecov/default.profdata
[ -f "$prof" ] || { echo "no profile at $prof"; exit 1; }
first=""; objs=()
while IFS= read -r b; do
  bin="$b/Contents/MacOS/$(basename "$b" .xctest)"; [ -f "$bin" ] || continue
  if [ -z "$first" ]; then first="$bin"; else objs+=(-object "$bin"); fi
done < <(find "$P" -maxdepth 1 -name '*.xctest' -type d | sort)
echo "bundles: $(( ${#objs[@]} / 2 + 1 ))"
xcrun llvm-cov export -summary-only -instr-profile "$prof" "$first" "${objs[@]}" > $R/cov.json || exit 1
python3 Scripts/gates.py coverage --json $R/cov.json > $R/logs/cov-gate.log 2>&1; echo "gate rc=$?"
tail -25 $R/logs/cov-gate.log
xcrun llvm-cov show -instr-profile "$prof" "$first" "${objs[@]}" "$W/Sources/ZTronAssetSync/Engine/EngineCommands.swift" > $R/logs/cov-enginecommands.txt 2>&1
echo "--- S1 lines (line|count|source)"
awk -F'|' '{gsub(/ /,"",$1)} $1>=970 && $1<=1014' $R/logs/cov-enginecommands.txt | cut -c1-150
