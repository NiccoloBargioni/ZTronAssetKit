import Foundation
import ZTronAssetModel

/// Commit scheduling and the commit unit (R-STO-4, I-5, P-5; ARCHITECTURE §4.1, ADR-015; WP-B).
///
/// Mutations are counted (`markDirty`); a commit captures the whole state synchronously (copy-on-write) with a
/// generation allocated at capture, runs one metadata unit, and covers every mutation counted before the capture.
/// At most one commit runs at a time, and commits start at most once per `commitMinimumInterval` (≤ 4/s): a caller
/// that needs a commit inside the window sleeps until it opens, and every caller waiting meanwhile shares the next
/// commit.
extension AssetStore {
    /// Counts a mutation; `.soon` makes the coalesced commit a deadline (`nextDeadline()`), `.lazy` rides along.
    func markDirtyInternal(_ urgency: DirtyUrgency) {
        self.state.core.commits.mutationSerial += 1
        if urgency == .soon {
            self.state.core.commits.soonSerial = self.state.core.commits.mutationSerial
        }
    }

    /// Returns once every mutation counted before the call is committed at `durability` (REENTRANCY R5). While
    /// `apply` writes its chunks (the commit fence, ADR draft B-23) it waits for all of them: a generation never
    /// holds a half-applied manifest.
    func requireCommittedInternal(_ durability: CommitDurability) async throws(StoreError) {
        try self.checkLive()
        let target = self.state.core.commits.mutationSerial
        while !self.state.core.commits.covers(target, durability) {
            try self.checkLive()
            try self.checkWritable()
            if self.state.core.applyGate.writing {
                // REENTRANCY: b-8 (proposed) — the loop re-reads coverage, the phase, the fence and the in-flight
                // flag once `apply`'s writes are complete.
                await self.waitForApplyWrites()
                continue
            }
            if self.state.core.commits.inFlight {
                // REENTRANCY: R5 — the loop re-reads coverage, the phase and the in-flight flag after the running
                // commit finished (successfully or not).
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.state.core.commits.waiters.append(continuation)
                }
                continue
            }
            if let opens = self.commitWindowOpens(), self.environment.time.monotonicNow() < opens {
                do throws(CancellationError) {
                    // REENTRANCY: b-2 (proposed) — the timer only pokes: the loop recomputes coverage, the in-flight
                    // flag, the window and the phase from scratch (as R9 for purge's grace wait).
                    try await self.environment.time.sleep(until: opens)
                } catch {
                    throw .cancelled
                }
                continue
            }
            // REENTRANCY: R5 — the loop re-reads coverage, the window and the phase after the commit.
            try await self.commitNow(durability)
        }
    }

    /// When the coalescing window opens again, or `nil` when no commit was attempted yet.
    func commitWindowOpens() -> MonotonicInstant? {
        self.state.core.commits.lastAttemptAt.map { $0.adding(seconds: max(0, self.configuration.commitMinimumInterval)) }
    }

    /// Captures the state, allocates the generation, runs the commit unit and folds its result back
    /// (REENTRANCY R5). The caller ensured no commit is in flight.
    func commitNow(_ durability: CommitDurability) async throws(StoreError) {
        guard let layout = self.state.core.layout else {
            throw .notOpen
        }
        let generation = self.state.core.nextGeneration
        self.state.core.nextGeneration += 1
        let serial = self.state.core.commits.mutationSerial
        let fanOuts = self.state.core.commits.dirtyFanOuts
        let blobsDirty = self.state.core.commits.blobsDirectoryDirty
        let input = IndexCommitInput(
            layout: layout,
            content: self.captureContent(generation: generation),
            dirtyFanOuts: fanOuts.sorted(),
            blobsDirectoryDirty: blobsDirty,
            durability: durability,
            lock: self.state.core.lock,
            blobTable: self.state.core.blobTable,
            deletingDooms: self.state.core.deletingDooms,
            replacingDooms: self.state.core.replacingDooms,
            committedGeneration: self.state.core.committedGeneration,
            promotion: self.state.core.commits.pendingPromotion
        )
        self.state.core.commits.inFlight = true
        self.state.core.commits.dirtyFanOuts = []
        self.state.core.commits.blobsDirectoryDirty = false
        self.state.core.commits.lastAttemptAt = self.environment.time.monotonicNow()
        let fileSystem = self.environment.fileSystem
        let outcome: IndexCommitOutcome
        do {
            let interval = self.environment.log.interval(.commit, category: .store, "generation \(generation)")
            defer {
                interval.end()
            }
            // REENTRANCY: R5 — `committedGeneration = max(…)` with the generation allocated at capture; mutations made
            // meanwhile stay dirty (their serial is above `serial`); on failure the dirty directories are restored;
            // waiters are resumed either way; callers re-check the phase, so no new commit starts once closing.
            outcome = await self.runUnit(on: self.environment.metadataExecutor) {
                IndexCommitUnit.run(input, fileSystem: fileSystem)
            }
        }
        self.state.core.commits.inFlight = false
        if outcome.promotedName {
            // The loaded index.tmp is index.bin now, whether or not the rest of the unit succeeded (ADR draft B-28).
            self.state.core.commits.pendingPromotion = nil
        }
        if outcome.promotedDurably, let promoted = input.promotion {
            self.state.core.committedGeneration = max(self.state.core.committedGeneration, promoted)
        }
        switch outcome.result {
        case .success:
            self.state.core.committedGeneration = max(self.state.core.committedGeneration, generation)
            self.state.core.commits.committedSerial = max(self.state.core.commits.committedSerial, serial)
            if durability == .durable {
                self.state.core.commits.durableSerial = max(self.state.core.commits.durableSerial, serial)
            }
            self.state.core.metrics.commits += 1
            self.resumeCommitWaiters()
        case .failure(let error):
            self.state.core.commits.dirtyFanOuts.formUnion(fanOuts)
            self.state.core.commits.blobsDirectoryDirty = self.state.core.commits.blobsDirectoryDirty || blobsDirty
            self.state.core.metrics.commitFailures += 1
            if error == .storageUnavailable(.rootVanished) {
                self.state.core.unavailable = .rootVanished
            }
            let reason = AssetStore.describe(error)
            self.environment.log.log(.store, .error, "commit of generation \(generation) failed: \(reason)")
            self.resumeCommitWaiters()
            throw error
        }
    }

    /// The persisted state, captured synchronously (O(1) copies of the dictionaries). DOOMED is left empty here: the
    /// commit unit derives it from the blob table captured at the same instant (`IndexCommitInput.completeContent`,
    /// store-2 S2-04), off the actor.
    func captureContent(generation: UInt64) -> IndexContent {
        let core = self.state.core
        let millis = (self.environment.time.now().timeIntervalSince1970 * 1_000).rounded()
        return IndexContent(
            storeID: core.storeID,
            generation: generation,
            launchEpoch: core.launchEpoch,
            writtenAtMillis: millis.isFinite && abs(millis) < 9e18 ? Int64(millis) : 0,
            degraded: core.degraded,
            appliedManifest: core.appliedManifest,
            etag: core.etag,
            records: core.records,
            stamp: core.stamp,
            syncDue: core.syncDue,
            lastCleanupAt: self.state.cleanup.lastCleanupAt,
            legacyPhase: self.state.migration.phase,
            legacyStamp: self.state.migration.legacyStamp,
            doomed: [:]
        )
    }

    /// A store error rendered for a log line without any identifier or path (R-OBS-1): only the failures a commit or
    /// a publication logs are spelled out; every other case carries an identifier and renders as its class.
    static func describe(_ error: StoreError) -> String {
        switch error {
        case .fileSystem(let failure):
            return "fileSystem(\(String(describing: failure)))"
        case .storageUnavailable(let reason):
            return "storageUnavailable(\(String(describing: reason)))"
        case .integrity(.sizeMismatch):
            return "integrity(sizeMismatch)"
        case .integrity(.checksumMismatch):
            return "integrity(checksumMismatch)"
        case .integrity(.oversize):
            return "integrity(oversize)"
        default:
            return "storeError"
        }
    }
}
