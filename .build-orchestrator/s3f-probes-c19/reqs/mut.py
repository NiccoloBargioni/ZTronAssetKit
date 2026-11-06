#!/usr/bin/env python3
"""Cycle-19 reqs verifier mutant runner (scratch only, never committed). Applies each mutant to the mutation copy
(mutsrc), builds it (mutbuild), runs its filter (a second time when the first run fails, for 2/2), else the Sync bundle
once (twice when that fails), reverts, and diffs the copy's Sources/ against the worktree's."""
import os, subprocess, sys, time, datetime

W = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f"
S = W + "/.build-verify-s3f-c19-reqs"
SRC = S + "/mutsrc"
BUILD = S + "/mutbuild"
LOGS = S + "/logs/mut"
os.makedirs(LOGS, exist_ok=True)
ENV = dict(os.environ, TMPDIR=S + "/tmp", CLANG_MODULE_CACHE_PATH=S + "/tmp/modcache", LLVM_PROFILE_FILE=S + "/tmp/prof-%p.profraw")

E = "Sources/ZTronAssetSync/Engine/"
PENDING = "barrierDecidesA429OnTheLaneAnOwedMoveLeavesAfterALaterApply|barrierDecidesA429WithoutAnInterestTheOwedMovesVerdictAnswers"
SHARED = "barrierMovesASharedContentsIDsOverBoundedTurns"
SHUT = "barrierShutsDownWhileAPublicationWaitsForOwedMoves"
DRAIN = "barrierDrainsTheEventsAfterAVisitsRest"
TWO = "barrierMovesOneHoldersIDsOntoTwoPublications"
REST = "barrierMakesTheOwedMovesBeforeAVisitsRest"
HOPBIND = "barrierBindsTheIDAPublicationKeepsOnceTheMoveOffItsJobIsMade"
STALE = "barrierSpendsTheRerouteOfAVisitMadeOverTurns"
NEW19 = "|".join([PENDING, SHARED, DRAIN, TWO, REST, HOPBIND, STALE])
LANE = PENDING + "|VerifyC18Correct/pendingLane|VerifyC18Correct/pendingNotFound"

MUTANTS = {
    # c18 #8 (followedLane's owed-move clauses) and c18 #1 (the lane of an id an owed move carries)
    "laneCarriedDrop": (E + "EngineFailures.swift",
        "        func carried(_ asset: AssetID) -> Job? {\n            guard !pending.isEmpty, let index = pending[asset] else {\n                return nil\n            }\n            return self.waitingTarget(self.state.inboundMoves[index])\n        }\n",
        "        func carried(_ asset: AssetID) -> Job? {\n            _ = pending\n            return nil\n        }\n",
        LANE, 1500),
    "laneTargetVerdictDrop": (E + "EngineFailures.swift",
        "            var targetRule = targets[target.transfer] ?? rule(of: target)\n",
        "            var targetRule = targets[target.transfer] ?? { let r = rule(of: target); return LaneMoveRule(job: r.job, visit: r.visit, movedBefore: r.movedBefore, after: nil) }()\n",
        LANE, 1500),
    "laneHolderRule": (E + "EngineFailures.swift",
        "                        if let viaTarget = movesViaTarget(asset, interest, &targets) {\n                            reaches = viaTarget\n                        } else {\n                            reaches = moves(asset, interest, under: &own)\n                        }\n",
        "                        reaches = moves(asset, interest, under: &own)\n",
        LANE, 1500),
    "laneOwnViaTargetDrop": (E + "EngineFailures.swift",
        "                    if movesViaTarget(asset, interest, &targets) ?? true {\n",
        "                    if true {\n",
        LANE, 1500),
    "laneVisitedCarriedDrop": (E + "EngineFailures.swift",
        "job.assets.contains { !here($0) || carried($0) != nil })",
        "job.assets.contains { !here($0) })",
        LANE, 1500),
    # c18 #9 (foundInbound's pending guard and its insert branches)
    "findInboundPendingDrop": (E + "EngineFollow.swift",
        "                guard pending.isEmpty || pending[asset] == nil, let listed = copy.entry(for: asset) else {\n",
        "                guard let listed = copy.entry(for: asset) else {\n",
        SHARED, 1500),
    "firstInsertDrop": (E + "EngineFollow.swift",
        "                } else if first?.target == index {\n                    first?.ids.insert(asset)\n",
        "                } else if first?.target == index {\n",
        TWO, 1500),
    "othersSlotInsertDrop": (E + "EngineFollow.swift",
        "                    others[slot].ids.insert(asset)\n",
        "                    _ = slot\n",
        TWO, 1500),
    "othersAppendDrop": (E + "EngineFollow.swift",
        "                    others.append((index, [asset]))\n",
        "",
        TWO, 1500),
    # c18 #10 (the publication's wait released)
    "inboundMadeHolderResumeDrop": (E + "EngineFollow.swift",
        "for transfer in [move.target, move.holder] where",
        "for transfer in [move.target] where",
        HOPBIND, 1500),
    "restEndResumeDrop": (E + "EngineFollow.swift",
        "        if !self.inboundBlocks(rest.holder) {\n            self.state.inboundWaits.removeValue(forKey: rest.holder)?.resume()\n        }\n        return made.moved\n",
        "        return made.moved\n",
        SHARED, 1500),
    "shutdownReleaseInboundWaitsDrop": (E + "EngineShutdown.swift",
        "        self.state.pumpWaitsForFollow = false\n        self.releaseInboundWaits()\n",
        "        self.state.pumpWaitsForFollow = false\n",
        SHUT, 360),
    # c18 #7 (C2: the bound by ids; S3-R23 item 3's drop-mutants of the bound)
    "startChunkDrop": (E + "EngineMoves.swift",
        "        guard moved.count > budget else {\n",
        "        guard moved.count > Int.max else {\n",
        NEW19, 2400),
    "inboundIDsNowFull": (E + "EngineMoves.swift",
        "        max(1, self.state.followIDsPerTurn / 2)\n",
        "        max(1, self.state.followIDsPerTurn * 4)\n",
        NEW19, 2400),
    "continueMoveBudgetDrop": (E + "EngineMoves.swift",
        "            if asset != current {\n                guard spent < budget else {\n                    break\n                }\n",
        "            if asset != current {\n",
        NEW19, 2400),
    "inboundSpentDrop": (E + "EngineFollow.swift",
        "                budget.ids -= made.spent\n                moved = moved || made.moved\n",
        "                moved = moved || made.moved\n",
        NEW19, 2400),
    "restSpentDrop": (E + "EngineFollow.swift",
        "        budget.ids -= made.spent\n        guard rest.moves.isDone else {\n",
        "        guard rest.moves.isDone else {\n",
        NEW19, 2400),
    "visitSpentDrop": (E + "EngineFollow.swift",
        "            self.follow(transfer, ids: ids, afterVerdict: false)\n        }\n        budget.ids -= made.spent\n",
        "            self.follow(transfer, ids: ids, afterVerdict: false)\n        }\n",
        NEW19, 2400),
    "drainVisitIDsFull": (E + "EngineFollow.swift",
        "        _ = self.follow(transfer, ids: self.state.followIDsPerTurn, afterVerdict: true)\n",
        "        _ = self.follow(transfer, ids: Int.max, afterVerdict: true)\n",
        DRAIN, 1500),
}


