#!/bin/bash
# Cycle-11 reqs-lens verifier: release build, unsafe/docs gates, Sync x3, TSan, iOS generic build, S3-R13 export check.
WT=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
R=$WT/.build-verify-s3f-c11-reqs
L=$R/logs
cd "$WT" || exit 1
export TMPDIR=$R/tmp CLANG_MODULE_CACHE_PATH=$R/tmp/mc LLVM_PROFILE_FILE=$R/tmp/%p.profraw
sample() { while true; do echo "$(date +%H:%M:%S) $(sysctl -n vm.loadavg)"; sleep 5; done; }
stamp() { echo "=== $1 $(date +%H:%M:%S) $(sysctl -n vm.loadavg)"; }

stamp release
swift build -c release --scratch-path .build-verify-s3f-c11-reqs -Xswiftc -warnings-as-errors > $L/release.log 2>&1; echo "release exit $?"
grep -c 'warning:' $L/release.log; tail -1 $L/release.log

stamp gates
python3 Scripts/gates.py unsafe --sources "$PWD/Sources" --audit docs/UNSAFE-AUDIT.md > $L/gates.log 2>&1 && python3 Scripts/gates.py docs --sources "$PWD/Sources" >> $L/gates.log 2>&1; echo "gates exit $?"
grep -E 'UNSAFE|DOCS' $L/gates.log

for i in 1 2 3; do
  stamp sync$i
  sample > $L/load-sync$i.txt & SP=$!
  swift test --scratch-path .build-verify-s3f-c11-reqs --skip Benchmarks --filter ZTronAssetSyncTests > $L/sync$i.log 2>&1; echo "sync$i exit $?"
  kill $SP
  grep -E '(✔|✘) Test run with' $L/sync$i.log | tail -1
  grep -c 'Time limit was exceeded' $L/sync$i.log
done

stamp tsan
sample > $L/load-tsan.txt & SP=$!
swift test --scratch-path .build-verify-s3f-c11-reqs-tsan --sanitize=thread --skip Benchmarks --filter ZTronAssetSyncTests > $L/tsan.log 2>&1; echo "tsan exit $?"
kill $SP
grep -E '(✔|✘) Test run with' $L/tsan.log | tail -1
echo "tsan reports $(grep -c 'WARNING: ThreadSanitizer' $L/tsan.log) timeouts $(grep -c 'Time limit was exceeded' $L/tsan.log)"

stamp ios
xcodebuild -scheme ZTronAssetKit -destination 'generic/platform=iOS' -derivedDataPath .build-verify-s3f-c11-reqs/xcode build OTHER_SWIFT_FLAGS='-warnings-as-errors' -quiet > $L/ios.log 2>&1; echo "ios exit $?"
grep -c 'warning:' $L/ios.log; grep -c 'error:' $L/ios.log

stamp t64
rm -rf $R/t64 && mkdir -p $R/t64 && git archive HEAD | tar -x -C $R/t64
sed -i '' '1s|.*|// swift-tools-version: 6.4|' $R/t64/Package.swift; head -1 $R/t64/Package.swift
(cd $R/t64 && swift build --build-tests --scratch-path $R/t64-build -Xswiftc -warnings-as-errors > $L/t64.log 2>&1; echo "t64 build-tests exit $?")
echo "t64 warnings $(grep -c 'warning:' $L/t64.log) errors $(grep -c 'error:' $L/t64.log)"; tail -1 $L/t64.log
(cd $R/t64 && swift build -c release --scratch-path $R/t64-build > $L/t64-release.log 2>&1; echo "t64 release exit $?")
echo "t64 release warnings $(grep -c 'warning:' $L/t64-release.log)"; tail -1 $L/t64-release.log
stamp done
