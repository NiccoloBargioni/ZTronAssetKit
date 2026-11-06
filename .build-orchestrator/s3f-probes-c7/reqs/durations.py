import re, sys, pathlib
# usage: durations.py <tests dir> <log>... ; prints tests over half their guard (max over logs)
root = pathlib.Path(sys.argv[1])
guards = {}
for f in root.rglob("*.swift"):
    src = f.read_text()
    for m in re.finditer(r'@Test\(', src):
        i = m.end(); depth = 1; j = i
        while depth and j < len(src):
            c = src[j]
            if c == '"':
                j += 1
                while src[j] != '"':
                    j += 2 if src[j] == '\\' else 1
            elif c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
            j += 1
        decl = src[i:j-1]
        nm = re.match(r'\s*"((?:[^"\\]|\\.)*)"', decl)
        if not nm:
            continue
        name = nm.group(1).replace('\\"', '"')
        mm = re.search(r'\.timeLimit\(\.minutes\((\d+)\)\)', decl)
        guards[name] = (int(mm.group(1)) if mm else None, f.name)
rx = re.compile(r'Test "(.*)"(?: with \d+ test cases?)? (passed|failed) after ([\d.]+) seconds')
res = {}
for log in sys.argv[2:]:
    for line in pathlib.Path(log).read_text(errors="replace").splitlines():
        m = rx.search(line)
        if m:
            res.setdefault(m.group(1), []).append(float(m.group(3)))
rows = []
unk = 0
for name, ds in res.items():
    g = guards.get(name)
    if not g or g[0] is None:
        if not g: unk += 1
        continue
    lim = g[0] * 60
    rows.append((max(ds) / lim, max(ds), g[0], g[1], name, ds))
rows.sort(reverse=True)
print(f"tests timed={len(res)} unmatched={unk}")
over = [r for r in rows if r[0] > 0.5]
print(f"over half: {len(over)}")
for r in rows[:int(sys.argv[0] and 25)]:
    print(f"{r[0]*100:5.1f}% {r[1]:7.2f}s /{r[2]}min {r[3]}: {r[4][:110]} {r[5]}")
