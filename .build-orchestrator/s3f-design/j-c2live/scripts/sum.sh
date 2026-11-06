#!/bin/bash
# usage: sum.sh <round>
cd /Users/admin/Documents/ZTronAssetKit/.build-orchestrator/s3f-design/j-c2live/logs
for f in c2-$1-*.log; do
  echo "== ${f%.log} | $(grep -h 'load' $f.load 2>/dev/null | sed 's/load //' | tr '\n' ' ')"
  grep -h "VERIFY-C8-C2-MIXED 10,000\|R-SYN-11 reclaim during\|VERIFY-J-C2 10,000\|VERIFY-J-PILEUP 10,000\|PILEUP-LATENCY 10000\|incomplete\|Time limit" $f | sed 's/ms (budgets.*best); runs/runs/' | cut -c1-230
done
