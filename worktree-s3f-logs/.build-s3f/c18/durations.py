import re, sys, glob
names = {}
for f in glob.glob('Tests/ZTronAssetSyncTests/**/*.swift', recursive=True):
    src = open(f).read()
    for m in re.finditer(r'@Test\(\s*"((?:[^"\\]|\\.)*)"(.*?)\)\s*\n\s*func', src, re.S):
        lim = re.search(r'\.timeLimit\(\.minutes\((\d+)\)\)', m.group(2))
        names[m.group(1)] = int(lim.group(1)) if lim else None
seen = {}
for line in open(sys.argv[1], errors='replace'):
    line = re.sub(r'\x1b\[[0-9;]*m', '', line)
    m = re.match(r'^✔ Test "(.*)" (?:with \d+ test cases )?passed after ([0-9.]+) seconds', line)
    if m:
        seen[m.group(1)] = float(m.group(2))
matched = {n: (d, names[n]) for n, d in seen.items() if names.get(n)}
print(f"reported {len(seen)} matched-with-guard {len(matched)}")
fr = sorted(((d / (g * 60), d, g, n) for n, (d, g) in matched.items()), reverse=True)
for r in fr[:5]:
    print(f"{r[0]*100:5.1f}% {r[1]:8.2f}s /{r[2]}m | {r[3][:110]}")
by = {}
for n, (d, g) in matched.items():
    by.setdefault(g, []).append((d, n))
for g in sorted(by):
    mx = max(by[g])
    print(f"guard {g}m: {len(by[g])} tests, max {mx[0]:.2f}s ({mx[0]/(g*60)*100:.1f}%) {mx[1][:90]}")
new = ['barrierReadmits', 'R-SYN-3: a re-admission turn during an owed follow', 'R-SYN-3: a backoff', 'R-SYN-3: an attempt cancelled by the transport during an owed follow', 'a deferred policy pause', 'an ended run']
try:
    newn = [l.rstrip('\n') for l in open('.build-s3f/c18/newtests.txt')]
    got = [(seen[n], names.get(n), n) for n in newn if n in seen]
    print(f"new tests reported {len(got)} of {len(newn)}")
    if got:
        mx = max(got)
        print(f"new tests max {mx[0]:.2f}s of {mx[1]}m ({mx[0]/(mx[1]*60)*100:.1f}%) {mx[2][:90]}")
except FileNotFoundError:
    pass
