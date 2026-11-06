# covdiff21b.py with the bundles' directory as argv[2] (the profile argv[1], the lines to print as file:line in
# argv[3:]): run on a copy of a run's bundles and profile (cycle 21, step 8).
import subprocess, re, os, sys, glob
W = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f"
S = W + "/.build-s3f"
diff = subprocess.run(["git", "-C", W, "diff", "-U0", "8e1fb24..HEAD", "--", "Sources"], capture_output=True, text=True).stdout
changed = {}
cur = None
for line in diff.splitlines():
    if line.startswith("+++ b/"):
        cur = line[6:]
        changed.setdefault(cur, set())
    m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
    if m and cur:
        start = int(m.group(1)); n = int(m.group(2) or 1)
        changed[cur].update(range(start, start + n))
bins = sorted(b for b in glob.glob(sys.argv[2] + "/*.xctest") if "Benchmarks" not in b)
objs = [b + "/Contents/MacOS/" + os.path.basename(b)[:-7] for b in bins]
args = ["xcrun", "llvm-cov", "show", "-instr-profile", sys.argv[1], objs[0]]
for o in objs[1:]:
    args += ["-object", o]
for f, lines in sorted(changed.items()):
    out = subprocess.run(args + ["-sources", W + "/" + f], capture_output=True, text=True).stdout
    zero = []
    for l in out.splitlines():
        m = re.match(r"\s*(\d+)\|\s*([0-9.kKM]+|)\|(.*)", l)
        if not m:
            continue
        n = int(m.group(1)); c = m.group(2)
        if c == "0" and n in lines:
            zero.append((n, m.group(3).strip()[:110]))
    for want in sys.argv[3:]:
        wf, wl = want.rsplit(":", 1)
        if f.endswith(wf):
            for l in out.splitlines():
                m = re.match(r"\s*(\d+)\|\s*([0-9.kKM]+|)\|(.*)", l)
                if m and int(m.group(1)) == int(wl):
                    print(f"COUNT {want}: {m.group(2) or '(none)'} | {m.group(3).strip()[:110]}")
    print(f"{f}: changed {len(lines)} lines, zero-count changed lines {len(zero)}")
    for n, t in zero:
        print(f"   {n}: {t}")
