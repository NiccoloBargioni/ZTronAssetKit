#!/bin/bash
# Waits for a 1-minute load under 6 (at most 5 minutes), then runs the cited probes one suite at a time.
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c21-reqs
for i in $(seq 1 60); do
  l=$(sysctl -n vm.loadavg | awk '{print $2}')
  if awk -v l="$l" 'BEGIN{exit !(l < 6)}'; then break; fi
  sleep 5
done
echo "quiet wait ended $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $S/logs/probe-times.txt
bash $S/tools/proberun.sh c20r 'VerifyC20ReqsC2Probes'
bash $S/tools/proberun.sh c20c 'VerifyC20Correct/deferBehindTurns' 'VerifyC20Correct/manyMovesTurns' 'VerifyC20Correct/drainBoundAllTurns'
bash $S/tools/proberun.sh c21 'ProbeC21APM'
bash $S/tools/proberun.sh c20sup 'VerifyC20SupersedeBench'
