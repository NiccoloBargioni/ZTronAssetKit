#!/bin/bash
# Debug build (with tests) of each judge worktree, in sequence.
L=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-design/j-break/logs
for k in "$@"; do
  W=/Users/admin/Documents/ZTronAssetKit/.build-s3f-j-break-$k-wt
  start=$(date +%s)
  (cd $W && swift build --build-tests --scratch-path .build-x -Xswiftc -warnings-as-errors > $L/build-$k.log 2>&1)
  echo "build $k exit=$? secs=$(( $(date +%s) - start ))" >> $L/build-status.log
done
