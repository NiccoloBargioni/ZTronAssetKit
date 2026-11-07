#!/bin/bash
# Run 13, the close ruling's point 7: on the final HEAD, verify.sh --quick, then --gates-only, then --full. Every stage
# is stamped with the three load averages (S3-R23 item 1) and sampled every 5 s; verify.sh's step lines and the
# benchmark step's result lines are stamped as they appear (watch.py). sim.lock is held for the coverage runs (--quick,
# and --full, whose three test runs carry coverage). Each mode's .verify-logs are copied, and docs/TRACEABILITY.md is
# restored after --gates-only and --full. A mode that does not end as expected stops the script.
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
source $W/.build-s3f/c20/env.sh
C=$W/.build-s3f/c23/close
TOOLS=$W/.build-s3f/c23/tools
mkdir -p $C
T=$C/times.txt
LOCK=/Users/admin/Documents/ZTronAssetKit/.build-orchestrator/sim.lock
stamp() { echo "$(date +%H:%M:%S) $1 load $(sysctl -n vm.loadavg)" >> $T; }
sampler() { while [ ! -e "$2" ]; do echo "$(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $1; sleep 5; done; }
takelock() {
    stamp "$1 waiting for lock"
    until mkdir $LOCK 2>/dev/null; do sleep 15; done
    echo "s3f WP-F close (run 13, point 7) $1 $(date +%H:%M:%S)" > $LOCK/owner
    stamp "$1 lock taken"
}
droplock() { rm -rf $LOCK; stamp "$1 lock released"; }
restore_trace() {
    git diff --stat -- docs/TRACEABILITY.md > $C/trace-diff-$1.txt
    git checkout -- docs/TRACEABILITY.md
    stamp "$1 traceability restored, dirty $(git status --short | wc -l | tr -d ' ')"
}
runmode() {  # runmode <name> <verify flag>
    local name=$1 flag=$2 stop=$C/$1.stop
    rm -f $stop
    : > $C/$name.log
    sampler $C/$name-load.txt $stop &
    python3 $TOOLS/watch.py $C/$name.log $C/$name-steps.txt '^:::' $stop &
    if [ "$name" = full ]; then
        python3 $TOOLS/watch.py $W/.verify-logs/benchmarks.log $C/$name-bench-lines.txt '(✔|✘|◇ Test|^C2 |issue)' $stop from-end &
    fi
    SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh $flag > $C/$name.log 2>&1; RC=$?
    sleep 2; touch $stop; wait
    stamp "$name exit $RC: $(tail -1 $C/$name.log)"
    rm -rf $C/$name-logs; cp -R $W/.verify-logs $C/$name-logs
}
cd $W
: > $T
stamp "start head $(git rev-parse --short HEAD) dirty $(git status --short | wc -l | tr -d ' ')"
takelock quick
runmode quick --quick
mkdir -p $C/covcopy
cp .build-s3f/out/Products/Debug/codecov/default.profdata $C/covcopy/default.profdata
for b in $(ls -d .build-s3f/out/Products/Debug/*.xctest | grep -v Benchmarks); do rm -rf $C/covcopy/$(basename $b); cp -R $b $C/covcopy/; done
droplock quick
[ $RC -eq 0 ] || { stamp "stop: quick"; exit 1; }
runmode gates --gates-only
restore_trace gates
[ $RC -eq 0 ] || { stamp "stop: gates"; exit 1; }
swift build -c release --scratch-path .build-s3f-perf -Xswiftc -enable-testing --build-tests > $C/bench-prebuild.log 2>&1
stamp "bench prebuild exit $?"
takelock full
runmode full --full
restore_trace full
droplock full
stamp "done dirty $(git status --short | wc -l | tr -d ' ')"
git status --short > $C/status-after.txt
