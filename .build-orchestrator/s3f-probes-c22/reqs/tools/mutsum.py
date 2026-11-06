# Summarises each mutant run log: the run line, failing tests with their argument cases and first issue lines, time limits.
import glob, os, re, sys
LOGS = '/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c22-reqs/mut/logs'
names = sys.argv[1:]
for log in sorted(glob.glob(LOGS + '/*-run[12].log')):
    name = os.path.basename(log)[:-len('-run1.log')]
    if names and name not in names:
        continue
    text = open(log, errors='replace').read()
    run = re.findall(r'Test run with .*', text)
    fails = re.findall(r'✘ Test "([^"]+)" (?:recorded an issue(?: with \d+ arguments? (.*?))? at ([A-Za-z0-9_]+\.swift:\d+):\d+: (.{0,90}))', text)
    limits = re.findall(r'Time limit was exceeded', text)
    passed = len(re.findall(r'✔ Test "', text))
    print(f'== {os.path.basename(log)}: {run[-1] if run else "NO RUN LINE"} | passed-tests {passed} | time-limit issues {len(limits)}')
    seen = set()
    for (test, args, where, what) in fails:
        key = (test[:60], args, where)
        if key in seen:
            continue
        seen.add(key)
        print(f'   {where} [{args or "-"}] {what.strip()[:80]}')
