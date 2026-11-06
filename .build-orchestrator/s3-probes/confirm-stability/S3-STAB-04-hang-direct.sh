#!/bin/bash
# Runs the hang probe's test bundle directly under a pty (so output is flushed as it happens) with a scoped watchdog.
S=/Users/admin/Documents/ZTronAssetKit/.build-s3-confirm-stability
export TMPDIR=$S/tmp
P=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer
export DYLD_FRAMEWORK_PATH=$P/Library/Frameworks DYLD_LIBRARY_PATH=$P/usr/lib
B=$S/hangprobe-build/debug/HangProbeTests.xctest/Contents/MacOS/HangProbeTests
[ -f "$B" ] || B=$(ls $S/hangprobe-build/debug/*.xctest/Contents/MacOS/* | head -1)
H=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper
LIMIT=${1:-120}
script -q $S/hangprobe-direct.log /usr/bin/env DYLD_FRAMEWORK_PATH=$DYLD_FRAMEWORK_PATH DYLD_LIBRARY_PATH=$DYLD_LIBRARY_PATH SWIFT_BACKTRACE=enable=no $H --test-bundle-path $B $B --testing-library swift-testing > /dev/null 2>&1 &
PID=$!
START=$(date +%s)
while kill -0 $PID 2>/dev/null; do
  if [ $(( $(date +%s) - START )) -ge $LIMIT ]; then
    echo "STILL RUNNING after ${LIMIT}s (script pid $PID)"
    for c in $(pgrep -P $PID); do ps -o pid=,etime=,command= -p $c | cut -c1-140; pkill -TERM -P $c; kill -TERM $c; done; kill -TERM $PID
    exit 2
  fi
  sleep 1
done
wait $PID; echo "exited $? after $(( $(date +%s) - START ))s"
