#!/usr/bin/env python3
"""Apply each mutant to the scratch copy, build, run its filter twice, revert. Never touches the worktree."""
import os, subprocess, sys, time

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "src")
BUILD = os.path.join(ROOT, "build")
LOGS = os.path.join(ROOT, "logs")
os.makedirs(LOGS, exist_ok=True)
E = "Sources/ZTronAssetSync/Engine/"

MUTANTS = {
    # R-I (finding 10/11): the stamp's view admits again, as at 3f10eaa.
    "stampAdmits": (E + "EngineDispatch.swift", [(
        "            if case .reject(let cause, _)? = view.breaker?.admission(of: transfer, at: stamp.at) {\n                return .block(.circuitOpen(cause))\n            }\n",
        "            switch view.breaker?.admission(of: transfer, at: stamp.at) {\n            case .reject(let cause, _)?:\n                return .block(.circuitOpen(cause))\n            case .allow?, nil:\n                if job.adopt == nil, let reason = self.spaceBlock(job) {\n                    return .block(reason)\n                }\n                return .start(probe: false)\n            case .probe?:\n                break\n            }\n")],
        "barrierAdmitsAVisitsPlaceOnTheLiveThrottle|barrierAdmitsTheFollowsNewContentAsAtTheApply|barrierAdmitsARequestOnTheBreakerAtItsArrival"),
    # UNDECIDED-LANE (finding 12): no throttle on arrival when no own interest keeps an id and no Retry-After.
    "undecidedBack": (E + "EngineFailures.swift", [(
        "                self.state.throttles[origin] = max(decided ?? .zero, until)\n                self.state.metrics.retries[.throttled] += 1\n                self.throttleExtended(from: decided)\n                decision = .until(until)\n",
        "                if self.followedLane(job) != nil || seconds != nil {\n                    self.state.throttles[origin] = max(decided ?? .zero, until)\n                }\n                self.state.metrics.retries[.throttled] += 1\n                self.throttleExtended(from: decided)\n                decision = .until(until)\n")],
        "barrierThrottlesOnArrivalWhenTheVisitsMoveEveryID"),
    # R-C (findings 3/15): the sweep is judged only by its follow-up after the barrier, as at 3f10eaa.
    "spaceSweepNow": (E + "EngineJobs.swift", [(
        "                self.deferToFollow(.spaceSweep(sweep))\n", "")],
        "barrierGivesTheRoomToTheSweepsJobBeforeALaterRequest"),
    # Finding 5's readmit row.
    "readmitNow": (E + "EngineReadmission.swift", [(
        "        if self.defersToFollow {\n            self.deferToFollow(.readmit(passes))\n",
        "        if false {\n            self.deferToFollow(.readmit(passes))\n")],
        "barrierReadmitsBehindTheOwedVisitsPlaces"),
    # Finding 1's retryDueNow kill to keep.
    "retryDueNow": (E + "EngineTimers.swift", [(
        "                if self.defersToFollow {\n                    // The backoff's end is the clock's",
        "                if false {\n                    // The backoff's end is the clock's")],
        "barrierRetriesBehindTheOwedVisitsPlaces"),
    # S3-R16 1(e): the older verdict deferrals that stay (not in the cycle-13 table).
    "retryVerdictNow": (E + "EngineFailures.swift", [(
        "        if self.defersFailure(transfer, .retry(error, answer: answer)) {",
        "        if false, self.defersFailure(transfer, .retry(error, answer: answer)) {")],
        "EngineFollowBarrierTests"),
    "offlineVerdictNow": (E + "EngineFailures.swift", [(
        "            if self.defersFailure(transfer, .offline(requeue: retryNow)) {",
        "            if false, self.defersFailure(transfer, .offline(requeue: retryNow)) {")],
        "EngineFollowBarrierTests"),
    "throttleVerdictNow": (E + "EngineFailures.swift", [(
        "            if self.defersFailure(transfer, .throttle(ThrottleFacts(retryAfter: seconds, decision: decision))) {",
        "            if false, self.defersFailure(transfer, .throttle(ThrottleFacts(retryAfter: seconds, decision: decision))) {")],
        "EngineFollowBarrierTests"),
    "pauseVerdictNow": (E + "EngineFailures.swift", [(
        "        if self.defersFailure(transfer, .pause(policy: policyPause != nil, blocks: blocks)) {",
        "        if false, self.defersFailure(transfer, .pause(policy: policyPause != nil, blocks: blocks)) {")],
        "EngineFollowBarrierTests"),
}

def run(cmd, log):
    with open(log, "w") as f:
        f.write("$ " + " ".join(cmd) + "\n")
        f.flush()
        t = time.time()
        p = subprocess.run(cmd, cwd=SRC, stdout=f, stderr=subprocess.STDOUT)
        f.write("\nEXIT %d after %.1f s\n" % (p.returncode, time.time() - t))
    return p.returncode

def summary(log):
    out = []
    for line in open(log, errors="replace"):
        if ("Test run with" in line or "recorded an issue" in line or "Expectation failed" in line
                or "Time limit was exceeded" in line or line.startswith("EXIT")):
            out.append(line.rstrip()[:300])
    return out

names = sys.argv[1:] or list(MUTANTS)
for name in names:
    path, edits, flt = MUTANTS[name]
    full = os.path.join(SRC, path)
    orig = open(full).read()
    text = orig
    ok = True
    for old, new in edits:
        if text.count(old) != 1:
            print("MUTANT %s: edit count %d, skipped" % (name, text.count(old)), flush=True)
            ok = False
            break
        text = text.replace(old, new)
    if not ok:
        continue
    open(full, "w").write(text)
    try:
        b = run(["swift", "build", "--build-tests", "--scratch-path", BUILD], os.path.join(LOGS, name + "-build.log"))
        print("MUTANT %s: build exit %d" % (name, b), flush=True)
        if b == 0:
            for i in (1, 2):
                log = os.path.join(LOGS, "%s-run%d.log" % (name, i))
                run(["swift", "test", "--skip-build", "--scratch-path", BUILD, "--filter", flt], log)
                for s in summary(log):
                    print("MUTANT %s run%d: %s" % (name, i, s), flush=True)
    finally:
        open(full, "w").write(orig)
        print("MUTANT %s: reverted" % name, flush=True)
