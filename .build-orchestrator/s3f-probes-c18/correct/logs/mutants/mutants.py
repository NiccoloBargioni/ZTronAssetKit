#!/usr/bin/env python3
"""Re-applies the cycle-18 draft's mutants to the scratch probe copy, one at a time: build, run the killing test twice,
revert, and record. Only the scratch copy is touched; the worktree's Sources are the reference for the revert."""
import os
import re
import shutil
import subprocess
import sys
import time

S = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c18-correct"
WT = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f"
SRC = os.path.join(S, "probesrc")
LOG = os.path.join(S, "logs", "mutants")
os.makedirs(LOG, exist_ok=True)
ENV = dict(os.environ)
ENV.update({
    "TMPDIR": os.path.join(S, "tmp"),
    "CLANG_MODULE_CACHE_PATH": os.path.join(S, "tmp", "module-cache"),
    "LLVM_PROFILE_FILE": os.path.join(S, "tmp", "prof-%p.profraw"),
})

FOLLOW = "Sources/ZTronAssetSync/Engine/EngineFollow.swift"
FAILURES = "Sources/ZTronAssetSync/Engine/EngineFailures.swift"
CATCHUP = "Sources/ZTronAssetSync/Engine/EngineCatchUp.swift"

MUTANTS = [
    ("rerouteOnPassKeepWhole", FOLLOW,
     "movedBefore = job.rerouteOnPass?.intersection(away) ?? []",
     "movedBefore = job.rerouteOnPass ?? []",
     "barrierAnswersAnIDMovedBackAndAwayAgainWithThePublicationsOutcome"),
    ("vaStampDrop", FAILURES,
     "        guard let stamp else {\n            return self.verdictAnswers(verdict, interest, of: job)\n        }\n"
     "        return self.withReading(stamp) {\n            self.verdictAnswers(verdict, interest, of: job)\n        }\n",
     "        _ = stamp\n        return self.verdictAnswers(verdict, interest, of: job)\n",
     "barrierDecidesA429OnTheLaneAWaitingVerdictLeaves"),
    ("takeOffAssetsKeep", FOLLOW,
     "        self.state.jobs[job.transfer]?.assets.subtract(held)\n",
     "",
     "barrierJoinsAnIDMappedBackAfterTheVerdictThatWaits"),
    ("vaWallDrop", FAILURES,
     "lane: kept, wall: wall) == nil",
     "lane: kept, wall: self.environment.time.now()) == nil",
     "barrierDecidesA429OnTheLaneAWaitingVerdictLeaves"),
    ("inboundHolderWaitDrop", FOLLOW,
     "return self.state.inboundOnto[transfer] != nil || self.state.inboundMoves[self.state.inboundNext...].contains { $0.holder == transfer }",
     "return self.state.inboundOnto[transfer] != nil",
     "barrierGivesAnInterestMappedBackOffAPublicationItsOutcome"),
    ("catchUpWalkDrop", CATCHUP,
     "        self.bringInboundOntoPublications()\n",
     "",
     "barrierGivesAnInterestMovedOntoAPublicationItsOutcomeThroughACatchUp"),
]


def run(cmd, log):
    with open(log, "w") as handle:
        return subprocess.run(cmd, cwd=SRC, env=ENV, stdout=handle, stderr=subprocess.STDOUT).returncode


def summary(log):
    lines = open(log, errors="replace").read().splitlines()
    out = [l for l in lines if l.startswith("✘ Test") and "recorded an issue" in l][:6]
    out += [l for l in lines if "Test run with" in l]
    return [re.sub(r"\s+", " ", l)[:260] for l in out]


def main():
    only = sys.argv[1:]
    results = []
    for name, path, old, new, test in MUTANTS:
        if only and name not in only:
            continue
        target = os.path.join(SRC, path)
        text = open(target).read()
        count = text.count(old)
        if count != 1:
            results.append(f"{name}: anchor found {count} times, skipped")
            continue
        open(target, "w").write(text.replace(old, new))
        load = os.getloadavg()
        start = time.time()
        rc = run(["swift", "build", "--build-tests", "--scratch-path", "../probebuild"], os.path.join(LOG, f"{name}-build.log"))
        line = f"{name}: build rc={rc} {time.time() - start:.0f}s load {load[0]:.1f}"
        if rc == 0:
            for attempt in (1, 2):
                log = os.path.join(LOG, f"{name}-run{attempt}.log")
                rc_test = run(["swift", "test", "--scratch-path", "../probebuild", "--skip-build", "--filter", test], log)
                line += f"\n  run{attempt} rc={rc_test}: " + " | ".join(summary(log))
        shutil.copyfile(os.path.join(WT, path), target)
        results.append(line)
        print(line, flush=True)
    diff = subprocess.run(["diff", "-rq", os.path.join(WT, "Sources"), os.path.join(SRC, "Sources")], capture_output=True, text=True)
    print("revert diff:", diff.stdout.strip() or "none", flush=True)
    with open(os.path.join(LOG, "summary.txt"), "a") as handle:
        handle.write("\n".join(results) + f"\nrevert diff: {diff.stdout.strip() or 'none'}\n")


if __name__ == "__main__":
    main()
