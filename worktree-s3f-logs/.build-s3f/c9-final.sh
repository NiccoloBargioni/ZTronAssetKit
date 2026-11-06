#!/bin/bash
# cycle 9 final-tree runs, in order: --quick, coverage from its profile, Sync x3, release build
WT=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
cd $WT
export TMPDIR=$WT/.build-s3f/tmp CLANG_MODULE_CACHE_PATH=$WT/.build-s3f/tmp/mc
mkdir -p $TMPDIR
S=.build-s3f/c9-final.samples; : > $S
( while true; do echo "$(date +%s) $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $S; sleep 5; done ) &
SP=$!
echo "== HEAD $(git rev-parse --short HEAD) status: $(git status --short | tr '\n' ' ')"
echo "== quick $(date +%T) $(sysctl -n vm.loadavg)"
SWIFTPM_SCRATCH=.build-s3f bash Scripts/verify.sh --quick > .build-s3f/c9-final-quick.log 2>&1
echo "quick exit $? $(date +%T) $(sysctl -n vm.loadavg)"
grep -E 'VERIFY:|SUMMARY' .build-s3f/c9-final-quick.log; cp .verify-logs/tests.log .build-s3f/c9-final-quick-tests.log; sed "s/\x1b\[[0-9;]*m//g" .build-s3f/c9-final-quick-tests.log | grep -E "Test run with"
echo "== coverage $(date +%T)"
bash .build-s3f/c6-cov.sh > .build-s3f/c9-final-cov.log 2>&1; echo "cov exit $?"
grep -E 'ZTronAssetSync |overall|COVERAGE:' .build-s3f/c9-final-cov.log
for i in 1 2 3; do
  echo "== sync $i $(date +%T) $(sysctl -n vm.loadavg)"
  swift test --scratch-path .build-s3f --skip Benchmarks --filter ZTronAssetSyncTests > .build-s3f/c9-final-sync-$i.log 2>&1
  echo "sync $i exit $? $(date +%T)"; sed 's/\x1b\[[0-9;]*m//g' .build-s3f/c9-final-sync-$i.log | grep -E 'Test run with'
done
echo "== release $(date +%T) $(sysctl -n vm.loadavg)"
swift build -c release --scratch-path .build-s3f -Xswiftc -warnings-as-errors > .build-s3f/c9-final-release.log 2>&1
echo "release exit $? $(date +%T)"; sed 's/\x1b\[[0-9;]*m//g' .build-s3f/c9-final-release.log | tail -1; grep -c 'warning:' .build-s3f/c9-final-release.log
echo "== done $(date +%T) $(sysctl -n vm.loadavg)"
kill $SP
