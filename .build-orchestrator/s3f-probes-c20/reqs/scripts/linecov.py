import subprocess, re, sys
W = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f"
import glob, os
prof = sys.argv[1]; src = sys.argv[2]; rng = sys.argv[3]; bins = [b + '/Contents/MacOS/' + os.path.basename(b)[:-7] for b in sorted(glob.glob(sys.argv[4] + '/*.xctest'))]
a, b = map(int, rng.split("-"))
args = ["xcrun", "llvm-cov", "show", "-instr-profile", prof, bins[0]]
for o in bins[1:]:
    args += ["-object", o]
out = subprocess.run(args + ["-sources", W + "/" + src], capture_output=True, text=True).stdout
for l in out.splitlines():
    m = re.match(r"\s*(\d+)\|\s*([0-9.kKMG]+|)\|(.*)", l)
    if m and a <= int(m.group(1)) <= b:
        print(f"{m.group(1):>5} {m.group(2):>8} | {m.group(3)[:120]}")
