#!/usr/bin/env python3
"""run.py <mutant|base> <filter-regex> [timeout-seconds]: applies the mutant, builds, runs the filtered Sync tests, prints a summary."""
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE / "src"
LOGS = HERE / "logs"
LOGS.mkdir(exist_ok=True)

name, flt = sys.argv[1], sys.argv[2]
limit = int(sys.argv[3]) if len(sys.argv) > 3 else 400
env = dict(os.environ)
tmp = HERE.parent / "tmp"
env["TMPDIR"] = str(tmp)
env["CLANG_MODULE_CACHE_PATH"] = str(tmp / "mc")

subprocess.run([sys.executable, "-I", str(HERE / "mutate.py"), "revert" if name == "base" else name], check=True)
log = LOGS / f"{name}-{int(time.time())}.log"
with open(log, "w") as out:
    b = subprocess.run(["swift", "build", "--build-tests", "--scratch-path", "../build"], cwd=SRC, env=env, stdout=out, stderr=subprocess.STDOUT)
if b.returncode != 0:
    print(f"{name}: BUILD FAILED, see {log}")
    print("".join(l for l in open(log) if "error:" in l)[:2000])
    subprocess.run([sys.executable, "-I", str(HERE / "mutate.py"), "revert"], check=True)
    sys.exit(1)
start = time.time()
with open(log, "a") as out:
    p = subprocess.Popen(["swift", "test", "--skip-build", "--scratch-path", "../build", "--filter", flt], cwd=SRC, env=env,
                         stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        rc = p.wait(timeout=limit)
        hung = False
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
        rc = "killed"
        hung = True
elapsed = time.time() - start
subprocess.run([sys.executable, "-I", str(HERE / "mutate.py"), "revert"], check=True)
lines = open(log, errors="replace").read().splitlines()
keep = [l for l in lines if re.search(r"Expectation failed|Time limit|failed after|passed after|Test run with|recorded an issue|Issue|error:", l)
        and "started" not in l]
print(f"== {name} filter={flt} rc={rc} hung={hung} elapsed={elapsed:.1f}s log={log.name}")
seen = set()
for l in keep:
    s = re.sub(r"^.*?(Tests/ZTronAssetSyncTests/)", r"\1", l)[:330]
    if s not in seen:
        seen.add(s)
        print("  " + s)