def log(msg):
    line = f"{datetime.datetime.now():%H:%M:%S} {msg}"
    print(line, flush=True)
    with open(LOGS + "/summary.txt", "a") as f:
        f.write(line + "\n")


def load():
    return subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip()


def run(cmd, logname, timeout):
    start = time.time()
    with open(LOGS + "/" + logname, "w") as f:
        f.write(f"# {' '.join(cmd)}\n# start {datetime.datetime.now():%H:%M:%S} load {load()}\n")
        f.flush()
        p = subprocess.Popen(cmd, cwd=SRC, env=ENV, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Stop the whole process group of this run (our own swift-test and its helpers only).
            for sig in (15, 9):
                try:
                    os.killpg(p.pid, sig)
                except (ProcessLookupError, PermissionError):
                    pass
                time.sleep(5)
            # A test helper can leave the group (its own session): stop the ones that run this copy's build, by PID.
            ps = subprocess.run(["ps", "-ax", "-o", "pid=,command="], capture_output=True, text=True).stdout
            for line in ps.splitlines():
                pid, _, command = line.strip().partition(" ")
                if BUILD + "/" in command and "swiftpm-testing-helper" in command:
                    try:
                        os.kill(int(pid), 9)
                        f.write(f"# stopped leftover helper {pid}\n")
                    except (ProcessLookupError, PermissionError):
                        pass
            try:
                p.wait(timeout=30)
            except subprocess.TimeoutExpired:
                pass
            code = -999
        f.write(f"\n# exit {code} after {time.time() - start:.1f} s, end {datetime.datetime.now():%H:%M:%S} load {load()}\n")
    return code


def summary_lines(logname):
    out = []
    issues = 0
    for line in open(LOGS + "/" + logname, errors="replace"):
        keep = False
        if "Test run with" in line or line.startswith("# exit") or "Time limit" in line:
            keep = True
        elif ("recorded an issue" in line or "error:" in line) and issues < 14:
            issues += 1
            keep = True
        if keep:
            out.append(line.rstrip()[:420])
    return out


def main(names):
    for name in names:
        path, old, new, test, timeout = MUTANTS[name]
        full = os.path.join(SRC, path)
        text = open(full).read()
        count = text.count(old)
        if count != 1:
            log(f"{name}: SKIP, pattern count {count}")
            continue
        open(full, "w").write(text.replace(old, new))
        try:
            code = run(["swift", "build", "--build-tests", "--scratch-path", BUILD], f"{name}-build.log", 2400)
            if code != 0:
                log(f"{name}: BUILD FAILED {summary_lines(name + '-build.log')}")
                continue
            results = []
            code = run(["swift", "test", "--skip-build", "--scratch-path", BUILD, "--filter", test], f"{name}-filter1.log", timeout)
            results.append(("filter1", code, summary_lines(name + "-filter1.log")))
            if code != 0:
                code2 = run(["swift", "test", "--skip-build", "--scratch-path", BUILD, "--filter", test], f"{name}-filter2.log", timeout)
                results.append(("filter2", code2, summary_lines(name + "-filter2.log")))
            if results[-1][1] == 0:
                bundle = ["swift", "test", "--skip-build", "--scratch-path", BUILD, "--skip", "Benchmarks", "--skip", "VerifyC18Correct", "--filter", "ZTronAssetSyncTests"]
                code = run(bundle, f"{name}-bundle1.log", 3600)
                results.append(("bundle1", code, summary_lines(name + "-bundle1.log")))
                if code != 0:
                    code2 = run(bundle, f"{name}-bundle2.log", 3600)
                    results.append(("bundle2", code2, summary_lines(name + "-bundle2.log")))
            for label, c, lines in results:
                log(f"{name}: {label} exit {c}")
                for l in lines:
                    log(f"    {l}")
        finally:
            open(full, "w").write(text)
            diff = subprocess.run(["diff", "-rq", SRC + "/Sources", W + "/Sources"], capture_output=True, text=True).stdout.strip()
            log(f"{name}: reverted; sources diff: {diff or 'none'}")


if __name__ == "__main__":
    main(sys.argv[1:] or list(MUTANTS))
