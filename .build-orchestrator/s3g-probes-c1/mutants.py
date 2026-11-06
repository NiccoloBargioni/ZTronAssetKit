#!/usr/bin/env python3
"""Verifier mutant runner (s3g close-out cycle 1, correctness lens). Applies one mutant at a time to the probe copy,
runs the named tests against the probe copy's own scratch path, records the summary lines, and restores the file."""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.join(HERE, "probe-pkg")
SCRATCH = os.path.join(HERE, "probe-build")
LOGS = os.path.join(HERE, "mutant-logs")
os.makedirs(LOGS, exist_ok=True)

EF = "Sources/ZTronAssetKit/Facade/EventForwarder.swift"
AC = "Sources/ZTronAssetKit/Facade/AssetClient.swift"
PF = "Sources/ZTronAssetKit/Prefetch/Prefetch.swift"

M05_OLD = """                guard !self.finished else {
                    if let key = registration.key {
                        // REENTRANCY: g-7 (proposed) — nothing: terminal for this forwarder.
                        await self.lifecycle.unfollow(key)
                    }
                    return nil
                }
"""

FWD_OLD = """            let source: (stream: AsyncStream<AssetEvent>, generation: UInt64)
            if let given = pending {
                source = given
                pending = nil
            } else {"""
FWD_NEW = """            let source: (stream: AsyncStream<AssetEvent>, generation: UInt64)
            var fromFirst = false
            if let given = pending {
                source = given
                pending = nil
                fromFirst = true
            } else {"""
OFFER_OLD = """                guard await forwarder.offer(event) else {"""

MUTANTS = {
    "MC1": [(PF, "min(max(radius, 0), max(current, count - 1 - current))", "max(radius, 0)")],
    "M05": [(EF, M05_OLD, "")],
    "M01s": [(AC, "error == .shutDown || AssetClient.mayStemFromFileSystem(error)",
              "error == .shutDown || { if case .storageUnavailable = error { return true }; return false }()")],
    "RA4": [(AC, "static let reopenAttempts = 3", "static let reopenAttempts = 4")],
    "RA2": [(AC, "static let reopenAttempts = 3", "static let reopenAttempts = 2")],
    "MT1": [(EF, FWD_OLD, FWD_NEW),
            (EF, OFFER_OLD, "                if fromFirst, case .clientStarted = event { continue }\n" + OFFER_OLD)],
    "MT2": [(EF, FWD_OLD, FWD_NEW),
            (EF, OFFER_OLD, "                if fromFirst, case .maintenanceFinished = event { continue }\n" + OFFER_OLD)],
}

FILTERS = {
    "MC1": "hugeRadiusWalksOnlyTheCarousel",
    "M05": "stoppedRegistrationStartsNoPump|eventsStreamCancelledDuringItsRegistration",
    "M01s": "forcedSyncFileSystemFailureOnHealthyRoot",
    "RA4": "FacadeReopenLimitTests",
    "RA2": "FacadeReopenLimitTests",
    "MT1": "eventContinuityModel",
    "MT2": "eventContinuityModel",
}


def run(name):
    originals = {}
    try:
        for path, old, new in MUTANTS[name]:
            full = os.path.join(PKG, path)
            text = originals.get(full) or open(full).read()
            originals.setdefault(full, text)
            current = open(full).read()
            if current.count(old) != 1:
                print(f"{name}: pattern not unique in {path} ({current.count(old)})")
                return
            open(full, "w").write(current.replace(old, new))
        env = dict(os.environ, TMPDIR=os.path.join(HERE, "tmp"))
        log = os.path.join(LOGS, f"{name}.log")
        with open(log, "w") as handle:
            proc = subprocess.run(
                ["swift", "test", "--scratch-path", SCRATCH, "--skip", "Benchmarks", "--filter", FILTERS[name]],
                cwd=PKG, env=env, stdout=handle, stderr=subprocess.STDOUT, timeout=1500)
        lines = [l.rstrip() for l in open(log) if ("✘" in l or "✔ Test run" in l or "Expectation failed" in l
                                                    or "error:" in l or "Issue recorded" in l)]
        print(f"=== {name}: exit {proc.returncode}")
        for line in lines[:8]:
            print("   ", line[:400])
    finally:
        for full, text in originals.items():
            open(full, "w").write(text)


if __name__ == "__main__":
    for name in sys.argv[1:]:
        run(name)
