#!/usr/bin/env python3
"""Cycle-20 reqs verifier: drop-mutants on a scratch copy (mutsrc), built in mutbuild; 2 runs of each filter."""
import os, subprocess, datetime, sys, re
W = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f"
S = W + "/.build-verify-s3f-c20-reqs"
SRC = S + "/mutsrc"
B = S + "/mutbuild"
LOGS = S + "/logs/mut"
os.makedirs(LOGS, exist_ok=True)
ENV = dict(os.environ, TMPDIR=S + "/tmp", CLANG_MODULE_CACHE_PATH=S + "/tmp/modcache")
E = "/Sources/ZTronAssetSync/Engine/"
TT = "barrierBoundsAnOwedMovesTurnAcrossHolders|barrierBoundsARestsTurnAcrossHolders"
LEG = "barrierWalksOntoAChecksumLessPublication"
DRAIN = "barrierBoundsTheDrainsVisitsAfterVerdictsByOneTurnsIDs"
COUNTS = "EngineInterestCountsTests"
SHUT = "admissionStraddlingShutdownFollowsNothing"
REVAL = "barrierRereadsWhatLandsBetweenABoundedMovesTurns"
READMIT = "barrierReadmitsBehindTheOwedVisitsPlaces"
GUARD1 = "            guard let interest = self.state.jobs[holder]?.interests[item.token].map({ JobInterest(lane: $0.lane, kind: $0.kind, assets: []) }) else {\n                continue\n            }\n"
STANDIN = "            let interest = self.state.jobs[holder]?.interests[item.token].map({ JobInterest(lane: $0.lane, kind: $0.kind, assets: []) }) ?? JobInterest(lane: .bulk, kind: .run, assets: [])\n"
GUARD2 = "            guard self.state.jobs[holder]?.removeAsset(asset, for: item.token) == true else {\n                continue\n            }\n"
NOGUARD2 = "            _ = self.state.jobs[holder]?.removeAsset(asset, for: item.token)\n"
M = {
    # reqs #1
    "inboundSpentDrop": ("EngineFollow.swift", "                budget.ids -= made.spent\n                moved = moved || made.moved\n", "                moved = moved || made.moved\n", TT),
    "restSpentDrop": ("EngineFollow.swift", "        budget.ids -= made.spent\n        guard rest.moves.isDone else {\n", "        guard rest.moves.isDone else {\n", TT),
    "visitSpentDrop": ("EngineFollow.swift", "            self.follow(transfer, ids: ids, afterVerdict: false)\n        }\n        budget.ids -= made.spent\n", "            self.follow(transfer, ids: ids, afterVerdict: false)\n        }\n", TT),
    "continueMoveBudgetDrop": ("EngineMoves.swift", "                guard spent < budget else {\n                    break\n                }\n                spent += 1\n", "                spent += 1\n", TT),
    # reqs #2
    "byIdentifierTargetDrop": ("EngineFollow.swift", "                byIdentifier[target.entry.identifier] = index\n", "                _ = index\n", LEG),
    "byIdentifierLookupDrop": ("EngineFollow.swift", "                    index = byIdentifier[asset].flatMap { SyncEngine.sameTransfer(listed, targets[$0].entry) ? $0 : nil }\n", "                    index = nil\n", LEG),
    # correct #1 (the cycle-19 defect itself, then the budget's subtraction, the seed and the break)
    "drainOriginalDefect": ("EngineFollow.swift", "        let made = self.follow(transfer, ids: self.state.drainIDsLeft, afterVerdict: true)\n        self.state.drainIDsLeft -= made.spent\n", "        _ = self.follow(transfer, ids: self.state.followIDsPerTurn, afterVerdict: true)\n", DRAIN),
    "drainSpentDrop": ("EngineFollow.swift", "        self.state.drainIDsLeft -= made.spent\n", "        _ = made\n", DRAIN),
    "drainSeedFull": ("EngineFollow.swift", "        self.drainEventsAfterFollow(ids: budget.ids)\n", "        self.drainEventsAfterFollow()\n", DRAIN),
    "drainSpentBreakDrop": ("EngineFollow.swift", "            if self.state.followMoving != nil || self.state.drainIDsLeft <= 0 {\n", "            if self.state.followMoving != nil {\n", DRAIN),
    # correct #2
    "countInsertDrop": ("EngineState.swift", "        case (nil, let added?):\n            self.interestCounts.add(added)\n", "        case (nil, _?):\n            break\n", COUNTS),
    "countRemovalDrop": ("EngineState.swift", "        case (let removed?, nil):\n            self.interestCounts.remove(removed)\n", "        case (_?, nil):\n            break\n", COUNTS),
    "countLaneChangeDrop": ("EngineState.swift", "        case (let old?, let new?):\n            self.interestCounts.remove(old)\n            self.interestCounts.add(new)\n", "        case (_?, _?):\n            break\n", COUNTS),
    # reqs #4
    "admissionGuardDrop": ("EngineManifest.swift", "                    let view = try await self.store.planningView()\n                    guard self.isRunning else {\n                        return\n                    }\n", "                    let view = try await self.store.planningView()\n", SHUT),
    "followOwedClauseDrop": ("EngineCommands.swift", "        if !self.isRunning, self.followOwed {\n            violations.append(\"a follow is owed while the engine is \\(self.state.lifecycle)\")\n        }\n", "", SHUT),
    # reqs #5
    "moveIDGoneDrop": ("EngineMoves.swift", GUARD2, NOGUARD2, REVAL),
    "supersedeRelaneDrop": ("EngineMoves.swift", "            } else {\n                self.relane(holder, from: progress.lane)\n            }\n", "            }\n", REVAL),
    "moveInterestGoneDrop": ("EngineMoves.swift", GUARD1, STANDIN, REVAL),
    "moveInterestGoneReroute": ("EngineMoves.swift", GUARD1 + GUARD2, STANDIN + NOGUARD2, REVAL),
    # reqs #6: the defect the de-flaked assertion guards (a readmission turn not held behind the owed follow)
    "readmitDeferDrop": ("EngineReadmission.swift", "        if self.defersToFollow {\n            self.deferToFollow(.readmit(passes))\n", "        if false, self.defersToFollow {\n            self.deferToFollow(.readmit(passes))\n", READMIT),
    # reqs #6
    "admissionRecordDrop": ("EngineDispatch.swift", "        self.state.admissionsForTests?.append(AttemptAdmission(transfer: transfer, ticket: job.ticket, place: job.queuePlace, attempt: attempt))\n", "", READMIT),
}
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
        out, rc = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or ""), "TIMEOUT"
    open(f"{LOGS}/{tag}-run{i}.log", "w").write(out)
    log(f"{tag}: run{i} exit {rc} load {load()}")
    issues = [l for l in out.splitlines() if "recorded an issue" in l]
    for l in issues[:4]:
        log("    " + re.sub(r"\s+", " ", l)[:300])
    if len(issues) > 4:
        log(f"    ... {len(issues)} issue lines")
    for l in out.splitlines():
        if "Test run with" in l:
            log("    " + l.strip()[:200])
mode = sys.argv[1]
if mode == "baseline":
    if build("baseline"):
        for i in (1, 2):
            run("baseline", "|".join([TT, LEG, DRAIN, COUNTS, SHUT, REVAL, READMIT]), i)
    sys.exit(0)
for name in sys.argv[2:]:
    fname, old, new, filt = M[name]
    F = SRC + E + fname
    text = open(F).read()
    if text.count(old) != 1:
        log(f"{name}: SKIP count {text.count(old)}")
        continue
    open(F, "w").write(text.replace(old, new))
    try:
        if build(name):
            for i in (1, 2):
                run(name, filt, i)
    finally:
        open(F, "w").write(text)
        d = subprocess.run(["diff", "-rq", SRC + "/Sources", W + "/Sources"], capture_output=True, text=True).stdout.strip()
        log(f"{name}: reverted; sources diff: {d or 'none'}")
