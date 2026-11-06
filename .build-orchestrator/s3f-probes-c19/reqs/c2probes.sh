#!/bin/bash
# Cycle-18 C2 probes at HEAD, release (scratch only): best of 3 inside each probe; load stamps around each.
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c19-reqs
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/modcache LLVM_PROFILE_FILE=$S/tmp/prof-%p.profraw
cd $S/perfsrc || exit 2
G=$S/logs/gates
T=$G/times.txt
for probe in VerifyC18ReqsTurns VerifyC18ReqsDivergence; do
  echo "$(date +%H:%M:%S) c2 $probe start load $(sysctl -n vm.loadavg)" >> $T
  bash $S/loadsampler.sh $G/c2-$probe-load.txt 5 & SAMPLER=$!
  swift test -c release --skip-build --scratch-path ../probeperf -Xswiftc -enable-testing --filter $probe > $G/c2-$probe.log 2>&1
  code=$?
  kill $SAMPLER 2>/dev/null; wait $SAMPLER 2>/dev/null
  echo "$(date +%H:%M:%S) c2 $probe exit $code load $(sysctl -n vm.loadavg)" >> $T
done
