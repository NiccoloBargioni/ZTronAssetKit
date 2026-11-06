#!/bin/bash
# s3f c3 reqs verification: mutants in sequence (scratch).
cd "$(dirname "$0")"
FOLLOW='replacedContentFailure|noReplacedContentStarts|droppedUserJobWaitsForTheFollow|noStaleStarts|notFoundBeforeVisit|notFoundDuringFollowNoSeam'
run() { echo "### $(date +%T) load $(sysctl -n vm.loadavg)"; python3 -I run.py "$@"; }
run base 'noStaleStartsBetweenFollowTurns' 900
run noyield 'shutdownDrainsOverSeveralTurns' 900
run m5closeonly 'shutdownJoinsBeforeClosing' 900
run m5 'shutdownJoinsBeforeClosing' 900
run m6 'shutdownJoinsBeforeClosing' 900
run r3cancel 'uncommandedClientCancelRequeues' 900
run r5budget 'maintenanceStopsBeforeEviction|maintenanceStopsBetweenSteps' 900
run r2split 'failedRecordPublicationRefused' 900
run noFix "$FOLLOW" 1200
run noResolveAllHook "$FOLLOW" 1200
run noDispatchStall "$FOLLOW" 1200
echo "### done $(date +%T) load $(sysctl -n vm.loadavg)"
