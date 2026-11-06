#!/bin/bash
# Waits for item A's mutant run, then runs candidate 4's, K4's and T1-space's, then item B's, on the snapshot.
cd /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
while pgrep -f "c21/tools/mut21.py" > /dev/null; do sleep 30; done
SNAP=$PWD/.build-s3f/c21/snap-b
echo "start $(date +%H:%M) rev $(cat $SNAP/REV) load $(sysctl -n vm.loadavg)" > .build-s3f/c21/mut21-c4.txt
MUT_SNAP=$SNAP MUT_EXTRA=.build-s3f/c21/tools/mut-c4.py python3 .build-s3f/c21/tools/mut21s.py >> .build-s3f/c21/mut21-c4.txt 2>&1
echo "end $(date +%H:%M) load $(sysctl -n vm.loadavg)" >> .build-s3f/c21/mut21-c4.txt
echo "start $(date +%H:%M) rev $(cat $SNAP/REV) load $(sysctl -n vm.loadavg)" > .build-s3f/c21/mut21-b.txt
MUT_SNAP=$SNAP MUT_EXTRA=.build-s3f/c21/tools/mut-b.py python3 .build-s3f/c21/tools/mut21s.py >> .build-s3f/c21/mut21-b.txt 2>&1
echo "end $(date +%H:%M) load $(sysctl -n vm.loadavg)" >> .build-s3f/c21/mut21-b.txt
