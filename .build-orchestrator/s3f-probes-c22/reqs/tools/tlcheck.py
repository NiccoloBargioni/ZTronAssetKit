# Lists @Test functions added since a base that are async but carry no .timeLimit (own or suite-level). Scratch only.
import re, subprocess, sys
W = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f'
base = sys.argv[1]
files = subprocess.run(['git', '-C', W, 'diff', '--name-only', base + '..HEAD', '--', 'Tests/ZTronAssetSyncTests'], capture_output=True, text=True).stdout.split()
added = {}
for f in files:
    d = subprocess.run(['git', '-C', W, 'diff', '-U0', base + '..HEAD', '--', f], capture_output=True, text=True).stdout
    lines = set()
    for h in re.finditer(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@', d, re.M):
        s, c = int(h.group(1)), int(h.group(2) or '1')
        lines.update(range(s, s + c))
    added[f] = lines
for f, lines in added.items():
    try:
        src = open(f'{W}/{f}').read().split('\n')
    except FileNotFoundError:
        continue
    suite_limit = any('@Suite' in l and 'timeLimit' in l for l in src)
    for i, l in enumerate(src):
        if '@Test' in l and (i + 1) in lines:
            j = i
            attr = ''
            while j < len(src) and not re.search(r'\bfunc\b', src[j]):
                attr += src[j]
                j += 1
            sig = src[j] if j < len(src) else ''
            if 'async' in sig and 'timeLimit' not in attr and not suite_limit:
                print(f'{f}:{i+1}: {sig.strip()[:110]}')
