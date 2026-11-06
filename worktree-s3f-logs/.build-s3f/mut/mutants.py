#!/usr/bin/env python3
"""Cycle-11 mutants: applied in place on the committed tree, rebuilt in .build-s3f, run twice, reverted."""
import os, subprocess, sys, pathlib
WT = pathlib.Path("/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f")
E = "Sources/ZTronAssetSync/Engine/"
MUTANTS = {
    "noCarry": ([(E + "EngineFollow.swift",
                  "            self.state.followOrder = Array(owed)\n            self.state.followCarried.formUnion(others)\n",
                  "            self.state.followOrder = Array(owed) + others\n", 1)],
                "barrierCarriesUnfollowedJobsBehindAnOwedPass"),
    "noReroute": ([(E + "EngineFollow.swift",
                    "        if join.listed, self.state.applied.entry(for: join.asset)",
                    "        if false, join.listed, self.state.applied.entry(for: join.asset)", 1)],
                  "barrierReroutesAJoinALaterApplyMoved"),
    "relaneNoDefer": ([(E + "EngineJobs.swift",
                        "                // (S3-R14 item 4).\n                return\n            }\n",
                        "                // (S3-R14 item 4).\n            }\n", 1)],
                      "EngineFollowBarrier"),
    "throttleAtNow": ([(E + "EngineFollow.swift",
                        "answeredAt: facts.at, answerEnd: end)",
                        "answeredAt: nil, answerEnd: nil)", 1)],
                      "EngineFollowBarrier"),
    "noFlagPump": ([(E + "EngineFollow.swift", "if moved || self.state.pumpWaitsForFollow {", "if moved {", 2)],
                   "barrierFillsAFreedSlotInTheFollowsLastTurn"),
    "noDispatchOwedFlag": ([(E + "EngineRuns.swift",
                             "|| !self.state.originOwed.isEmpty || self.state.pumpWaitsForFollow",
                             "|| !self.state.originOwed.isEmpty", 1)],
                           "barrierHoldsAPendingRunBehindTheOwedPump"),
}
ENV = dict(os.environ, TMPDIR=str(WT / ".build-s3f/tmp"), CLANG_MODULE_CACHE_PATH=str(WT / ".build-s3f/tmp/mc"),
           LLVM_PROFILE_FILE=str(WT / ".build-s3f/tmp/%p.profraw"))

def run(name, override_filter=None, runs=2):
    edits, flt = MUTANTS[name]
    flt = override_filter or flt
    originals = {}
    try:
        for rel, old, new, count in edits:
            path = WT / rel
            text = originals.setdefault(rel, path.read_text())
            current = path.read_text()
            assert current.count(old) == count, f"{name}: {rel} has {current.count(old)} of the target, expected {count}"
            path.write_text(current.replace(old, new))
        log = WT / f".build-s3f/mut/{name}-build.log"
        b = subprocess.run(["swift", "build", "--build-tests", "--scratch-path", ".build-s3f"], cwd=WT, env=ENV,
                           stdout=open(log, "w"), stderr=subprocess.STDOUT)
        print(f"MUTANT {name}: build exit {b.returncode}", flush=True)
        if b.returncode != 0:
            return
        for i in range(1, runs + 1):
            out = WT / f".build-s3f/mut/{name}-run{i}.log"
            r = subprocess.run(["timeout", "900", "swift", "test", "--skip-build", "--scratch-path", ".build-s3f", "--filter", flt],
                               cwd=WT, env=ENV, stdout=open(out, "w"), stderr=subprocess.STDOUT)
            lines = out.read_text().splitlines()
            summary = [l for l in lines if "Test run with" in l]
            failed = sorted({l.split(" recorded an issue")[0] for l in lines if l.startswith("✘ Test ") and "recorded an issue" in l})
            print(f"MUTANT {name} run {i}: exit {r.returncode} :: {summary[-1] if summary else 'no summary'}", flush=True)
            for f in failed[:6]:
                print(f"    {f[:230]}", flush=True)
    finally:
        for rel, text in originals.items():
            (WT / rel).write_text(text)
        d = subprocess.run(["git", "diff", "--stat", "Sources/"], cwd=WT, capture_output=True, text=True).stdout.strip()
        print(f"MUTANT {name}: reverted, git diff --stat Sources/ = '{d}'", flush=True)

if __name__ == "__main__":
    args = sys.argv[1:]
    flt = None
    if args and args[0].startswith("--filter="):
        flt = args[0].split("=", 1)[1]
        args = args[1:]
    for n in args:
        run(n, flt)
