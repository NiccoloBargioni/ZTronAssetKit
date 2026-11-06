#!/usr/bin/env python3
"""Applies one named mutant to the scratch copy (mut/src); 'revert' restores Sources/ZTronAssetSync from the worktree."""
import shutil
import sys
from pathlib import Path

WT = Path(__file__).resolve().parents[2]
SRC = Path(__file__).resolve().parent / "src"
E = "Sources/ZTronAssetSync/Engine/"

# name -> list of (file, old, new, which): which = 'all' or an occurrence index (0-based)
MUTANTS = {
    "strand": [(E + "EngineDispatch.swift",
                "let update = terminal ?? .failed(.transient(.incompleteCallbackSequence, retryAfter: nil))",
                "guard let update = terminal else { return }", 0)],
    "nochunk": [(E + "EngineShutdown.swift", "if steps == SyncEngine.shutdownStepsPerTurn {", "if steps == Int.max {", "all")],
    "noyield": [(E + "EngineShutdown.swift", "                await Task.yield()\n", "", "all")],
    "firedue": [(E + "EngineTimers.swift", "self.state.heap.popDue(at: now, limit: Self.dueDeadlinesPerTurn)", "self.state.heap.popDue(at: now)", 0)],
    "eager": [(E + "EngineReadmission.swift", "if kind == .circuitOpen, self.breakerAdmitsOnlyProbe() {", "if kind == .circuitOpen, self.breakerAdmitsOnlyProbe(), kind != .circuitOpen {", 0),
              (E + "EngineOriginGate.swift", "if gate.breaker == .probe {", "if gate.breaker == .probe, gate.breaker != .probe {", 0)],
    "followall": [(E + "EngineFollow.swift", "while visited < Self.followsPerTurn, self.state.followNext", "while self.state.followNext", 0),
                  (E + "EngineFollow.swift", "while !self.state.followScans.isEmpty, compared < Self.followScansPerTurn, formatted < Self.followFormatsPerTurn {",
                   "while !self.state.followScans.isEmpty {", 0),
                  (E + "EngineFollow.swift", "while scan.next < entries.count, compared < Self.followScansPerTurn, formatted < Self.followFormatsPerTurn {",
                   "while scan.next < entries.count {", 0)],
    "settleguard": [(E + "EngineRuns.swift", "run.settlement == nil, !self.followOwed else {", "run.settlement == nil else {", 0)],
    "catchupguard": [(E + "EngineCatchUp.swift", "guard !self.state.heldForManifest.isEmpty, !self.followOwed else {", "guard !self.state.heldForManifest.isEmpty else {", 0)],
    "m6": [(E + "EngineLifecycle.swift",
            "        while let key = self.state.tasks.keys.min(), let task = self.state.tasks[key] {\n",
            "        while false, let key = self.state.tasks.keys.min(), let task = self.state.tasks[key] {\n", 0)],
    "m5closeonly": [(E + "EngineLifecycle.swift",
                     "        await self.settle(self.drainEverything(with: .shutDown), with: .shutDown)\n        // Join every owned task",
                     "        await self.settle(self.drainEverything(with: .shutDown), with: .shutDown)\n        if self.state.launch != nil || self.state.startTask != nil { await self.store.close() }\n        // Join every owned task", 0),
                    (E + "EngineLifecycle.swift", "            await self.store.close()\n        }\n        self.finishShutdown()",
                     "        }\n        self.finishShutdown()", 0)],
    "m5": [(E + "EngineLifecycle.swift",
            "        await self.settle(self.drainEverything(with: .shutDown), with: .shutDown)\n        // Join every owned task",
            "        await self.settle(self.drainEverything(with: .shutDown), with: .shutDown)\n        if self.state.launch != nil || self.state.startTask != nil { self.state.closingStore = true; self.notifyObservers(); await self.store.close() }\n        // Join every owned task", 0),
           (E + "EngineLifecycle.swift", "            self.state.closingStore = true\n            self.notifyObservers()\n            // REENTRANCY: RE-S22 — terminal: every owned task is joined, so no store call is in flight.\n            await self.store.close()\n        }\n        self.finishShutdown()",
            "        }\n        self.finishShutdown()", 0)],
    "r1unknown": [(E + "EngineDispatch.swift", "            self.resolveAll(transfer, with: .failed(.notFound))\n        case .assetFailed, .unverifiedRejected:",
                   "            self.resolveAll(transfer, with: .failed(.shutDown))\n        case .assetFailed, .unverifiedRejected:", 0)],
    "r2failed": [(E + "EngineDispatch.swift", "        case .assetFailed, .unverifiedRejected:\n            self.transition(transfer, to: .failed(.untilEntryChanges))\n            self.resolveAll(transfer, with: .failed(error.assetError))",
                  "        case .assetFailed, .unverifiedRejected:\n            self.transition(transfer, to: .failed(.untilEntryChanges))\n            self.resolveAll(transfer, with: .failed(.notFound))", 0)],
    "r3cancel": [(E + "EngineFailures.swift", "            // Not a failure (T7/T13): a cancel the engine did not ask for re-queues the job.\n            self.requeue(transfer, discarding: request)",
                  "            self.retryLater(transfer, error: .transient(.unknown(urlErrorCode: 0), retryAfter: nil))", 0)],
    "r4replay": [(E + "EngineEvents.swift", "                if let progress = self.state.progress.latestRun {\n                    replay(progress)",
                  "                if let progress = self.state.progress.latestRun, progress != progress {\n                    replay(progress)", 0)],
    "r5budget": [(E + "EngineCommands.swift", "            if expired() {", "            if expired(), false {", 1)],
    "r6throw": [(E + "EngineCommands.swift", "return .failure(self.isShuttingDown ? .shutDown : error.assetError)", "return .failure(.shutDown)", 2)],
    "r2split": [(E + "EngineDispatch.swift", "        case .unknownAsset, .notPresent:\n            self.transition(transfer, to: .failed(.untilEntryChanges))\n            self.resolveAll(transfer, with: .failed(.notFound))\n        case .assetFailed, .unverifiedRejected:",
                 "        case .unknownAsset, .notPresent, .assetFailed:\n            self.transition(transfer, to: .failed(.untilEntryChanges))\n            self.resolveAll(transfer, with: .failed(.notFound))\n        case .unverifiedRejected:", 0)],
}


def revert():
    shutil.rmtree(SRC / "Sources/ZTronAssetSync")
    shutil.copytree(WT / "Sources/ZTronAssetSync", SRC / "Sources/ZTronAssetSync")


def apply(name):
    for rel, old, new, which in MUTANTS[name]:
        path = SRC / rel
        text = path.read_text()
        n = text.count(old)
        if n == 0:
            sys.exit(f"MUTANT {name}: not found in {rel}: {old[:60]!r}")
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
