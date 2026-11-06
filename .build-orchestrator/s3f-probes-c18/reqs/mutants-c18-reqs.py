#!/usr/bin/env python3
"""Cycle-18 reqs verifier mutant runner (scratch only): applies each mutant to the mutation copy, builds, runs its
filter (twice when it fails), else the Sync bundle once (twice when that fails), reverts, and checks the copy."""
import os, subprocess, sys, time, datetime, json

W = "/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f"
S = W + "/.build-verify-s3f-c18-reqs"
SRC = S + "/mutsrc"
BUILD = S + "/mutbuild"
LOGS = S + "/logs/mut"
os.makedirs(LOGS, exist_ok=True)
ENV = dict(os.environ, TMPDIR=S + "/tmp", CLANG_MODULE_CACHE_PATH=S + "/tmp/modcache")
SENSITIVE = {"tsan", "sim", "bench"}

E = "Sources/ZTronAssetSync/Engine/"
MUTANTS = {
    "rerouteOnPassKeepWhole": (E + "EngineFollow.swift",
        "            self.state.jobs[transfer]?.rerouteFor = follow\n        } else {\n            movedBefore = job.rerouteOnPass?.intersection(away) ?? []\n        }\n        self.state.jobs[transfer]?.rerouteOnPass = movedBefore\n",
        "            self.state.jobs[transfer]?.rerouteFor = follow\n            self.state.jobs[transfer]?.rerouteOnPass = movedBefore\n        } else {\n            movedBefore = job.rerouteOnPass?.intersection(away) ?? []\n        }\n",
        "barrierAnswersAnIDMovedBackAndAwayAgainWithThePublicationsOutcome"),
    "takeOffAssetsKeep": (E + "EngineFollow.swift",
        "        self.state.jobs[job.transfer]?.assets.subtract(held)\n",
        "",
        "barrierJoinsAnIDMappedBackAfterThe"),
    "vaStampDrop": (E + "EngineFailures.swift",
        "        return self.withReading(stamp) {\n            self.verdictAnswers(verdict, interest, of: job)\n        }\n",
        "        _ = stamp\n        return self.verdictAnswers(verdict, interest, of: job)\n",
        "barrierDecidesA429OnTheLaneAWaitingVerdictLeaves"),
    "retryAfterWallDrop": (E + "EngineFollow.swift",
        "            self.retryLater(transfer, error: error, answer: answer, wall: wall)\n",
        "            _ = wall\n            self.retryLater(transfer, error: error, answer: answer)\n",
        "barrierReadsARetryAfterDateAtItsArrival"),
    "vaWallDrop": (E + "EngineFailures.swift",
        "            return self.retryDelay(job.transfer, error: error, attempts: attempts, lane: kept, wall: wall) == nil\n",
        "            _ = wall\n            return self.retryDelay(job.transfer, error: error, attempts: attempts, lane: kept, wall: self.environment.time.now()) == nil\n",
        "barrierDecidesA429OnTheLaneAWaitingVerdictLeaves"),
    "applyWalkDrop": (E + "EngineRuns.swift",
        "        self.bringInboundOntoPublications()\n        self.adoptApplied(manifest, etag: etag)\n",
        "        self.adoptApplied(manifest, etag: etag)\n",
        "barrierGivesAnInterestMovedOntoAPublicationItsOutcome"),
    "catchUpWalkDrop": (E + "EngineCatchUp.swift",
        "        self.bringInboundOntoPublications()\n        self.adoptApplied(view.appliedManifest, etag: self.state.appliedETag)\n",
        "        self.adoptApplied(view.appliedManifest, etag: self.state.appliedETag)\n",
        "barrierGivesAnInterestMovedOntoAPublicationItsOutcomeThroughACatchUp"),
    "followedLanePendingHereDrop": (E + "EngineFailures.swift",
        "            if !pending.isEmpty, let target = pending[asset] {\n                return target == job.transfer\n            }\n",
        "",
        None),
    "followedLanePendingFilterDrop": (E + "EngineFailures.swift",
        "if visit?.contains(asset) ?? true || movedBefore.contains(asset) || (!pending.isEmpty && pending[asset] != nil) {",
        "if visit?.contains(asset) ?? true || movedBefore.contains(asset) {",
        None),
    "findInboundPendingDrop": (E + "EngineFollow.swift",
        "                guard pending.isEmpty || pending[asset] == nil, let listed = copy.entry(for: asset) else {\n",
        "                guard let listed = copy.entry(for: asset) else {\n",
        None),
    "shutdownReleaseInboundWaitsDrop": (E + "EngineShutdown.swift",
        "        self.state.pumpWaitsForFollow = false\n        self.releaseInboundWaits()\n",
        "        self.state.pumpWaitsForFollow = false\n",
        None),
    "inboundMadeHolderResumeDrop": (E + "EngineFollow.swift",
        "for transfer in [move.target, move.holder] where",
        "for transfer in [move.target] where",
        None),
    "inboundTargetFailedDrop": (E + "EngineFollow.swift",
        "        case .failed:\n            return job.attemptEnd != nil\n        case .queued, .blocked, .downloading:\n            return false\n",
        "        case .failed:\n            return false\n        case .queued, .blocked, .downloading:\n            return false\n",
        None),
    "inboundMovesNowUnbounded": (E + "EngineFollow.swift",
        "    static let inboundMovesNow = 64\n",
        "    static let inboundMovesNow = 1_000_000\n",
        "barrierMovesConvergingIDsOverTheFollowsTurns"),
}


