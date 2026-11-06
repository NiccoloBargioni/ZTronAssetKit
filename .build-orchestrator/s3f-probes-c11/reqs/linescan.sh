#!/bin/bash
cd /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
B=.build-verify-s3f-c11-reqs/out/Products/Debug
P=$B/codecov/default.profdata
BIN=$B/ZTronAssetSyncTests.xctest/Contents/MacOS/ZTronAssetSyncTests
E=Sources/ZTronAssetSync/Engine
show() { xcrun llvm-cov show "$BIN" -instr-profile="$P" "$1" 2>&1 | sed -n "$2"; }
for spec in "$E/EngineReadmission.swift 110,116p" "$E/EngineReadmission.swift 196,201p" "$E/EngineTimers.swift 112,119p" "$E/EngineJobs.swift 325,330p" "$E/EngineJobs.swift 471,479p" "$E/EngineFollow.swift 193,233p" "$E/EngineFollow.swift 434,440p" "$E/EngineCommands.swift 462,467p" "$E/EngineCommands.swift 527,532p" "$E/EngineCommands.swift 997,1002p" "$E/EngineCommands.swift 1524,1529p"; do
  set -- $spec; echo "--- $1 $2"; show "$1" "$2"
done
