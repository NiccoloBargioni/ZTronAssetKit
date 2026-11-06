#!/bin/bash
# Re-runs the simulator's failing test alone on macOS (scratch only).
W=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=$W/.build-verify-s3f-c19-reqs
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/modcache LLVM_PROFILE_FILE=$S/tmp/prof-%p.profraw
cd $W || exit 2
F=$S/logs/flake
T=$F/times.txt
stamp() { echo "$(date +%H:%M:%S) $1 load $(sysctl -n vm.loadavg)" >> $T; }
bash $S/loadsampler.sh $F/mac-load.txt 5 & SAMPLER=$!
stamp "mac rep30 start"
swift test --skip-build --scratch-path .build-verify-s3f-c19-reqs --filter barrierReadmitsBehindTheOwedVisitsPlaces --maximum-repetitions 30 > $F/mac-rep30.log 2>&1
stamp "mac rep30 exit $?"
for i in $(seq 1 10); do
  swift test --skip-build --scratch-path .build-verify-s3f-c19-reqs --filter barrierReadmitsBehindTheOwedVisitsPlaces > $F/mac-sep-$i.log 2>&1
  stamp "mac sep$i exit $?"
done
kill $SAMPLER 2>/dev/null; wait $SAMPLER 2>/dev/null
stamp "mac done"
