# Re-parses the mutant run logs: per log, the summary line, issue count, time-limit issues, and the failing
# file:line per LaneDropVisit order (regex on "at <File>.swift:<line>:<col>:").
import glob, os, re, sys

LOG = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c23-reqs/mut/logs'
pat = sys.argv[1] if len(sys.argv) > 1 else '*-run[12].log'
for path in sorted(glob.glob(os.path.join(LOG, pat))):
    name = os.path.basename(path)[:-4]
    if name.startswith('base-'):
        continue
    lines = open(path, errors='replace').read().splitlines()
    summ = [l.strip() for l in lines if 'Test run with' in l]
    issues = [l for l in lines if l.startswith('✘ Test') and 'recorded an issue' in l]
    by = {}
    tl = 0
    for l in issues:
        m = re.search(r'visit → \.(\w+)', l)
        order = m.group(1) if m else '-'
        if 'Time limit was exceeded' in l:
            tl += 1
            order += '(TIMELIMIT)'
        loc = re.search(r' at (\w+\.swift):(\d+):\d+:', l)
        by.setdefault(order, set()).add(f'{loc.group(1)}:{loc.group(2)}' if loc else '?')
    per = '; '.join(f'{o}: ' + ', '.join(sorted(s, key=lambda x: (x.split(":")[0], int(x.split(":")[1]) if x != "?" else 0))) for o, s in sorted(by.items()))
    print(f'{name}: {summ[-1] if summ else "NO SUMMARY"} | issues {len(issues)}, time-limit {tl} | {per}')
