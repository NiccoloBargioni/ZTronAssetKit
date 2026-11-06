#!/bin/bash
# Runs one test bundle's Swift Testing tests directly (no SwiftPM lock). Copy of the hunter's run-direct.sh with this
# agent's own TMPDIR and worktree. usage: run-direct.sh <scratch> <Target> <log> <swift-testing args...>
S=$1; T=$2; LOG=$3; shift 3
P=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer
B=$S/out/Products/Debug/$T.xctest/Contents/MacOS/$T
[ -f "$B" ] || B=$S/debug/$T.xctest/Contents/MacOS/$T
H=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper
export TMPDIR=/Users/admin/Documents/ZTronAssetKit/.build-s3-confirm-stability/tmp
export DYLD_FRAMEWORK_PATH=$P/Library/Frameworks DYLD_LIBRARY_PATH=$P/usr/lib
TSANLIB=$(dirname $(dirname $B))/Frameworks/libclang_rt.tsan_osx_dynamic.dylib
if [ -f "$TSANLIB" ]; then export DYLD_INSERT_LIBRARIES=$TSANLIB; fi
cd /Users/admin/Documents/ZTronAssetKit/.build-s3-confirm-stability-wt
$H --test-bundle-path $B $B --testing-library swift-testing "$@" > $LOG 2>&1
echo "exit $?"
