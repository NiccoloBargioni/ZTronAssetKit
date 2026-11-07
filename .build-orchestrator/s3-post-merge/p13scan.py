import re, sys, math, os
files = sys.argv[1:]
ansi = re.compile(r'\x1b\[[0-9;]*m')
pat = re.compile(r'P-13 reclaim of (\d+) blobs: ([0-9.]+) s in (\d+) units, (?:unit p99 ([0-9.]+) ms, max|unit max) ([0-9.]+) ms \(p50 ([0-9.]+) ms, p95 ([0-9.]+) ms\).*?units over the batch budget: \[(.*?)\]')
seen = set()
for f in files:
    try:
        raw = open(f, 'rb').read().decode('utf-8', 'replace')
    except Exception as e:
        print("ERR", f, e); continue
    text = ansi.sub('', raw).replace('\\"', '"')
    for m in pat.finditer(text):
        blobs, total, n, p99, mx, p50, p95, over = m.groups()
        n = int(n)
        overs = re.findall(r'([0-9.]+) ms wall', over)
        k = len(overs)
        tol = n - math.ceil(0.99 * n)
        key = (total, n, mx)
        dup = key in seen
        seen.add(key)
        verdict = "p99-PASS" if k <= tol else "p99-FAIL"
        print(f"{os.path.relpath(f)} | total {total} s | n {n} | p99 {p99 or '-'} | max {mx} | p50 {p50} p95 {p95} | over5 {k} | tol {tol} | {verdict}{' (dup)' if dup else ''}")
