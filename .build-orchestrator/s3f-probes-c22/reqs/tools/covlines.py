# Zero-count changed lines in Sources since a base commit, from `llvm-cov show` text (the reqs verifier's own check).
# Usage: python3 covlines.py <base> <profdata> <bin> [<bin> ...]
import os, re, subprocess, sys
W = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f'
base, prof, bins = sys.argv[1], sys.argv[2], sys.argv[3:]
diff = subprocess.run(['git', '-C', W, 'diff', '-U0', base + '..HEAD', '--', 'Sources'], capture_output=True, text=True).stdout
changed = {}
cur = None
for line in diff.splitlines():
    if line.startswith('+++ '):
        cur = line[6:] if line.startswith('+++ b/') else None
    elif line.startswith('@@') and cur:
        m = re.match(r'@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@', line)
        start, count = int(m.group(1)), int(m.group(2) or '1')
        changed.setdefault(cur, set()).update(range(start, start + count))
objs = []
for b in bins[1:]:
    objs += ['-object', b]
total = zero = 0
for rel, lines in sorted(changed.items()):
    path = os.path.join(W, rel)
    out = subprocess.run(['xcrun', 'llvm-cov', 'show', '-instr-profile', prof, bins[0]] + objs + ['-sources', path], capture_output=True, text=True).stdout
    counts = {}
    for l in out.splitlines():
        m = re.match(r'\s*(\d+)\|\s*([0-9.]+[kMG]?|)\|', l)
        if m:
            counts[int(m.group(1))] = m.group(2)
    measured = [n for n in sorted(lines) if counts.get(n, '') != '']
    zeros = [n for n in measured if counts[n] == '0']
    total += len(measured)
    zero += len(zeros)
    print(f'{rel}: {len(measured)} executable changed lines, {len(zeros)} at zero: {zeros}')
print(f'TOTAL executable changed lines {total}, zero-count {zero}')
