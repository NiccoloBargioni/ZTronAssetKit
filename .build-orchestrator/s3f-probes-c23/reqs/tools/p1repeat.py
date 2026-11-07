# p1-rule-false applied once, then the three e1-P1 tests run 6 more times, to see whether e1-P1's other side
# (userJoinFromInsideAnENOSPCsReadSkipsItsVerdict, :182) fails, passes or hits its time limit under the mutant.
import os, subprocess, sys, re
sys.argv = ['x', 'mutants']
src = open('/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c23-reqs/tools/mutc23.py').read().split('\ndef main')[0]
ns = {}
exec(src, ns)
name, path, old, new, flt = [m for m in ns['M'] if m[0] == 'p1-rule-false'][0]
p = os.path.join(ns['SRC'], path)
text = open(p).read()
assert text.count(old) == 1
open(p, 'w').write(text.replace(old, new))
try:
    ok, secs = ns['build']('p1rep')
    print('build', ok, int(secs), flush=True)
    for r in range(3, 9):
        s, bo, tl, n = ns['run'](f'p1-rule-false-rep{r}', flt, timeout=900)
        print(f'rep{r}: {s} | issues {n} tl {tl} | load {ns["loads"]()}', flush=True)
finally:
    open(p, 'w').write(text)
print('reverted', open(p).read() == text)
