#!/usr/bin/env python3
"""c12 reqs verifier: apply a fixer-defined mutant (fixer-mutants.json edits) to src/, rebuild in mbuild/, run a filter twice, revert."""
import os, subprocess, sys, pathlib, json, hashlib
R = pathlib.Path("/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c12-reqs")
SRC = R / "src"
M = json.load(open(R / "fixer-mutants.json"))
FILTERS = {
    "readmitNow": "barrierReadmitsBehindTheOwedVisitsPlaces|barrierPlacesAReadmissionAsTheFollowLeavesIt",
    "retryDueNow": "barrierRetriesBehindTheOwedVisitsPlaces",
    "requeueReplayDropped": "barrierRequeuesACancelledAttemptBehindTheOwedVisitsPlaces",
    "pauseParkDropped": "barrierParksAPolicyPauseWithItsPlace",
    "stillWantsAlways": "barrierDropsTheJoinOfAnEndedRun",
    "unblockNow": "EngineFollowBarrierTests/barrierHoldsAPendingRunBehindTheOwedPump",
    "noDispatchOwedFlag": "EngineFollowBarrierTests/barrierHoldsAPendingRunBehindTheOwedPump",
    "committedNow": "barrierPlacesACommitsMovedIDAtTheFollowsPlace|barrierGivesACommitsSlotToTheFollowsReroute",
    "noPublishedVisit": "barrierPlacesACommitsMovedIDAtTheFollowsPlace|barrierGivesACommitsSlotToTheFollowsReroute",
    "timerUnblockDropped": "barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply",
    "placeStampsIgnored": "EngineFollowBarrierTests/barrier.*",
    "noArrivalThrottle": "barrierThrottlesTheOriginWhenA429Arrives|barrierThrottlesForTheFollowedLane",
    "arrivalJobLane": "barrierThrottlesForTheFollowedLane",
    "throttleReadLive": "barrierAnswersAJoinOnTheThrottleAtItsRequest|barrierAnswersAJoinWithTheExtensionAfterIt|barrierAnswersAThrottleParkWithItsOwnWait",
    "visitsLive": "barrierAdmitsTheFollowsNewContentAsAtTheApply|barrierGatesTheFollowsNewContentOnTheThrottleAtTheApply",
    "viewBreakerOutcomeDropped": "EngineRegressionRound2Tests",
    "alarmAtPark": "barrierAnswersAThrottleParkWithItsOwnWait",
}
ENV = dict(os.environ, TMPDIR=str(R / "tmp"), CLANG_MODULE_CACHE_PATH=str(R / "tmp/mc"), LLVM_PROFILE_FILE=str(R / "tmp/%p.profraw"))
LOGS = R / "mut"; LOGS.mkdir(exist_ok=True)

def md5_sources(root):
    h = hashlib.md5()
    for p in sorted((root / "Sources").rglob("*.swift")):
        h.update(p.read_bytes())
    return h.hexdigest()

def run(name, flt=None, runs=2):
    edits = M[name]["edits"]; flt = flt or FILTERS[name]
    originals = {}
    try:
        for rel, old, new, count in edits:
            path = SRC / rel; cur = path.read_text(); originals.setdefault(rel, cur)
            assert cur.count(old) == count, f"{name}: {rel} has {cur.count(old)} of the target, expected {count}"
            path.write_text(cur.replace(old, new))
        b = subprocess.run(["nice", "-n", "10", "swift", "build", "--build-tests", "--scratch-path", str(R / "mbuild")], cwd=SRC, env=ENV,
                           stdout=open(LOGS / f"{name}-build.log", "w"), stderr=subprocess.STDOUT)
        print(f"MUTANT {name}: build exit {b.returncode}", flush=True)
        if b.returncode != 0:
            return
        for i in range(1, runs + 1):
            out = LOGS / f"{name}-run{i}.log"
            r = subprocess.run(["timeout", "1500", "nice", "-n", "10", "swift", "test", "--skip-build", "--scratch-path", str(R / "mbuild"), "--filter", flt, "--skip", "probeREPendingRun|Verify"],
                               cwd=SRC, env=ENV, stdout=open(out, "w"), stderr=subprocess.STDOUT)
            lines = out.read_text().splitlines()
            summary = [l for l in lines if "Test run with" in l]
            issues = [l for l in lines if "recorded an issue" in l]
            print(f"MUTANT {name} run {i}: exit {r.returncode} :: {summary[-1] if summary else 'no summary'}", flush=True)
            for l in issues[:5]:
                print(f"    {l[:330]}", flush=True)
    finally:
        for rel, text in originals.items():
            (SRC / rel).write_text(text)
        wt = R.parent
        print(f"MUTANT {name}: reverted; Sources md5 worktree={md5_sources(wt)} scratch={md5_sources(SRC)}", flush=True)

if __name__ == "__main__":
    for n in sys.argv[1:]:
        run(n)
