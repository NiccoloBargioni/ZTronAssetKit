#!/bin/bash
# Runs one Swift Testing bundle directly through swiftpm-testing-helper (no SwiftPM lock, unbuffered output), with an
# optional scoped watchdog. usage: run-direct.sh <scratch> <Target> <log> <watchdog-seconds|0> <swift-testing args...>
S=$1; T=$2; LOG=$3; WD=$4; shift 4
P=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer
B=$S/out/Products/Debug/$T.xctest/Contents/MacOS/$T
[ -f "$B" ] || B=$S/debug/$T.xctest/Contents/MacOS/$T
H=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper
export TMPDIR=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3c/.build-verify-s3c-c1-reqs/tmp
export DYLD_FRAMEWORK_PATH=$P/Library/Frameworks DYLD_LIBRARY_PATH=$P/usr/lib
TSANLIB=$(dirname $(dirname $B))/Frameworks/libclang_rt.tsan_osx_dynamic.dylib
[ -f "$TSANLIB" ] || TSANLIB=$(ls /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/*/lib/darwin/libclang_rt.tsan_osx_dynamic.dylib | head -1)
if [ "${TSAN:-0}" = 1 ]; then export DYLD_INSERT_LIBRARIES=$TSANLIB; fi
cd /Users/admin/Documents/ZTronAssetKit/.worktrees/s3c
$H --test-bundle-path $B $B --testing-library swift-testing "$@" > $LOG 2>&1 &
PID=$!
if [ "$WD" -gt 0 ]; then
  ( sleep $WD; if kill -0 $PID 2>/dev/null; then echo "WATCHDOG: still running after ${WD}s, killing $PID" >> $LOG; kill $PID; fi ) &
  W=$!
fi
wait $PID; RC=$?
[ -n "$W" ] && kill $W 2>/dev/null
echo "exit $RC"
