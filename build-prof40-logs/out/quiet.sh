#!/bin/bash
P=/Users/admin/Documents/ZTronAssetKit/.build-prof40
start=$(date +%s)
echo "quiet-wait start $(date +%T) $(sysctl -n vm.loadavg)" >> $P/out/loads.txt
while true; do
  l=$(sysctl -n vm.loadavg | awk '{print $2}')
  if awk "BEGIN{exit !($l <= 9.0)}"; then break; fi
  if [ $(( $(date +%s) - start )) -gt 780 ]; then echo "quiet-wait gave up $(date +%T) $(sysctl -n vm.loadavg)" >> $P/out/loads.txt; break; fi
  sleep 10
done
echo "quiet-wait end $(date +%T) $(sysctl -n vm.loadavg)" >> $P/out/loads.txt
bash $P/out/baseline.sh base2
H=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper
B=$P/spm/release/ZTronAssetKitBenchmarks.xctest/Contents/MacOS/ZTronAssetKitBenchmarks
D=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer
for i in 1 2 3; do
  echo "micro2-$i start $(date +%T) $(sysctl -n vm.loadavg)" >> $P/out/loads.txt
  DYLD_FRAMEWORK_PATH=$D/Library/Frameworks:$D/Library/PrivateFrameworks DYLD_LIBRARY_PATH=$D/usr/lib $H --test-bundle-path $B --testing-library swift-testing --filter "Prof40Shapes/micro" > $P/out/micro2-$i.log 2>&1
  echo "micro2-$i end $(date +%T) $(sysctl -n vm.loadavg)" >> $P/out/loads.txt
done
