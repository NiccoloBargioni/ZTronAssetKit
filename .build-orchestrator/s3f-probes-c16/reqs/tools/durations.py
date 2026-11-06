#!/usr/bin/env python3
"""Scratch: each reported test's duration against its .timeLimit guard (Sync bundle)."""
import glob, re, sys
root = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/Tests/ZTronAssetSyncTests'
guards = {}
for f in glob.glob(root + '/**/*.swift', recursive=True):
    for m in re.finditer(r'@Test\("((?:[^"\\]|\\.)*)"([^\n]*)', open(f).read()):
        name, rest = m.group(1).replace('\\"', '"'), m.group(2)
        g = re.search(r'\.timeLimit\(\.minutes\((\d+)\)\)', rest)
        guards[name] = int(g.group(1)) * 60 if g else None
log = open(sys.argv[1]).read()
rows = []
for m in re.finditer(r'^✔ Test "((?:[^"\\]|\\.)*)"(?: with \d+ test cases?)? passed after ([0-9.]+) seconds', log, re.M):
    name, d = m.group(1), float(m.group(2))
    g = guards.get(name)
    if g:
        rows.append((d / g, d, g, name))
rows.sort(reverse=True)
print(f'tests with a guard: {len(rows)}; over half: {sum(1 for r in rows if r[0] > 0.5)}')
for r in rows[:6]:
    print(f'{r[0]*100:5.1f}%  {r[1]:7.2f} s of {r[2]} s  {r[3][:110]}')
