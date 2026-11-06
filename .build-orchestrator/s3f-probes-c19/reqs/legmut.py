#!/usr/bin/env python3
"""Scratch: the checksum-less lookups' drop-mutants against PROBE-C19R-LEGACY-TARGET (probe copy only), 2 runs each."""
import os, subprocess, datetime
W = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f"
S = W + "/.build-verify-s3f-c19-reqs"
SRC = S + "/probesrc"
LOGS = S + "/logs/legmut"
ENV = dict(os.environ, TMPDIR=S + "/tmp", CLANG_MODULE_CACHE_PATH=S + "/tmp/modcache", LLVM_PROFILE_FILE=S + "/tmp/prof-%p.profraw")
F = SRC + "/Sources/ZTronAssetSync/Engine/EngineFollow.swift"
MUTANTS = {
    "byIdentifierTargetDrop": ("                byIdentifier[target.entry.identifier] = index\n", "                _ = index\n"),
    "byIdentifierLookupDrop": ("                    index = byIdentifier[asset].flatMap { SyncEngine.sameTransfer(listed, targets[$0].entry) ? $0 : nil }\n", "                    index = nil\n"),
}
def load():
    return subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip()
def log(m):
    line = f"{datetime.datetime.now():%H:%M:%S} {m}"
    print(line, flush=True)
    open(LOGS + "/summary.txt", "a").write(line + "\n")
for name, (old, new) in MUTANTS.items():
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
            r = subprocess.run(["swift", "test", "--skip-build", "--scratch-path", S + "/probebuild", "--filter", "VerifyC19ReqsLegacy"], cwd=SRC, env=ENV, capture_output=True, text=True, timeout=900)
            out = r.stdout + r.stderr
            open(f"{LOGS}/{name}-run{i}.log", "w").write(out)
            log(f"{name}: run{i} exit {r.returncode} load {load()}")
            for line in out.splitlines():
                if "recorded an issue" in line or "Test run with" in line or "moves owed after" in line or "followUpsFirst true:" in line or "followUpsFirst false:" in line:
                    log("    " + line[:300])
    finally:
        open(F, "w").write(text)
        d = subprocess.run(["diff", "-rq", SRC + "/Sources", W + "/Sources"], capture_output=True, text=True).stdout.strip()
        log(f"{name}: reverted; sources diff: {d or 'none'}")
# Rebuild the clean copy so later probe runs use unmutated sources.
b = subprocess.run(["swift", "build", "--build-tests", "--scratch-path", S + "/probebuild"], cwd=SRC, env=ENV, capture_output=True, text=True)
log(f"clean rebuild exit {b.returncode}")