def log(msg):
    line = f"{datetime.datetime.now():%H:%M:%S} {msg}"
    print(line, flush=True)
    with open(LOGS + "/summary.txt", "a") as f:
        f.write(line + "\n")


def load():
    return subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip()


def wait_quiet():
    while True:
        try:
            phase = open(S + "/phase").read().strip()
        except OSError:
            phase = ""
        if phase not in SENSITIVE:
            return
        time.sleep(15)


def run(cmd, logname, timeout=1500):
    wait_quiet()
    start = time.time()
    with open(LOGS + "/" + logname, "w") as f:
        f.write(f"# {' '.join(cmd)}\n# load at start {load()}\n")
        f.flush()
        try:
            p = subprocess.run(cmd, cwd=SRC, env=ENV, stdout=f, stderr=subprocess.STDOUT, timeout=timeout)
            code = p.returncode
        except subprocess.TimeoutExpired:
            code = -999
        f.write(f"\n# exit {code} after {time.time() - start:.1f} s, load at end {load()}\n")
    return code


def summary_lines(logname):
    out = []
    for line in open(LOGS + "/" + logname, errors="replace"):
        if ("Test run with" in line) or ("Expectation failed" in line and len(out) < 12) or ("Time limit" in line) or ("error:" in line and len(out) < 12) or line.startswith("# exit"):
            out.append(line.rstrip()[:400])
    return out


def main(names):
    for name in names:
        path, old, new, test = MUTANTS[name]
        full = os.path.join(SRC, path)
        text = open(full).read()
        count = text.count(old)
        if count != 1:
            log(f"{name}: SKIP, pattern count {count}")
            continue
        open(full, "w").write(text.replace(old, new))
        try:
            code = run(["swift", "build", "--build-tests", "--scratch-path", BUILD], f"{name}-build.log")
            if code != 0:
                log(f"{name}: BUILD FAILED {summary_lines(name + '-build.log')}")
                continue
            results = []
            if test:
                code = run(["swift", "test", "--skip-build", "--scratch-path", BUILD, "--filter", test], f"{name}-filter1.log")
                results.append(("filter1", code, summary_lines(name + "-filter1.log")))
                if code != 0:
                    code2 = run(["swift", "test", "--skip-build", "--scratch-path", BUILD, "--filter", test], f"{name}-filter2.log")
                    results.append(("filter2", code2, summary_lines(name + "-filter2.log")))
            if not test or results[-1][1] == 0:
                code = run(["swift", "test", "--skip-build", "--scratch-path", BUILD, "--skip", "Benchmarks", "--filter", "ZTronAssetSyncTests"], f"{name}-bundle1.log")
                results.append(("bundle1", code, summary_lines(name + "-bundle1.log")))
                if code != 0:
                    code2 = run(["swift", "test", "--skip-build", "--scratch-path", BUILD, "--skip", "Benchmarks", "--filter", "ZTronAssetSyncTests"], f"{name}-bundle2.log")
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
