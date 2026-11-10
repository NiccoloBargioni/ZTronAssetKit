#!/bin/bash
P=/Users/admin/Documents/ZTronAssetKit/.build-prof40
export TMPDIR=$P/tmp CLANG_MODULE_CACHE_PATH=$P/tmp/modcache
cd $P/src || exit 2
tag=$1
for name in concentrationCommitRerouteTurns movedBeforeDrainTurns VerifyC20SupersedeBench; do
  echo "$tag-$name start $(date +%T) $(sysctl -n vm.loadavg)" >> $P/out/loads.txt
  swift test -c release --skip-build --scratch-path $P/spm -Xswiftc -enable-testing --filter $name > $P/out/$tag-$name.log 2>&1
  echo "$tag-$name end rc=$? $(date +%T) $(sysctl -n vm.loadavg)" >> $P/out/loads.txt
done
