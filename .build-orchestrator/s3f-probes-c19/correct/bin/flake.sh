#!/bin/bash
# Scratch: repeats one test in the probe tree's debug build, logging each run's result and the load.
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c19-correct
FILTER=$1; N=$2; TAG=$3
cd $S/probesrc || exit 2
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/modcache
L=$S/logs/flake-$TAG.log
echo "start $(date '+%H:%M:%S') load $(sysctl -n vm.loadavg)" > $L
for i in $(seq 1 $N); do
  swift test --skip-build --scratch-path ../probebuild --filter "$FILTER" > $S/logs/flake-$TAG-$i.log 2>&1
  rc=$?
  echo "run $i exit $rc $(grep -E '^(✔|✘) Test run' $S/logs/flake-$TAG-$i.log | tail -1 | cut -c1-90) load $(sysctl -n vm.loadavg) $(date '+%H:%M:%S')" >> $L
  if [ $rc -eq 0 ]; then rm -f $S/logs/flake-$TAG-$i.log; fi
done
echo "end $(date '+%H:%M:%S')" >> $L
