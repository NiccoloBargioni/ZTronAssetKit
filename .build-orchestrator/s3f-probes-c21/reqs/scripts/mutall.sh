#!/bin/bash
# Lane D: the mutant runner's baseline, the c20 items' mutants 2/2, then two open survivors against the whole Sync suite once.
S=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c21-reqs
python3 $S/tools/mut21r.py baseline
python3 $S/tools/mut21r.py site1-never-owe site3-never-owe site2-never-owe drain-spend-guard-drop drain-spend-sub-drop a-orig-queue-insert a-drop-bucket-append i5-fold k4-drop idx-release-keeps-entry move-turn-bound-drop c12-never-owe c12-followup-unbounded r7-partial-trim-drop
RUNS=1 python3 $S/tools/mut21r.py f7-delisted-stays b23-no-kind
echo "mutall done $(date +%H:%M:%S)" >> $S/logs/mut/summary.txt
