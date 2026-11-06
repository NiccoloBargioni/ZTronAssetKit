#!/usr/bin/env python3
"""Zero-count changed lines of Sources between BASE and HEAD, from a profile and the .xctest bundles of a products dir.
Usage: covdiff21.py BASE PROFDATA PRODUCTS_DIR [FILE:LINE ...]  (extra FILE:LINE args print those lines' counts)."""
import subprocess, re, os, sys, glob
W = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f"
base, prof, products = sys.argv[1], sys.argv[2], sys.argv[3]
probes = sys.argv[4:]
bins = [b + "/Contents/MacOS/" + os.path.basename(b)[:-7] for b in sorted(glob.glob(products + "/*.xctest"))]
bins = [b for b in bins if os.path.exists(b)]
diff = subprocess.run(["git", "-C", W, "diff", "-U0", base + "..HEAD", "--", "Sources"], capture_output=True, text=True).stdout
changed = {}
cur = None
for line in diff.splitlines():
    if line.startswith("+++ b/"):
        cur = line[6:]
        changed.setdefault(cur, set())
    m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
    if m and cur:
        start = int(m.group(1)); n = int(m.group(2) if m.group(2) is not None else 1)
        changed[cur].update(range(start, start + n))
args = ["xcrun", "llvm-cov", "show", "-instr-profile", prof, bins[0]]
for o in bins[1:]:
    args += ["-object", o]
want = {}
for p in probes:
    f, l = p.rsplit(":", 1)
    want.setdefault(f, set()).add(int(l))
files = sorted(set(changed) | set(want))
total_zero = 0
for f in files:
    lines = changed.get(f, set())
    out = subprocess.run(args + ["-sources", W + "/" + f], capture_output=True, text=True).stdout
    zero, executable, shown = [], 0, []
    for l in out.splitlines():
        m = re.match(r"\s*(\d+)\|\s*([0-9.kKMG]+|)\|(.*)", l)
        if not m:
            continue
        n = int(m.group(1)); c = m.group(2)
        if n in lines and c != "":
            executable += 1
        if c == "0" and n in lines:
            zero.append((n, m.group(3).strip()[:110]))
        if n in want.get(f, set()):
            shown.append((n, c, m.group(3).strip()[:110]))
    total_zero += len(zero)
    if lines:
        print(f"{f}: changed {len(lines)} lines ({executable} executable), zero-count changed lines {len(zero)}")
        for n, t in zero:
            print(f"   {n}: {t}")
    for n, c, t in shown:
        print(f"   PROBE {f}:{n} count '{c}': {t}")
print(f"TOTAL zero-count changed lines {total_zero} over {len(bins)} bundles")
