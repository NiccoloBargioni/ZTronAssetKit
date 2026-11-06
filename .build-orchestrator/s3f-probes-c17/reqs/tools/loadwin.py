#!/usr/bin/env python3
"""Scratch (s3f cycle-17 verification, requirements lens; never committed): mean, min and max of the 1-minute load
samples in logs/load.log between two epoch seconds. Usage: loadwin.py <start> <end> [skip-seconds]."""
import sys
S = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c17-reqs'
start, end = int(sys.argv[1]), int(sys.argv[2])
skip = int(sys.argv[3]) if len(sys.argv) > 3 else 0
xs = []
for line in open(S + '/logs/load.log'):
    parts = line.split()
    if len(parts) >= 3 and parts[0].isdigit():
        t = int(parts[0])
        if start + skip <= t <= end:
            xs.append(float(parts[2]))
if xs:
    print(f'load mean {sum(xs)/len(xs):.2f} min {min(xs):.2f} max {max(xs):.2f} n={len(xs)}')
else:
    print('load: no samples')
