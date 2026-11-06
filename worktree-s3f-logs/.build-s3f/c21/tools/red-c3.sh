#!/bin/bash
# Builds the red copy (HEAD's sources and the new tests) and runs the red set on it.
cd /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
export TMPDIR=$PWD/.build-s3f/tmp CLANG_MODULE_CACHE_PATH=$PWD/.build-s3f/tmp/module-cache LLVM_PROFILE_FILE=$PWD/.build-s3f/tmp/default-%p.profraw
RED=$PWD/.build-s3f/red
OUT=$PWD/.build-s3f/c21/red-c3
mkdir -p $OUT
echo "start $(date +%H:%M) rev $(cat $RED/REV) load $(sysctl -n vm.loadavg)" > $OUT/summary.txt
(cd $RED && swift build --build-tests --scratch-path $PWD/.build-s3f/redbuild -Xswiftc -warnings-as-errors) > $OUT/build.log 2>&1
echo "build exit $?" >> $OUT/summary.txt
(cd $RED && swift test --skip-build --scratch-path $PWD/.build-s3f/redbuild --skip Benchmarks --filter "${RED_FILTER:-commitOwesItsReroutes|twoCommitsOweABatchEach|commitOwesWhenItsAnswers|commitReroutesAtOnceWhenItFits|commitWithNothingToRerouteOwesNothing|drainReroutesAnOwedIDWithAllItsTokens}") > $OUT/tests.log 2>&1
echo "tests exit $? load $(sysctl -n vm.loadavg)" >> $OUT/summary.txt
(cd $RED && swift test --skip-build --scratch-path $PWD/.build-s3f/redbuild --filter "${RED_BENCH:-commitRerouteDivergentTurns}") > $OUT/bench.log 2>&1
echo "bench exit $? load $(sysctl -n vm.loadavg)" >> $OUT/summary.txt
echo "end $(date +%H:%M)" >> $OUT/summary.txt
