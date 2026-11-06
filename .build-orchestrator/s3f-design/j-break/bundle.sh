#!/bin/bash
# bundle.sh <key> <logname>: the committed ZTronAssetSyncTests bundle (debug), probes skipped.
k=$1; name=$2
L=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-design/j-break/logs
W=/Users/admin/Documents/ZTronAssetKit/.build-s3f-j-break-$k-wt
cd $W && swift test --scratch-path .build-x --skip-build --filter ZTronAssetSyncTests --skip "VerifyC7|VerifyC8|VerifyDDefer|DesignBudget|DesignD3|JBreak" > $L/$name.log 2>&1
echo "exit=$?"
grep -E "Test run with|✘ Test .*(failed|recorded)|time limit" $L/$name.log | cut -c1-300 | head -20
