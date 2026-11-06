#!/usr/bin/env python3
"""Cycle-11 reqs-lens verifier mutants: applied to the scratch export (src/), rebuilt in mbuild/, run twice, reverted."""
import os, subprocess, sys, pathlib
R = pathlib.Path("/Users/admin/Documents/ZTronAssetKit/.worktrees/s3f/.build-verify-s3f-c11-reqs")
SRC = R / "src"
E = "Sources/ZTronAssetSync/Engine/"
SKIP = "barrierHoldsAPendingRunBehindTheOwedPump"
MUTANTS = {
    "noReroute": ([(E + "EngineFollow.swift", "        if join.listed, self.state.applied.entry(for: join.asset)",
                    "        if false, join.listed, self.state.applied.entry(for: join.asset)", 1)],
                  "barrierReroutesAJoinALaterApplyMoved"),
    "relaneNoDefer": ([(E + "EngineJobs.swift", "                // (S3-R14 item 4).\n                return\n            }\n",
                        "                // (S3-R14 item 4).\n            }\n", 1)],
                      "EngineFollowBarrierTests"),
    "throttleAtNow": ([(E + "EngineFollow.swift", "answeredAt: facts.at, answerEnd: end)", "answeredAt: nil, answerEnd: nil)", 1)],
                      "barrierAnswersAThrottleParkWithItsOwnWait"),
    "alarmAtPark": ([(E + "EngineDispatch.swift", "self.state.heap.schedule(.throttle(origin), at: self.throttleEnd(after: until))",
                      "self.state.heap.schedule(.throttle(origin), at: until)", 1)],
                    "barrierAnswersAThrottleParkWithItsOwnWait"),
    "noFlagPump": ([(E + "EngineFollow.swift", "if moved || self.state.pumpWaitsForFollow {", "if moved {", 2)],
                   "barrierFillsAFreedSlotInTheFollowsLastTurn"),
    "condNow": ([(E + "EngineConditions.swift", "        if self.defersToFollow {\n            self.deferToFollow(.conditions(",
                  "        if false {\n            self.deferToFollow(.conditions(", 1)],
                "barrierPausesOnTheFollowedLane|barrierReadmitsAnEdgeInItsOwnOrder|probeC10RPolicyPause|pauseLane"),
    "pauseNow": ([(E + "EngineFailures.swift", "if self.defersFailure(transfer, .pause(", "if false, self.defersFailure(transfer, .pause(", 1)],
                 "barrierDecidesAPauseOnTheFollowedLane"),
    "throttleAnswersNow": ([(E + "EngineFailures.swift", "        if self.defersToFollow {\n            self.deferToFollow(.throttleAnswers)",
                             "        if false {\n            self.deferToFollow(.throttleAnswers)", 1)],
                           "barrierAnswersAThrottleExtensionOnTheFollowedState"),
    "readmitNow": ([(E + "EngineReadmission.swift", "        if self.defersToFollow {\n            self.deferToFollow(.readmit(",
                     "        if false {\n            self.deferToFollow(.readmit(", 1)],
                   "barrierPlacesAReadmissionAsTheFollowLeavesIt"),
    "removalNow": ([(E + "EngineJobs.swift", "        if self.defersToFollow {\n            self.deferToFollow(.removal(token, transfer))",
                     "        if false {\n            self.deferToFollow(.removal(token, transfer))", 1),
                    (E + "EngineCommands.swift", "            if self.defersToFollow, !waiter.fromStore {",
                     "            if false, !waiter.fromStore {", 1)],
                   "barrierAppliesAWithdrawalAfterTheVerdictItFollowed|joinRetire"),
    "joinNow": ([(E + "EngineJobs.swift", "        if self.defersToFollow {\n            let listed = ",
                  "        if false {\n            let listed = ", 1)],
                "barrierJoinsARequestToTheJobTheFollowCreates|doublePlace"),
    "throttleParkNow": ([(E + "EngineFailures.swift", "        if self.defersToFollow {\n            let decided = self.state.throttles[origin]",
                          "        if false {\n            let decided = self.state.throttles[origin]", 1)],
                        "barrierThrottlesForTheFollowedLane|throttleLane"),
}
ENV = dict(os.environ, TMPDIR=str(R / "tmp"), CLANG_MODULE_CACHE_PATH=str(R / "tmp/mc"), LLVM_PROFILE_FILE=str(R / "tmp/%p.profraw"))
LOGS = R / "mut"
LOGS.mkdir(exist_ok=True)


def run(name, runs=2):
    edits, flt = MUTANTS[name]
    originals = {}
    try:
        for rel, old, new, count in edits:
            path = SRC / rel
            current = path.read_text()
            originals.setdefault(rel, current)
            assert current.count(old) == count, f"{name}: {rel} has {current.count(old)} of the target, expected {count}"
            path.write_text(current.replace(old, new))
        log = LOGS / f"{name}-build.log"
        b = subprocess.run(["nice", "-n", "5", "swift", "build", "--build-tests", "--scratch-path", str(R / "mbuild")], cwd=SRC, env=ENV,
                           stdout=open(log, "w"), stderr=subprocess.STDOUT)
        print(f"MUTANT {name}: build exit {b.returncode}", flush=True)
        if b.returncode != 0:
            return
        for i in range(1, runs + 1):
            out = LOGS / f"{name}-run{i}.log"
            r = subprocess.run(["timeout", "1200", "swift", "test", "--skip-build", "--scratch-path", str(R / "mbuild"), "--filter", flt, "--skip", SKIP],
                               cwd=SRC, env=ENV, stdout=open(out, "w"), stderr=subprocess.STDOUT)
            lines = out.read_text().splitlines()
            summary = [l for l in lines if "Test run with" in l]
            issues = [l for l in lines if "recorded an issue" in l and "at " in l]
            print(f"MUTANT {name} run {i}: exit {r.returncode} :: {summary[-1] if summary else 'no summary'}", flush=True)
            for l in issues[:4]:
                print(f"    {l[:300]}", flush=True)
    finally:
        for rel, text in originals.items():
            (SRC / rel).write_text(text)
        d = subprocess.run(["bash", "-c", f"cd {R.parent} && git archive HEAD Sources | tar -x -O | md5; cat $(cd {SRC} && git -C {R.parent} ls-tree -r --name-only HEAD Sources | sed 's|^|{SRC}/|') | md5"],
                           capture_output=True, text=True).stdout.split()
        print(f"MUTANT {name}: reverted; Sources md5 HEAD={d[0] if d else '?'} scratch={d[1] if len(d) > 1 else '?'}", flush=True)


if __name__ == "__main__":
    for n in sys.argv[1:]:
        run(n)
