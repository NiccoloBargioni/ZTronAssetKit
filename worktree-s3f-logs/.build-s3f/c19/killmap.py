import re, subprocess, sys
# Usage: killmap.py <name> <log> [<log> ...]: for each issue in the logs, the HEAD line of its assertion (found by the
# failed expression's text in HEAD's file), the cases, and which runs saw it. A time-limit issue maps to its @Test line.
W = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f'
name, logs = sys.argv[1], sys.argv[2:]
files = {}
def head(f):
    if f not in files:
        p = subprocess.run(['git', '-C', W, 'ls-files', f'*{f}'], capture_output=True, text=True).stdout.split()
        files[f] = (p[0], subprocess.run(['git', '-C', W, 'show', f'HEAD:{p[0]}'], capture_output=True, text=True).stdout.splitlines()) if p else (f, [])
    return files[f]
sites = {}
summ = []
for i, log in enumerate(logs, 1):
    text = re.sub(r'\x1b\[[0-9;]*m', '', open(log, errors='replace').read())
    s = [l for l in text.splitlines() if 'Test run with' in l]
    summ.append(s[-1].strip() if s else 'NO SUMMARY (' + log.split('/')[-1] + ')')
    for l in text.splitlines():
        if not (l.startswith('✘ Test') and 'recorded an issue' in l):
            continue
        m = re.search(r' at ([A-Za-z0-9]+\.swift):(\d+):\d+: (.*)$', l)
        if not m:
            continue
        f, line, rest = m.group(1), int(m.group(2)), m.group(3)
        t = re.match(r'✘ Test "([^"]+)"', l).group(1)
        args = re.search(r'with \d+ arguments? (.*?) at [A-Za-z0-9]+\.swift', l)
        case = args.group(1).replace('visit → ', '').replace('shape → ', '') if args else '-'
        path, lines = head(f)
        hl = None
        if rest.startswith('Time limit'):
            key = 'time limit'
            for n, x in enumerate(lines, 1):
                if '@Test("' + t[:60] in x:
                    hl = n
        else:
            expr = rest.split(': ', 1)[1] if ': ' in rest else rest
            key = expr[:70]
            # The test's body follows its @Test line; a helper's assertion (before it) is found when none follows.
            start = next((n for n, x in enumerate(lines, 1) if '@Test("' + t[:60] in x), 0)
            for n, x in list(enumerate(lines, 1))[start:] + list(enumerate(lines, 1))[:start]:
                if ('#expect(' + expr[:50]) in x or ('#require(' + expr[:50]) in x:
                    hl = n
                    break
        k = (f, hl, key)
        sites.setdefault(k, [set(), set()])
        sites[k][0].add(case)
        sites[k][1].add(i)
print(name)
for i, s in enumerate(summ, 1):
    print(f'  run{i}: {s}')
for (f, hl, key), (cases, runs) in sorted(sites.items(), key=lambda kv: (kv[0][0], kv[0][1] or 0)):
    print(f'  {f}:{hl} [{key}] runs {sorted(runs)} cases {sorted(cases)}')
