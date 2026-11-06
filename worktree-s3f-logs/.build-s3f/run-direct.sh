#!/bin/bash
# Runs one test bundle's Swift Testing tests directly (no SwiftPM workspace lock), with the env swift test sets.
# usage: run-direct.sh <scratch> <Target> <log> <swift-testing args...>
S=$1; T=$2; LOG=$3; shift 3
WT=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
P=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer
B=$S/out/Products/Debug/$T.xctest/Contents/MacOS/$T
H=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper
export TMPDIR=$WT/.build-s3f/tmp
export DYLD_FRAMEWORK_PATH=$P/Library/Frameworks DYLD_LIBRARY_PATH=$P/usr/lib
TSANLIB=$S/out/Products/Debug/$T.xctest/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib
if [ -f "$TSANLIB" ]; then export DYLD_INSERT_LIBRARIES=$TSANLIB; fi
cd $WT
$H --test-bundle-path $B $B --testing-library swift-testing "$@" > $LOG 2>&1
echo "exit $?"
