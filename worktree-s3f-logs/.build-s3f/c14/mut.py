#!/usr/bin/env python3
"""Cycle-14 mutants: the worktree's Sources and Tests are synced into .build-s3f/mutsrc, each mutant applied there with a
count check, built in .build-s3f/mutbuild, its filter run twice, then reverted (the worktree is never edited)."""
import os, subprocess, sys, pathlib, json
WT = pathlib.Path("/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f")
SUFFIX = os.environ.get("MUT_SUFFIX", "")
SRC = WT / f".build-s3f/mutsrc{SUFFIX}"
BUILD = WT / f".build-s3f/mutbuild{SUFFIX}"
LOGS = WT / f".build-s3f/c14/mut{SUFFIX}"
E = "Sources/ZTronAssetSync/Engine/"
MUTANTS = json.loads((WT / ".build-s3f/c14/mutants.json").read_text())
ENV = dict(os.environ, TMPDIR=str(WT / ".build-s3f/tmp"), CLANG_MODULE_CACHE_PATH=str(WT / ".build-s3f/tmp/mc"),
           LLVM_PROFILE_FILE=str(WT / ".build-s3f/tmp/%p.profraw"))
LOGS.mkdir(parents=True, exist_ok=True)


def sync():
    SRC.mkdir(parents=True, exist_ok=True)
    for d in ["Sources", "Tests"]:
        subprocess.run(["rsync", "-a", "--delete", f"{WT}/{d}/", f"{SRC}/{d}/"], check=True)
    subprocess.run(["cp", f"{WT}/Package.swift", f"{SRC}/Package.swift"], check=True)


def run(name, runs=2):
    m = MUTANTS[name]
    edits, flt = m["edits"], os.environ.get("MUT_FILTER", m["filter"])
    originals = {}
    try:
        for rel, old, new, count in edits:
            path = SRC / rel
            current = path.read_text()
            originals.setdefault(rel, current)
            assert current.count(old) == count, f"{name}: {rel} has {current.count(old)} of the target, expected {count}"
            path.write_text(current.replace(old, new))
        log = LOGS / f"{name}-build.log"
        b = subprocess.run(["swift", "build", "--build-tests", "--scratch-path", str(BUILD)], cwd=SRC, env=ENV,
                           stdout=open(log, "w"), stderr=subprocess.STDOUT)
        print(f"MUTANT {name}: build exit {b.returncode}", flush=True)
        if b.returncode != 0:
            return
        for i in range(1, runs + 1):
            out = LOGS / f"{name}-run{i}.log"
            subprocess.run(["swift", "test", "--skip-build", "--scratch-path", str(BUILD), "--filter", flt],
                           cwd=SRC, env=ENV, stdout=open(out, "w"), stderr=subprocess.STDOUT)
            lines = out.read_text().splitlines()
            summary = [l for l in lines if "Test run with" in l]
            issues = [l for l in lines if "recorded an issue" in l]
            print(f"MUTANT {name} run {i}: {summary[-1][:160] if summary else 'no summary'}", flush=True)
            for l in issues[:4]:
                print(f"    {l[l.find('recorded'):][:260]}", flush=True)
    finally:
        for rel, text in originals.items():
            (SRC / rel).write_text(text)
        diff = subprocess.run(["diff", "-rq", f"{WT}/Sources", f"{SRC}/Sources"], capture_output=True, text=True).stdout
        print(f"MUTANT {name}: reverted; Sources differ from the worktree: {'none' if not diff.strip() else diff[:200]}", flush=True)


if __name__ == "__main__":
    sync()
    for n in sys.argv[1:]:
        run(n)
