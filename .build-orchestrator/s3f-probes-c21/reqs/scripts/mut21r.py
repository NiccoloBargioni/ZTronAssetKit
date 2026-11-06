#!/usr/bin/env python3
"""Cycle-21 reqs verifier: re-applies the cycle-20 defects (and drop-mutants of their bounds) on a scratch copy
(mutsrc, built in mutbuild) and runs each item's tests twice. Usage: mut21r.py baseline | mut21r.py NAME..."""
import os, subprocess, datetime, sys, re
W = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f"
S = W + "/.build-verify-s3f-c21-reqs"
SRC = S + "/mutsrc"
B = S + "/mutbuild"
LOGS = S + "/logs/mut"
os.makedirs(LOGS, exist_ok=True)
ENV = dict(os.environ, TMPDIR=S + "/tmp", CLANG_MODULE_CACHE_PATH=S + "/modcache")
E = "/Sources/ZTronAssetSync/Engine/"

SITE1 = "commitOwesItsReroutesAndTheDrainMakesThemBounded|commitOwesWhenItsAnswersAndReroutesPassTheBound|twoCommitsOweABatchEach"
SITE3 = "supersededPublicationOwesItsReroutesAndTheDrainMakesThemBounded|supersededPublicationCountsItsPairsAgainstItsTurn"
SITE2 = "drainOwesATakeOffThatDoesNotFitItsTurnRightBehindTheVerdict|drainSpendsTheVerdictsTurnOnATakeOffThatOwes|drainChargesAFittingTakeOffToItsTurnAndOwesTheNext"
DRAIN = "commitOwesItsReroutesAndTheDrainMakesThemBounded|drainReroutesAnOwedIDWithAllItsTokensInOneTurn|supersededPublicationOwesItsReroutesAndTheDrainMakesThemBounded"
ATEST = "barrierWaitsTheJoinsBehindAVerdictOutsideTheQueue|barrierPlacesTheJoinsBehindAVerdictRightBehindItNewestFirst"
I5 = "barrierMakesAMoveOntoAJobItsDrainedPublicationReQueued|owedReroutePinnedToARequeuedJobFollowsTheCopy"
K4 = "invariantsReportAnEventWaitingOnceShutDown"
IDX = "EngineIDTokensTests"
OWED = "EngineOwedAnswersTests"
MOVE = "EngineFollowBarrierMoveHoldersTests|EngineFollowBarrierTurnTotalTests"

OLD_DEFER = ("        self.state.joinsAfterFollow[join.token, default: [:]][join.asset] = join.entry.transferID\n"
             "        self.state.joinsBehindVerdicts[VerdictKey(transfer: target.transfer, epoch: target.epoch), default: []].append(JoinBehindVerdict(join: join, stamp: self.worldStamp()))\n")
C20_DEFER = ("        let events = self.state.eventsAfterFollow\n"
             "        let verdict = events.lastIndex { event in\n"
             "            switch event {\n"
             "            case .attemptFailed(let transfer, let epoch, _), .spaceFailure(let transfer, let epoch, _):\n"
             "                return transfer == target.transfer && epoch == target.epoch\n"
             "            default:\n"
             "                return false\n"
             "            }\n"
             "        }\n"
             "        let index = (verdict ?? events.count - 1) + 1\n"
             "        self.state.joinsAfterFollow[join.token, default: [:]][join.asset] = join.entry.transferID\n"
             "        self.state.eventsAfterFollow.insert(.join(join), at: index)\n"
             "        self.state.eventStamps.insert(self.worldStamp(), at: min(index, self.state.eventStamps.count))\n")
