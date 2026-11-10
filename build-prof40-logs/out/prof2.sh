#!/bin/bash
# usage: prof.sh <tag> <filter> <template> <runs>
P=/Users/admin/Documents/ZTronAssetKit/.build-prof40
H=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper
B=$P/spm/release/ZTronAssetKitBenchmarks.xctest/Contents/MacOS/ZTronAssetKitBenchmarks
D=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer
export TMPDIR=$P/tmp
cd $P/out
tag=$1
echo "$tag start $(date +%T) $(sysctl -n vm.loadavg)" >> $P/out/loads.txt
rm -rf $P/out/$tag.trace
xcrun xctrace record --template "$3" --output $P/out/$tag.trace --no-prompt --time-limit ${5:-10m} --target-stdout $P/out/$tag.stdout \
  --env DYLD_FRAMEWORK_PATH=$D/Library/Frameworks:$D/Library/PrivateFrameworks --env DYLD_LIBRARY_PATH=$D/usr/lib --env PROF40_RUNS=$4 \
  --launch -- $H --test-bundle-path $B --testing-library swift-testing --filter "$2" > $P/out/$tag.log 2>&1
echo "$tag end rc=$? $(date +%T) $(sysctl -n vm.loadavg)" >> $P/out/loads.txt
