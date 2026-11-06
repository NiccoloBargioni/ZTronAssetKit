#!/bin/bash
# usage: run-direct.sh <tsan-scratch> <log>
WT=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
S=$WT/$1; LOG=$2; T=ZTronAssetSyncTests
P=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer
B=$S/out/Products/Debug/$T.xctest/Contents/MacOS/$T
H=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper
export TMPDIR=$WT/.build-verify-s3f-c5-reqs/tmp/
export DYLD_FRAMEWORK_PATH=$P/Library/Frameworks DYLD_LIBRARY_PATH=$P/usr/lib
TSANLIB=$S/out/Products/Debug/$T.xctest/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib
if [ -f "$TSANLIB" ]; then export DYLD_INSERT_LIBRARIES=$TSANLIB; fi
cd $WT
$H --test-bundle-path $B $B --testing-library swift-testing > $LOG 2>&1
echo "exit $?" >> $LOG
