#!/usr/bin/env python3
"""Requirements-lens verifier: re-apply each original defect as a mutant in the scratch copy, rebuild, run the tests
that should catch it, and restore the file. Scratch only; never touches the worktree's tracked files."""
import os
import re
import subprocess
import sys

R = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.join(R, "mut", "pkg")
SCRATCH = os.path.join(R, "mut", "scratch")
LOGS = os.path.join(R, "logs")

MUTANTS = {
    "M1-claims-removeInterest": (
        "Sources/ZTronAssetSync/Engine/EngineJobs.swift",
        "            if self.state.claims[key] != nil {\n                // Kept for the claim",
        "            if false && self.state.claims[key] != nil {\n                // Kept for the claim",
        "EngineGroupClaimTests|PrefetchFacadeTests",
    ),
    "M2-created-shutdown": (
        "Sources/ZTronAssetSync/Engine/EngineLifecycle.swift",
        "        case .created, .starting, .running, .degraded:\n            break\n        }\n        self.state.lifecycle = .shuttingDown\n",
        "        case .created:\n            self.state.lifecycle = .shuttingDown\n            self.finishShutdown()\n            return\n        case .starting, .running, .degraded:\n            break\n        }\n        self.state.lifecycle = .shuttingDown\n",
        "EngineCreatedShutdownTests|FacadeLifecycleTests/registerBeforeStartThenShutdown|FacadeRaceTests/shutdownBeforeReplacementStart",
    ),
    "M3-no-handover": (
        "Sources/ZTronAssetKit/Facade/ClientLifecycle.swift",
        "        await self.handOverFollowers(to: next)\n",
        "        _ = next\n",
        "FacadeReopenTests/(consumerReceivesTheReplacementsClientStarted|terminalEventDuringTheReopenReachesTheConsumer)",
    ),
    "M4a-no-reopen-first": (
        "Sources/ZTronAssetKit/Facade/AssetClient.swift",
        "        for _ in 0..<AssetClient.reopenAttempts {\n            if reopensVanishedRootFirst, await core.store.unavailableReason == .rootVanished {",
        "        for _ in 0..<AssetClient.reopenAttempts {\n            if false, reopensVanishedRootFirst, await core.store.unavailableReason == .rootVanished {",
        "FacadeReopenTests/withAssetAfterReplacedRootLeasesFromReplacement",
    ),
    "M4b-no-post-failure-read": (
        "Sources/ZTronAssetKit/Facade/AssetClient.swift",
        "                if !vanished {\n                    vanished = await core.store.unavailableReason == .rootVanished\n                }\n",
        "",
        "FacadeReopenTests/syncAndEventsFollowReopen",
    ),
    "M5-store-read-nil": (
        "Sources/ZTronAssetStorage/Store/AssetStore.swift",
        "    package var unavailableReason: StorageUnavailableReason? {\n        self.state.core.unavailable\n    }",
        "    package var unavailableReason: StorageUnavailableReason? {\n        nil\n    }",
        "StoreUnavailableReasonTests",
    ),
    "M6-followup-running-only": (
        "Sources/ZTronAssetSync/Engine/EngineCommands.swift",
        "        guard !self.isShuttingDown, self.continueReleases() else {",
        "        guard self.isRunning, self.continueReleases() else {",
        "EngineGroupClaimTests/largeGroupReleasedBeforeStart|EngineCreatedShutdownTests/releaseFollowUpSpawnedInCreated",
    ),
    "M9-no-claimNewlyListed": (
        "Sources/ZTronAssetSync/Engine/EngineJobs.swift",
        "        self.claimNewlyListed()\n",
        "",
        "EngineGroupClaimTests/claimsRecordedBeforeStart",
    ),
    "M10-dropClaim-no-retire": (
        "Sources/ZTronAssetSync/Engine/EngineCommands.swift",
        "        if let transfer = self.state.claimHeld.removeValue(forKey: key), self.state.jobs[transfer]?.interests.isEmpty == true {\n            self.retire(transfer)\n        }",
        "        if let transfer = self.state.claimHeld.removeValue(forKey: key), self.state.jobs[transfer]?.interests.isEmpty == true {\n            _ = transfer\n        }",
        "EngineGroupClaimTests",
    ),
    "M12-no-heldLane": (
        "Sources/ZTronAssetSync/Engine/EngineJobs.swift",
        "        if job.interests.isEmpty {\n            job.heldLane = before\n        }\n",
        "",
        "EngineGroupClaimTests|PrefetchFacadeTests",
    ),
    "M11-endClaims-noop": (
        "Sources/ZTronAssetSync/Engine/EngineCommands.swift",
        "    private func endClaims(of token: InterestToken) {\n        guard let group",
        "    private func endClaims(of token: InterestToken) {\n        if token.rawValue >= 0 { return }\n        guard let group",
        "ZTronAssetSyncTests",
    ),
}


def run(cmd, log):
    with open(log, "w") as out:
        return subprocess.run(cmd, cwd=PKG, stdout=out, stderr=subprocess.STDOUT).returncode


def summary(log):
    lines = []
    with open(log, errors="replace") as handle:
        for line in handle:
            if re.search(r"✘ Test .* (failed|recorded an issue)|Test run with|error:", line):
                lines.append(line.rstrip()[:300])
    return lines


def main(names):
    for name in names:
        path, old, new, filt = MUTANTS[name]
        full = os.path.join(PKG, path)
        original = open(full).read()
        count = original.count(old)
        if count != 1:
            print(f"=== {name}: pattern occurs {count} times, skipped")
            continue
        open(full, "w").write(original.replace(old, new))
        try:
            build_log = os.path.join(LOGS, f"mut-{name}-build.log")
            code = run(["swift", "build", "--build-tests", "--scratch-path", SCRATCH], build_log)
            if code != 0:
                print(f"=== {name}: BUILD FAILED")
                for line in summary(build_log)[:10]:
                    print("   ", line)
                continue
            test_log = os.path.join(LOGS, f"mut-{name}-test.log")
            code = run(["swift", "test", "--skip-build", "--scratch-path", SCRATCH, "--filter", filt], test_log)
            lines = summary(test_log)
            failed = [line for line in lines if line.startswith("✘ Test") and "failed after" in line]
            print(f"=== {name}: test exit={code}, failing tests={len(failed)} (filter {filt})")
            for line in lines:
                if "Test run with" in line or ("✘ Test" in line and "failed after" in line):
                    print("   ", line)
        finally:
            open(full, "w").write(original)


if __name__ == "__main__":
    main(sys.argv[1:] or list(MUTANTS))