M = {
    # c20 reqs #0 / correct #3: the commit makes every re-route in its own turn (the cycle-20 code path).
    "site1-never-owe": ("EngineDispatch.swift", "        if rerouted > 0, locations.count + rerouted > self.inboundIDsNow {\n",
                        "        if false, rerouted > 0, locations.count + rerouted > self.inboundIDsNow {\n", SITE1),
    # c20 correct #2: a superseded exit re-routes every pair in its own turn.
    "site3-never-owe": ("EngineDispatch.swift", "        if let bound, job.interests.values.reduce(0, { $0 + $1.assets.count }) > bound {\n",
                        "        if false, let bound, job.interests.values.reduce(0, { $0 + $1.assets.count }) > bound {\n", SITE3),
    # c20 reqs #1: the drain's take-off makes every re-route in the verdict's turn, uncharged.
    "site2-never-owe": ("EngineFollow.swift", "        let owes = ids > self.state.drainIDsLeft\n        self.state.drainIDsLeft = owes ? 0 : self.state.drainIDsLeft - ids\n        return owes\n",
                        "        _ = ids\n        return false\n", SITE2),
    # the drain turn's id bound over an owed batch (S3-R23 item 3's drop-mutant of the bound).
    "drain-spend-guard-drop": ("EngineFollow.swift", "                guard spent < self.state.drainIDsLeft else {\n                    break\n                }\n                spent += 1\n                current = item.asset\n",
                               "                spent += 1\n                current = item.asset\n", DRAIN),
    "drain-spend-sub-drop": ("EngineFollow.swift", "        self.state.drainIDsLeft -= spent\n        if batch.items.isEmpty {\n",
                             "        if batch.items.isEmpty {\n", DRAIN),
    # c20 reqs #2 / correct #1: the cycle-20 O(E) queue insert behind the verdict, put back.
    "a-orig-queue-insert": ("EngineFollow.swift", OLD_DEFER, C20_DEFER, ATEST),
    # the side list's drop-mutant: the bucket append dropped.
    "a-drop-bucket-append": ("EngineFollow.swift", "        self.state.joinsBehindVerdicts[VerdictKey(transfer: target.transfer, epoch: target.epoch), default: []].append(JoinBehindVerdict(join: join, stamp: self.worldStamp()))\n",
                             "", ATEST),
    # c20 reqs #3 / correct #5: waitingTarget's queued, blocked and downloading arm folded into the publishing arm.
    "i5-fold": ("EngineFollow.swift", "        case .queued, .blocked, .downloading:\n            return nil\n",
                "        case .queued, .blocked, .downloading:\n            return job\n", I5),
    # c20 reqs #4 / correct #6: K4, the clause that stands for the removed branch.
    "k4-drop": ("EngineCommands.swift", "        if !self.isRunning, !events.isEmpty {\n            violations.append(\"\\(events.count) events wait for a follow while the engine is \\(self.state.lifecycle)\")\n        }\n",
                "", K4),
    # c20 correct #0 (item B): the index keeps a holder that left (its upkeep, I1).
    "idx-release-keeps-entry": ("EngineState.swift", "        if self.tokensByID[asset]?.remove(token) == false {\n            self.tokensByID[asset] = nil\n        }\n",
                                "        _ = self.tokensByID[asset]?.remove(token)\n", IDX),
    # c20 correct #0: the per-turn id bound of a move (the deterministic per-turn count).
    "move-turn-bound-drop": ("EngineMoves.swift", "            guard spent < budget else {\n                break\n            }\n            spent += 1\n            self.state.jobs[holder]?.assets.remove(asset)\n",
                             "            spent += 1\n            self.state.jobs[holder]?.assets.remove(asset)\n", MOVE),
    # c20 correct #4 (item C, Phase 2): a large job's answers all resumed in the commit's turn (the cycle-20 path).
    "c12-never-owe": ("EngineJobs.swift", "        let owing = job.interests.count > self.state.answersPerTurn\n", "        let owing = false\n", OWED),
    # the answer follow-up's per-turn bound dropped.
    "c12-followup-unbounded": ("EngineJobs.swift", "        let end = min(self.state.owedAnswers.count, self.state.owedAnswersHead + self.state.answersPerTurn)\n",
                               "        let end = self.state.owedAnswers.count\n", OWED),
    # c20 reqs #6 / S3-R26 item 10: the commit's partial trim at once (the line that replaced 8e1fb24's :1118).
    "r7-partial-trim-drop": ("EngineDispatch.swift", "                    self.state.jobs[transfer]?.subtractAssets(trim.unbound, for: trim.token)\n",
                             "                    _ = trim\n", "runJoinsSharedJobWhileItVerifies"),
    # the fixer's open survivors, spot-checked against the whole Sync suite (one run each, RUNS=1).
    "f7-delisted-stays": ("EngineDispatch.swift", "                    if !(self.state.applied.entry(for: asset).map({ SyncEngine.sameTransfer($0, jobEntry) }) ?? false) {\n",
                          "                    if !(self.state.applied.entry(for: asset).map({ SyncEngine.sameTransfer($0, jobEntry) }) ?? true) {\n", "ZTronAssetSyncTests"),
    "b23-no-kind": ("EngineCommands.swift", "$0.lane < .userInitiated && $0.kind != .waiter && isPurged($0.asset)",
                    "$0.lane < .userInitiated && isPurged($0.asset)", "ZTronAssetSyncTests"),
    # item 5's fold against Shape A alone (Step 7 claims it fails Shape A's one-turn state assertion 2/2).
    "i5-fold-shapeA": ("EngineFollow.swift", "        case .queued, .blocked, .downloading:\n            return nil\n",
                       "        case .queued, .blocked, .downloading:\n            return job\n", "barrierMakesAMoveOntoAJobItsDrainedPublicationReQueued"),
}
ALL = "|".join(sorted(set("|".join([SITE1, SITE3, SITE2, DRAIN, ATEST, I5, K4, IDX, OWED, MOVE, "runJoinsSharedJobWhileItVerifies"]).split("|"))))

