#!/usr/bin/env python3
"""Scratch: the per-turn budget drop-mutants against PROBE-C19R-TWO-HOLDER-TURN (probe copy only), 2 runs each."""
import os, subprocess, datetime, sys
W = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f"
S = W + "/.build-verify-s3f-c19-reqs"
SRC = S + "/probesrc"
LOGS = S + "/logs/turnmut"
os.makedirs(LOGS, exist_ok=True)
ENV = dict(os.environ, TMPDIR=S + "/tmp", CLANG_MODULE_CACHE_PATH=S + "/tmp/modcache", LLVM_PROFILE_FILE=S + "/tmp/prof-%p.profraw")
F = SRC + "/Sources/ZTronAssetSync/Engine/EngineFollow.swift"
MUTANTS = {
    "inboundSpentDrop": ("                budget.ids -= made.spent\n                moved = moved || made.moved\n", "                moved = moved || made.moved\n"),
    "restSpentDrop": ("        budget.ids -= made.spent\n        guard rest.moves.isDone else {\n", "        guard rest.moves.isDone else {\n"),
    "visitSpentDrop": ("            self.follow(transfer, ids: ids, afterVerdict: false)\n        }\n        budget.ids -= made.spent\n", "            self.follow(transfer, ids: ids, afterVerdict: false)\n        }\n"),
}
FILTER = sys.argv[1]
names = sys.argv[2:]
def load():
    return subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip()
def log(m):
    line = f"{datetime.datetime.now():%H:%M:%S} {m}"
    print(line, flush=True)
    open(LOGS + "/summary.txt", "a").write(line + "\n")
for name in names:
    old, new = MUTANTS[name]
    text = open(F).read()
    if text.count(old) != 1:
        log(f"{name}: SKIP count {text.count(old)}")
        continue
    open(F, "w").write(text.replace(old, new))
    try:
        b = subprocess.run(["swift", "build", "--build-tests", "--scratch-path", S + "/probebuild"], cwd=SRC, env=ENV, capture_output=True, text=True)
        open(f"{LOGS}/{name}-build.log", "w").write(b.stdout + b.stderr)
        log(f"{name}: build exit {b.returncode} load {load()}")
        if b.returncode != 0:
            continue
        for i in (1, 2):
            r = subprocess.run(["swift", "test", "--skip-build", "--scratch-path", S + "/probebuild", "--filter", FILTER], cwd=SRC, env=ENV, capture_output=True, text=True, timeout=900)
            out = r.stdout + r.stderr
            open(f"{LOGS}/{name}-{FILTER}-run{i}.log", "w").write(out)
            log(f"{name}: {FILTER} run{i} exit {r.returncode} load {load()}")
            for line in out.splitlines():
                if "recorded an issue" in line or "Test run with" in line or "PROBE-C19R-TWO-HOLDER-TURN sweep" in line or "PROBE-C19R-BYSTANDER" in line:
                    log("    " + line[:330])
    finally:
        open(F, "w").write(text)
        d = subprocess.run(["diff", "-rq", SRC + "/Sources", W + "/Sources"], capture_output=True, text=True).stdout.strip()
        log(f"{name}: reverted; sources diff: {d or 'none'}")
b = subprocess.run(["swift", "build", "--build-tests", "--scratch-path", S + "/probebuild"], cwd=SRC, env=ENV, capture_output=True, text=True)
log(f"clean rebuild exit {b.returncode}")
