import subprocess, re, os, sys, glob
W = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f"
S = W + "/.build-verify-s3f-c20-correct"
diff = subprocess.run(["git", "-C", W, "diff", "-U0", "49a0493..HEAD", "--", "Sources"], capture_output=True, text=True).stdout
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
bins = sorted(glob.glob(S + "/out/Products/Debug/*.xctest"))
objs = [b + "/Contents/MacOS/" + os.path.basename(b)[:-7] for b in bins]
prof = S + "/out/Products/Debug/codecov/default.profdata"
args = ["xcrun", "llvm-cov", "show", "-instr-profile", prof, objs[0]]
for o in objs[1:]:
    args += ["-object", o]
extra = [(f, set(int(x) for x in rng.split(","))) for f, rng in (a.split(":") for a in sys.argv[1:])]
for f, lines in sorted(changed.items()) + extra:
    out = subprocess.run(args + ["-sources", W + "/" + f], capture_output=True, text=True).stdout
    zero = []
    seen = {}
    for l in out.splitlines():
        m = re.match(r"\s*(\d+)\|\s*([0-9.kKM]+|)\|(.*)", l)
        if not m:
            continue
        n = int(m.group(1)); c = m.group(2)
        if n in lines:
            seen[n] = c
        if c == "0" and n in lines:
            zero.append((n, m.group(3).strip()[:110]))
    print(f"{f}: lines {len(lines)}, zero-count {len(zero)}")
    for n, t in zero:
        print(f"   {n}: {t}")
    if (f, lines) in extra:
        print("   counts:", sorted(seen.items()))
