import json, re, sys, pathlib, datetime
# usage: windows.py <tests dir> <load.log> <events.jsonl>... ; per-test duration vs guard and the 1-min load over its window
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
        mm = re.search(r'\.timeLimit\(\.minutes\((\d+)\)\)', decl)
        guards[nm.group(1).replace('\\"', '"')] = int(mm.group(1)) if mm else None
load = []
for l in open(sys.argv[2]):
    t, rest = l.split(" ", 1)
    load.append((t, float(rest.split()[1])))
def window(a, b):
    ta = datetime.datetime.fromtimestamp(a).strftime("%H:%M:%S"); tb = datetime.datetime.fromtimestamp(b).strftime("%H:%M:%S")
    v = [x for t, x in load if ta <= t <= tb]
    return ta, tb, v
rows = []
for path in sys.argv[3:]:
    names = {}; start = {}; end = {}
    for l in open(path):
        e = json.loads(l)
        p = e["payload"]
        if e["kind"] == "test" and p.get("kind") == "function":
            names[p["id"]] = p["displayName"]
        elif e["kind"] == "event":
            k = p["kind"]; tid = p.get("testID")
            if k == "testStarted" and tid in names:
                start[tid] = p["instant"]["since1970"]
            elif k in ("testEnded", "testSkipped") and tid in names:
                end[tid] = p["instant"]["since1970"]
    for tid, s in start.items():
        if tid not in end: continue
        name = names[tid]; g = guards.get(name)
        if not g: continue
        d = end[tid] - s
        ta, tb, v = window(s, end[tid])
        rows.append((d / (g * 60), d, g, ta, tb, (min(v) if v else -1), (max(v) if v else -1), (sum(v)/len(v) if v else -1), (sum(1 for x in v if x > 30) / len(v) if v else -1), pathlib.Path(path).name, name))
rows.sort(reverse=True)
print("over half:", sum(1 for r in rows if r[0] > 0.5), "of", len(rows))
for r in rows[:int(sys.argv[0] and 14)]:
    print(f"{r[0]*100:5.1f}% {r[1]:7.2f}s /{r[2]}min {r[3]}-{r[4]} load {r[5]:.1f}-{r[6]:.1f} mean {r[7]:.1f} >30 {r[8]*100:.0f}% {r[9]}: {r[10][:95]}")
