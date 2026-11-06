#!/bin/bash
cd "$(dirname "$0")"
FOLLOW='replacedContentFailure|noReplacedContentStarts|droppedUserJobWaitsForTheFollow|noStaleStarts|notFoundBeforeVisit|notFoundDuringFollowNoSeam'
run() { echo "### $(date +%T) load $(sysctl -n vm.loadavg)"; python3 -I run.py "$@"; }
run noCountHook "$FOLLOW" 1200
run noSpaceHook "$FOLLOW" 1200
run listedOnlyAtDispatch "$FOLLOW" 1200
run owedVisitsOnly "$FOLLOW" 1200
run userHeadCounted "$FOLLOW" 1200
run noFlagPump 'ZTronAssetSyncTests' 1800
run noDispatchOwedFlag 'ZTronAssetSyncTests' 1800
echo "### done $(date +%T) load $(sysctl -n vm.loadavg)"
