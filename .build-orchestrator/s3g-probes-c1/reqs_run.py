#!/usr/bin/env python3
"""Mutant runner for the s3g close-out verification (scratch only).

Applies one mutant at a time to the scratch copy `pkg/`, builds the tests into `build/`, runs a filtered test with a
wall-clock timeout, records the summary lines, and restores the file. Usage: run.py <mutant-id> [<mutant-id> ...]
"""
import os
import pathlib
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
PKG = HERE / "pkg"
BUILD = HERE / "build"
LOGS = HERE / "logs"
LOGS.mkdir(exist_ok=True)

PREFETCH = "Sources/ZTronAssetKit/Prefetch/Prefetch.swift"
CLIENT = "Sources/ZTronAssetKit/Facade/AssetClient.swift"
FORWARDER = "Sources/ZTronAssetKit/Facade/EventForwarder.swift"

NEW_WALK = """        let reach = PrefetchWindow.reach(count: ids.count, current: current, radius: radius)
        var distance = 1
        while distance <= reach {
            visit(current + distance, at: distance)
            visit(current - distance, at: distance)
            distance += 1
        }"""
# s3-base's walk, verbatim (the original S3-PERF-06 defect); `visit` and `reach` stay so the tests compile.
OLD_WALK = """        let reach = max(radius, 0)
        var distance = 1
        while distance <= reach {
            for index in [current + distance, current - distance] where ids.indices.contains(index) {
                let id = ids[index]
                if seen.insert(id).inserted {
                    result.append(PrefetchTarget(id: id, priority: .prefetch, distance: distance))
                }
            }
            distance += 1
        }"""

FORWARDER_EXIT = """                guard !self.finished else {
                    if let key = registration.key {
                        // REENTRANCY: g-7 (proposed) — nothing: terminal for this forwarder.
                        await self.lifecycle.unfollow(key)
                    }
                    return nil
                }
"""

SYNC_HANDOFF = "if case .failed(let error) = outcome, error == .shutDown || AssetClient.mayStemFromFileSystem(error) {"

PUMP_HEAD = """        var pending = first
        var ended: UInt64?"""
PUMP_OFFER = """                guard await forwarder.offer(event) else {"""

REFUSAL = """        if reopensVanishedRootFirst, await core.store.unavailableReason == .rootVanished {
            // The root vanished again after every reopen allowed: the failure is reported, never a lease under it.
            throw .storageUnavailable(.rootVanished)
        }
"""


def drop_in_registration_generation(case: str) -> list:
    return [
        (FORWARDER, PUMP_HEAD, "        let registrationGeneration = first?.generation\n" + PUMP_HEAD),
        (FORWARDER, PUMP_OFFER,
         f"                if case .{case} = event, source.generation == registrationGeneration {{ continue }}\n" + PUMP_OFFER),
    ]


