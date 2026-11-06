#!/usr/bin/env python3
"""S3G-1 original defect (s3-base's unclamped walk) against the release P-8 benchmark, in the scratch copy.

Usage: o1_release.py build | run. `build` applies the mutant and builds the release tests; `run` runs the benchmark with
a wall-clock limit in its own process group (killed as a group on timeout), prints the issue lines, restores the file.
"""
import os
import pathlib
import signal
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import reqs_run as base  # noqa: E402

PKG, LOGS = base.PKG, base.LOGS
BUILD = base.HERE / "build-release"
FILE = PKG / base.PREFETCH


def apply():
    text = FILE.read_text()
    if base.OLD_WALK in text:
        return
    assert text.count(base.NEW_WALK) == 1
    FILE.write_text(text.replace(base.NEW_WALK, base.OLD_WALK))


def restore():
    text = FILE.read_text()
    if base.OLD_WALK in text:
        FILE.write_text(text.replace(base.OLD_WALK, base.NEW_WALK))


def main():
    mode = sys.argv[1]
    if mode == "build":
        apply()
        code = base.run(["swift", "build", "-c", "release", "--build-tests", "--scratch-path", str(BUILD),
                         "-Xswiftc", "-enable-testing"], LOGS / "O1-release-build.log", 3600)
        print(f"== O1 release build exit {code}")
        return
    log = LOGS / "O1-release-test.log"
    start = time.time()
    with open(log, "w") as out:
        out.write(f"load {os.getloadavg()}\n")
        out.flush()
        proc = subprocess.Popen(["swift", "test", "-c", "release", "--skip-build", "--scratch-path", str(BUILD),
                                 "-Xswiftc", "-enable-testing", "--filter", "prefetchWindowHugeRadius"],
                                cwd=PKG, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = proc.wait(timeout=int(sys.argv[2]) if len(sys.argv) > 2 else 240)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            code = "TIMEOUT (process group killed)"
        out.write(f"\n== exit {code} after {time.time() - start:.1f} s, load {os.getloadavg()}\n")
    restore()
    print(f"== O1 release test exit {code}")
    print("\n".join(base.summary(log)))
    for line in open(log, errors="replace"):
        if line.startswith("P-8 prefetch window"):
            print(line.rstrip()[:300])


if __name__ == "__main__":
    main()
