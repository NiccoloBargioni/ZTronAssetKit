#!/bin/bash
# Runs the C2 measurements one by one, each started once the 1-minute load is at most 10 (or after a 20-minute wait).
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=$W/.build-verify-s3f-c20-correct
export TMPDIR=$S/tmp
Q=$S/logs/quiet.meta
one() { sysctl -n vm.loadavg | awk '{print $2}'; }
wait_quiet() {
  local t=0
  while :; do
    if awk -v l="$(one)" 'BEGIN{exit !(l<=10)}'; then echo "$(date +%H:%M:%S) quiet for $1 $(sysctl -n vm.loadavg)" >> $Q; return 0; fi
    if [ $t -ge 1200 ]; then echo "$(date +%H:%M:%S) NOT quiet after 20 min for $1 $(sysctl -n vm.loadavg)" >> $Q; return 1; fi
    sleep 5; t=$((t+5))
  done
}
for step in "$@"; do
  wait_quiet $step
  case $step in
    deferq) bash $S/bin/relprobes.sh deferq deferBehindTurns PROBE_C20C_COUNT=10000 PROBE_C20C_REPEATS=3 > /dev/null 2>&1 ;;
    superq) bash $S/bin/relprobes.sh superq VerifyC20SupersedeBench > /dev/null 2>&1 ;;
    userq) bash $S/bin/relprobes.sh userq VerifyC19UserBench > /dev/null 2>&1 ;;
    drainq) bash $S/bin/relprobes.sh drainq VerifyC19DrainBench > /dev/null 2>&1 ;;
    bench)
      cd $W
      echo "bench start $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" > $S/logs/bench.meta
      swift test -c release --scratch-path .build-verify-s3f-c20-correct-perf -Xswiftc -enable-testing --filter Benchmarks > $S/logs/bench.log 2>&1
      echo "bench end rc=$? $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $S/logs/bench.meta
      ;;
  esac
  echo "$(date +%H:%M:%S) done $step $(sysctl -n vm.loadavg)" >> $Q
done
echo "$(date +%H:%M:%S) all done" >> $Q
