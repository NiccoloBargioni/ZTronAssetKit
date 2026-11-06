import subprocess, re, os, sys, glob
W = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f"
S = W + "/.build-verify-s3f-c20-reqs"
base = sys.argv[1]
prof = sys.argv[2]
import glob as _g
bins = [b + '/Contents/MacOS/' + os.path.basename(b)[:-7] for b in sorted(_g.glob(sys.argv[3] + '/*.xctest'))]
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
for f, lines in sorted(changed.items()):
    out = subprocess.run(args + ["-sources", W + "/" + f], capture_output=True, text=True).stdout
    zero = []
    executable = 0
    for l in out.splitlines():
        m = re.match(r"\s*(\d+)\|\s*([0-9.kKMG]+|)\|(.*)", l)
        if not m:
            continue
        n = int(m.group(1)); c = m.group(2)
        if n in lines and c != "":
            executable += 1
        if c == "0" and n in lines:
            zero.append((n, m.group(3).strip()[:110]))
    print(f"{f}: changed {len(lines)} lines ({executable} executable), zero-count changed lines {len(zero)}")
    for n, t in zero:
        print(f"   {n}: {t}")
