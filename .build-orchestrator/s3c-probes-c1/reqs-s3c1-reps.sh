#!/bin/bash
# S3C-1 evidence at HEAD: TSan 20 repetitions, 50 fresh TSan launches of phaseFourStopsListing, debug 200 repetitions.
V=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3c/.build-verify-s3c-c1-reqs
R=$V/probe/run-direct.sh
O=$V/reps; mkdir -p $O
F='ZTronAssetStorageTests\.(PollReleaseTests|EvictionTests|EvictionOverlapTests|GarbageCollectionTests|HolderScanTests|IdempotencyTests|IntegrityTests|LeaseTests|LegacyEdgeTests|LegacyMigrationTests|LegacyOnDemandRaceTests|PurgeTests|LargeBlobTests)/'
S=$O/summary.txt; : > $S
echo "loopback-tsan $(date +%T) $(uptime | sed 's/.*load/load/')" >> $S
TSAN=1 bash $R ${V}-tsan ZTronAssetStorageTests $O/loopback-tsan.log 600 --filter 'LoopbackHTTPServerTests' >> $S
grep -E 'Test run with' $O/loopback-tsan.log >> $S
echo "tsan20 $(date +%T) $(uptime | sed 's/.*load/load/')" >> $S
TSAN=1 bash $R ${V}-tsan ZTronAssetStorageTests $O/tsan20.log 1800 --filter "$F" --repetitions 20 >> $S
grep -E 'Test run with' $O/tsan20.log | tail -1 >> $S; echo "x=$(grep -c '✘' $O/tsan20.log) tsan=$(grep -c ThreadSanitizer $O/tsan20.log) reps=$(grep -c 'repetition' $O/tsan20.log)" >> $S
echo "fresh50 $(date +%T) $(uptime | sed 's/.*load/load/')" >> $S
for i in $(seq 1 50); do TSAN=1 bash $R ${V}-tsan ZTronAssetStorageTests $O/fresh-$i.log 300 --filter 'ZTronAssetStorageTests\.LegacyEdgeTests/phaseFourStopsListing' >> $O/fresh-exits.txt; done
echo "exits0=$(grep -c 'exit 0' $O/fresh-exits.txt) passes=$(cat $O/fresh-*.log | grep -c '✔ Test "R-STO-11: phase 4 stops listing') x=$(cat $O/fresh-*.log | grep -c '✘') tsan=$(cat $O/fresh-*.log | grep -c ThreadSanitizer)" >> $S
echo "debug200 $(date +%T) $(uptime | sed 's/.*load/load/')" >> $S
bash $R $V ZTronAssetStorageTests $O/debug200.log 3600 --filter "$F" --repetitions 200 >> $S
grep -E 'Test run with' $O/debug200.log | tail -1 >> $S; echo "x=$(grep -c '✘' $O/debug200.log)" >> $S
echo "DONE $(date +%T) $(uptime | sed 's/.*load/load/')" >> $S
