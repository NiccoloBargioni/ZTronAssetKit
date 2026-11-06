import re, sys, glob
W = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f"
guards = {}
for f in glob.glob(W + "/Tests/ZTronAssetSyncTests/**/*.swift", recursive=True):
    text = open(f, errors="replace").read()
    for m in re.finditer(r'@Test\(\s*"((?:[^"\\]|\\.)*)"', text):
        name = m.group(1).replace('\\"', '"')
        tail = text[m.end():m.end() + 600]
        rest = tail.split("func ")[0]
        g = re.search(r'\.timeLimit\(\.minutes\((\d+)\)\)', rest)
        if g:
            guards[name] = int(g.group(1)) * 60.0
        else:
            # suite-level or no guard
            guards.setdefault(name, None)
log = open(sys.argv[1], errors="replace").read()
rows = []
unmatched = []
for m in re.finditer(r'[✔✘] Test "((?:[^"\\]|\\.)*)"(?: with \d+ test cases)? (passed|failed) after ([0-9.]+) seconds', log):
    name, status, t = m.group(1), m.group(2), float(m.group(3))
    g = guards.get(name)
    if g is None:
        unmatched.append((t, name))
        continue
    rows.append((t / g, t, g, status, name))
rows.sort(reverse=True)
print(f"matched {len(rows)}, unmatched {len(unmatched)} (max {max([u[0] for u in unmatched], default=0):.2f} s); over half: {sum(1 for r in rows if r[0] > 0.5)}; failed: {sum(1 for r in rows if r[3] != 'passed')}")
for r in rows[:4]:
    print(f"  {r[0] * 100:.1f} % {r[1]:.2f} s of {r[2]:.0f} s {r[3]}: {r[4][:110]}")