MUTANTS = {
    # S3G-1: the original defect (s3-base's unclamped walk in `targets`), helper left correct.
    "O1": ([(PREFETCH, NEW_WALK, OLD_WALK)], "hugeRadiusWalksOnlyTheCarousel", 300),
    # S3G-1: the helper unclamped (the fixer's MC1).
    "MC1": ([(PREFETCH, "min(max(radius, 0), max(current, count - 1 - current))", "max(radius, 0)")],
            "hugeRadiusWalksOnlyTheCarousel", 300),
    # S3G-1: an off-by-one clamp to the nearer side (would drop pages from the far side).
    "MC2": ([(PREFETCH, "min(max(radius, 0), max(current, count - 1 - current))",
              "min(max(radius, 0), min(current, count - 1 - current))")], "hugeRadiusWalksOnlyTheCarousel", 300),
    # S3G-2 (1): M05, the stopped-registration exit removed.
    "M05": ([(FORWARDER, FORWARDER_EXIT, "")], "FacadeRaceTests", 600),
    # S3G-2 (3): M01s, sync's hand-off narrowed to .shutDown and .storageUnavailable.
    "M01s": ([(CLIENT, SYNC_HANDOFF,
               "if case .failed(let error) = outcome, error == .shutDown || { if case .storageUnavailable = error { return true } else { return false } }() {")],
             "forcedSyncFileSystemFailureOnHealthyRoot", 300),
    # S3G-2 (3): only .insufficientSpace dropped from sync's hand-off.
    "M01i": ([(CLIENT, SYNC_HANDOFF,
               "if case .failed(let error) = outcome, error == .shutDown || (AssetClient.mayStemFromFileSystem(error) && { if case .insufficientSpace = error { return false } else { return true } }()) {")],
             "forcedSyncFileSystemFailureOnHealthyRoot", 300),
    # S3G-2 (2): the forwarder drops events of its registration generation.
    "MT1": (drop_in_registration_generation("clientStarted"), "EventContinuityModelTests", 900),
    "MT2": (drop_in_registration_generation("maintenanceFinished"), "EventContinuityModelTests", 900),
    "MT3": (drop_in_registration_generation("syncFinished"), "EventContinuityModelTests", 900),
    # S3G-3: the reopen limit changed, and the post-loop refusal removed.
    "MR4": ([(CLIENT, "static let reopenAttempts = 3", "static let reopenAttempts = 4")], "FacadeReopenLimitTests", 600),
    "MR2": ([(CLIENT, "static let reopenAttempts = 3", "static let reopenAttempts = 2")], "FacadeReopenLimitTests", 600),
    "MW": ([(CLIENT, REFUSAL, "")], "FacadeReopenLimitTests", 600),
    # Control: no mutation.
    "NONE": ([], "hugeRadiusWalksOnlyTheCarousel|stoppedRegistrationStartsNoPump|forcedSyncFileSystemFailureOnHealthyRoot|FacadeReopenLimitTests", 600),
}


def run(cmd, log, timeout):
    start = time.time()
    with open(log, "w") as out:
        out.write(f"$ {' '.join(cmd)}\nload {os.getloadavg()}\n")
        out.flush()
        try:
            proc = subprocess.run(cmd, cwd=PKG, stdout=out, stderr=subprocess.STDOUT, timeout=timeout)
            code = proc.returncode
        except subprocess.TimeoutExpired:
            code = "TIMEOUT"
        out.write(f"\n== exit {code} after {time.time() - start:.1f} s, load {os.getloadavg()}\n")
    return code


def summary(log):
    keep = []
    for line in open(log, errors="replace"):
        if ("✘" in line or "error:" in line or "Test run with" in line or line.startswith("== exit")
                or "Expectation failed" in line or "Issue recorded" in line):
            keep.append(line.rstrip()[:400])
    return keep


def main():
    for name in sys.argv[1:]:
        edits, test_filter, timeout = MUTANTS[name]
        originals = {}
        try:
            for path, old, new in edits:
                file = PKG / path
                text = originals.setdefault(path, file.read_text())
                current = file.read_text()
                assert current.count(old) == 1, f"{name}: anchor not unique in {path}: {current.count(old)}"
                file.write_text(current.replace(old, new))
            build = run(["swift", "build", "--build-tests", "--scratch-path", str(BUILD)], LOGS / f"{name}-build.log", 3600)
            print(f"== {name} build exit {build}")
            if build != 0:
                print("\n".join(summary(LOGS / f"{name}-build.log")[-15:]))
                continue
            code = run(["swift", "test", "--skip-build", "--scratch-path", str(BUILD), "--filter", test_filter],
                       LOGS / f"{name}-test.log", timeout)
            print(f"== {name} test exit {code}")
            print("\n".join(summary(LOGS / f"{name}-test.log")[-14:]))
        finally:
            for path, text in originals.items():
                (PKG / path).write_text(text)
        sys.stdout.flush()


if __name__ == "__main__":
    main()
