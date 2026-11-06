#!/usr/bin/env python3
"""Applies named mutants to the scratch copy (mut/src); 'revert' restores Sources/ZTronAssetSync from the worktree.
s3f close-out verification, cycle 3, requirements lens (scratch, never committed)."""
import shutil
import sys
from pathlib import Path

WT = Path(__file__).resolve().parents[2]
SRC = Path(__file__).resolve().parent / "src"
E = "Sources/ZTronAssetSync/Engine/"

JOIN = "        // Join every owned task: tasks that end during the loop remove themselves; the loop iterates a copy.\n"
CLOSE_LATE = ("        if self.state.launch != nil || self.state.startTask != nil {\n"
              "            // The order R-SYN-15 rests on (ADR-039): every owned task was joined above.\n"
              "            // REENTRANCY: RE-S22 — terminal: every owned task is joined, so no store call is in flight.\n"
              "            await self.closeStore()\n"
              "        }\n")

# name -> list of (file, old, new, which): which = 'all' or an occurrence index (0-based)
MUTANTS = {
    # --- cycle-2 requirements-lens test-strength items ---
    "noyield": [(E + "EngineShutdown.swift", "                await Task.yield()\n", "", "all")],
    "nochunk": [(E + "EngineShutdown.swift", "if steps == SyncEngine.shutdownStepsPerTurn {", "if steps == Int.max {", "all")],
    # close moved alone before the joins; the mark (closeStore) stays after them
    "m5closeonly": [(E + "EngineLifecycle.swift", JOIN,
                     "        if self.state.launch != nil || self.state.startTask != nil { await self.store.close() }\n" + JOIN, 0)],
    # mark and close (closeStore) moved before the joins
    "m5": [(E + "EngineLifecycle.swift", JOIN,
            "        if self.state.launch != nil || self.state.startTask != nil { await self.closeStore() }\n" + JOIN, 0),
           (E + "EngineLifecycle.swift", CLOSE_LATE, "", 0)],
    "m6": [(E + "EngineLifecycle.swift",
            "        while let key = self.state.tasks.keys.min(), let task = self.state.tasks[key] {\n",
            "        while false, let key = self.state.tasks.keys.min(), let task = self.state.tasks[key] {\n", 0)],
    "r3cancel": [(E + "EngineFailures.swift", "            // Not a failure (T7/T13): a cancel the engine did not ask for re-queues the job.\n            self.requeue(transfer, discarding: request)",
                  "            self.retryLater(transfer, error: .transient(.unknown(urlErrorCode: 0), retryAfter: nil))", 0)],
    "r5budget": [(E + "EngineCommands.swift", "            if expired() {", "            if expired(), false {", 1)],
    "r2split": [(E + "EngineDispatch.swift", "        case .unknownAsset, .notPresent:\n            self.transition(transfer, to: .failed(.untilEntryChanges))\n            self.resolveAll(transfer, with: .failed(.notFound))\n        case .assetFailed, .unverifiedRejected:",
                 "        case .unknownAsset, .notPresent, .assetFailed:\n            self.transition(transfer, to: .failed(.untilEntryChanges))\n            self.resolveAll(transfer, with: .failed(.notFound))\n        case .unverifiedRejected:", 0)],
    # --- the blocking fix (cycle-2 correctness lens), removed piece by piece ---
    "noResolveAllHook": [(E + "EngineJobs.swift", "        if case .failed = outcome, self.followBeforeActing(transfer) {\n            return\n        }\n", "", 0)],
    "noCountHook": [(E + "EngineFailures.swift", "guard !self.followBeforeActing(transfer), var job = self.state.jobs[transfer] else {", "guard var job = self.state.jobs[transfer] else {", 0)],
    "noSpaceHook": [(E + "EngineFailures.swift", "self.state.jobs[transfer]?.epoch == epoch, !self.followBeforeActing(transfer), let job", "self.state.jobs[transfer]?.epoch == epoch, let job", 0)],
    "noDispatchStall": [(E + "EngineDispatch.swift", "        if let job = self.state.jobs[transfer], self.awaitsFollow(job) {\n", "        if false, let job = self.state.jobs[transfer], self.awaitsFollow(job) {\n", 0)],
    "listedOnlyAtDispatch": [(E + "EngineDispatch.swift", "        if let job = self.state.jobs[transfer], self.awaitsFollow(job) {\n", "        if let job = self.state.jobs[transfer], self.holdsMovedID(job) {\n", 0)],
    "userHeadCounted": [(E + "EngineDispatch.swift", "found = ready.map { entry in self.state.jobs[entry.transfer].map { !self.awaitsFollow($0) } ?? true } ?? false", "found = ready != nil", 0)],
    "owedVisitsOnly": [(E + "EngineFollow.swift", "        return job.assets.contains { asset in\n            self.state.applied.entry(for: asset).map { $0.transferID != job.transfer } ?? false\n        }",
                        "        return self.state.unfollowed.contains(job.transfer) && job.assets.contains { asset in\n            self.state.applied.entry(for: asset).map { $0.transferID != job.transfer } ?? false\n        }", 0)],
}
MUTANTS["noFlagPump"] = [(E + "EngineFollow.swift", "if moved || self.state.pumpWaitsForFollow {", "if moved {", "all")]
MUTANTS["noDispatchOwedFlag"] = [(E + "EngineRuns.swift", "|| !self.state.originOwed.isEmpty || self.state.pumpWaitsForFollow", "|| !self.state.originOwed.isEmpty", 0)]
MUTANTS["noFix"] = MUTANTS["noResolveAllHook"] + MUTANTS["noCountHook"] + MUTANTS["noSpaceHook"] + MUTANTS["noDispatchStall"]


def revert():
    shutil.rmtree(SRC / "Sources/ZTronAssetSync")
    shutil.copytree(WT / "Sources/ZTronAssetSync", SRC / "Sources/ZTronAssetSync")


def apply(name):
    for rel, old, new, which in MUTANTS[name]:
        path = SRC / rel
        text = path.read_text()
        n = text.count(old)
        if n == 0:
            sys.exit(f"MUTANT {name}: not found in {rel}: {old[:70]!r}")
        if which == "all":
            text = text.replace(old, new)
        else:
            idx = -1
            for _ in range(which + 1):
                idx = text.index(old, idx + 1)
            text = text[:idx] + new + text[idx + len(old):]
        path.write_text(text)
        print(f"MUTANT {name}: {rel} ({n} match(es), applied {which})")


if __name__ == "__main__":
    revert()
    if sys.argv[1] != "revert":
        for name in sys.argv[1:]:
            apply(name)
