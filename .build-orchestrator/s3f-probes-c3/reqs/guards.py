import re, sys, pathlib
log = pathlib.Path(sys.argv[1]).read_text(errors="replace")
src = {p: p.read_text() for p in pathlib.Path("Tests/ZTronAssetSyncTests").rglob("*.swift")}
rows = []
for m in re.finditer(r'Test "(.*?)" (?:with \d+ test cases? )?(passed|failed) after ([0-9.]+) seconds', log):
    name, status, d = m.group(1), m.group(2), float(m.group(3))
    if d < 20: continue
    lim = None; where = ""
    for p, t in src.items():
        i = t.find('@Test("' + name + '"')
        if i >= 0:
            line = t[i:t.find("\n", i)]
            mm = re.search(r'timeLimit\(\.minutes\((\d+)\)\)', line)
            lim = int(mm.group(1)) * 60 if mm else None
            where = f"{p.name}:{t[:i].count(chr(10)) + 1}"
            break
    rows.append((d, lim, status, where, name[:95]))
for d, lim, st, where, name in sorted(rows, reverse=True):
    pct = f"{100*d/lim:.0f}%" if lim else "?"
    print(f"{d:8.2f}s / {lim}s {pct:>5} {st:6} {where:45} {name}")
