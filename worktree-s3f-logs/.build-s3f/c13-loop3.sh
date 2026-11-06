#!/bin/bash
# finding 1/13: the formerly hanging test, 30 runs, 6 at a time, on the built tree (no build), with the 1-minute load sampled
WT=/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f
cd $WT
export TMPDIR=$WT/.build-s3f/tmp CLANG_MODULE_CACHE_PATH=$WT/.build-s3f/tmp/mc LLVM_PROFILE_FILE=$WT/.build-s3f/tmp/%p.profraw
L=$WT/.build-s3f/c13/loop; rm -rf $L; mkdir -p $L
S=$L/samples; : > $S
( while true; do echo "$(date +%s) $(date +%H:%M:%S) $(sysctl -n vm.loadavg)" >> $S; sleep 5; done ) &
SP=$!
echo "== loop HEAD $(git rev-parse --short HEAD) $(date +%T) $(sysctl -n vm.loadavg)"
seq 1 30 | xargs -P 6 -n 1 bash $WT/.build-s3f/c13/loop-one-nolock.sh
kill $SP
echo "== loop done $(date +%T)"
sort -n -k2 $L/exits | awk '{print $4}' | sort | uniq -c
grep -h 'Test run with' $L/run-*.log | sed 's/after [0-9.]* seconds//' | sort | uniq -c
grep -l 'Time limit\|recorded an issue' $L/run-*.log | head
grep -h 'waiting for lock\|Another instance' $L/run-*.log | head -2
python3 - <<PY
vals=[float(l.split()[3]) for l in open("$S") if l.strip()]
print(f"loop load: mean {sum(vals)/len(vals):.2f} min {min(vals):.2f} max {max(vals):.2f} over {len(vals)} samples" if vals else "no samples")
PY
