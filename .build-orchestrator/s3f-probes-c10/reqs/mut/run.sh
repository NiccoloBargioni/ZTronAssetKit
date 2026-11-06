#!/bin/bash
R=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c10-reqs
export TMPDIR=$R/tmp CLANG_MODULE_CACHE_PATH=$R/tmp/mc
cd $R/copy-head
for n in "$@"; do
  python3 $R/mut/apply.py $R/mut/mutants.py . $n apply
  F=$(python3 $R/mut/apply.py $R/mut/mutants.py . $n filter)
  swift build --build-tests --scratch-path $R/b-head > $R/mut/build-$n.log 2>&1; echo "$n build exit $? $(date +%T) $(sysctl -n vm.loadavg)"
  for i in 1 2; do
    swift test --scratch-path $R/b-head --skip-build --filter "$F" > $R/mut/test-$n-$i.log 2>&1; echo "$n test $i exit $? $(date +%T)"
  done
  python3 $R/mut/apply.py $R/mut/mutants.py . $n revert
done
diff -r /Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Sources $R/copy-head/Sources && echo "copy-head sources restored"
