#!/bin/bash
# run.sh <key> <logname> <filter> : debug probe run in the judge worktree, summary to stdout.
k=$1; name=$2; filter=$3
L=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-design/j-break/logs
W=/Users/admin/Documents/ZTronAssetKit/.build-s3f-j-break-$k-wt
cd $W && swift test --scratch-path .build-x --skip-build --filter "$filter" > $L/$name.log 2>&1
echo "exit=$?"
grep -E "Test run with|✘ Test .*(failed|recorded)|Expectation failed|time limit|Issue recorded" $L/$name.log | sed -E 's/^.{0,0}//' | cut -c1-400 | head -40
