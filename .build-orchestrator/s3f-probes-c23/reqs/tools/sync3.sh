#!/bin/bash
# Cycle-23 reqs verifier: ZTronAssetSyncTests three consecutive times (debug, my scratch path), each logged.
R=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c23-reqs
for i in 1 2 3; do
  bash $R/tools/run.sh sync$i swift test --scratch-path .build-verify-s3f-c23-reqs --skip Benchmarks --filter ZTronAssetSyncTests
done
