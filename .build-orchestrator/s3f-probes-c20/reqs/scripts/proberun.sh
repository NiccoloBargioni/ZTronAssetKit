#!/bin/bash
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c20-reqs
export TMPDIR=$S/tmp CLANG_MODULE_CACHE_PATH=$S/tmp/modcache
cd $S/probesrc || exit 2
T=$S/logs/gates/times.txt
tag=${1:-probe1}
echo "$(date +%H:%M:%S) $tag start load $(sysctl -n vm.loadavg)" >> $T
bash $S/scripts/loadsampler.sh $S/logs/$tag-load.txt 5 & SP=$!
swift test -c release --skip-build --scratch-path $S/probebuild -Xswiftc -enable-testing --filter VerifyC20ReqsC2Probes > $S/logs/$tag.log 2>&1
rc=$?
kill $SP 2>/dev/null; wait $SP 2>/dev/null
echo "$(date +%H:%M:%S) $tag exit $rc load $(sysctl -n vm.loadavg)" >> $T