def load():
    return subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip()
def log(m):
    line = f"{datetime.datetime.now():%H:%M:%S} {m}"
    print(line, flush=True)
    open(LOGS + "/summary.txt", "a").write(line + "\n")
def build(tag):
    b = subprocess.run(["swift", "build", "--build-tests", "--scratch-path", B], cwd=SRC, env=ENV, capture_output=True, text=True)
    open(f"{LOGS}/{tag}-build.log", "w").write(b.stdout + b.stderr)
    log(f"{tag}: build exit {b.returncode} load {load()}")
    return b.returncode == 0
def run(tag, filt, i):
    args = ["swift", "test", "--skip-build", "--scratch-path", B]
    for f in filt.split("|"):
        args += ["--filter", f]
    try:
        r = subprocess.run(args, cwd=SRC, env=ENV, capture_output=True, text=True, timeout=1500)
        out, rc = r.stdout + r.stderr, r.returncode
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        rc = "TIMEOUT"
    open(f"{LOGS}/{tag}-run{i}.log", "w").write(out)
    log(f"{tag}: run{i} exit {rc} load {load()}")
    failed = [l for l in out.splitlines() if l.startswith("✘ Test") and "argument" in l]
    for l in failed[:8]:
        log("    " + re.sub(r"\s+", " ", l)[:260])
    issues = [l for l in out.splitlines() if "recorded an issue" in l]
    for l in issues[:3]:
        log("    " + re.sub(r"\s+", " ", l)[:300])
    if len(issues) > 3:
        log(f"    ... {len(issues)} issue lines")
    for l in out.splitlines():
        if "Test run with" in l:
            log("    " + l.strip()[:200])

mode = sys.argv[1]
if mode == "baseline":
    if build("baseline"):
        run("baseline", ALL, 1)
    sys.exit(0)
for name in sys.argv[1:]:
    fname, old, new, filt = M[name]
    F = SRC + E + fname
    text = open(F).read()
    if text.count(old) != 1:
        log(f"{name}: SKIP count {text.count(old)}")
        continue
    open(F, "w").write(text.replace(old, new))
    try:
        if build(name):
            for i in range(1, int(os.environ.get('RUNS', '2')) + 1):
                run(name, filt, i)
    finally:
        open(F, "w").write(text)
        d = subprocess.run(["diff", "-rq", SRC + "/Sources", W + "/Sources"], capture_output=True, text=True).stdout.strip()
        log(f"{name}: reverted; sources diff: {d or 'none'}")
