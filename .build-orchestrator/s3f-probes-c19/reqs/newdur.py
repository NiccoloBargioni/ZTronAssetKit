import re, sys
S = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c19-reqs"
names = [l.strip() for l in open(S + "/newtests.txt") if l.strip()]
for log in sys.argv[1:]:
    text = open(log, errors="replace").read()
    worst = (0.0, "")
    missing = []
    fails = []
    for n in names:
        m = re.search(r'([✔✘]) Test "' + re.escape(n) + r'"(?: with \d+ test cases)? (passed|failed) after ([0-9.]+) seconds', text)
        if not m:
            missing.append(n)
            continue
        if m.group(2) != "passed":
            fails.append(n)
        t = float(m.group(3))
        if t > worst[0]:
            worst = (t, n)
    total = re.findall(r'Test run with (\d+) tests? in (\d+) suites? (passed|failed) after ([0-9.]+) seconds', text)
    print(f"{log.split('/')[-1]}: run {total[-1] if total else 'none'}; new tests reported {len(names) - len(missing)}/{len(names)}, failed {len(fails)}; longest {worst[0]:.3f} s ({worst[0] / 180 * 100:.1f} % of 3 min): {worst[1][:90]}")
    for n in missing:
        print("   missing:", n[:100])
