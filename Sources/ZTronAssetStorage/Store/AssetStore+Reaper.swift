import Foundation
import ZTronAssetModel

/// The I-3 deletion protocol and the engine-driven deadlines (H-2; ARCHITECTURE §4.4; ADR-016, ADR-017, ADR-022;
/// WP-B).
///
/// `deletable(k)` ⇔ `k` is doomed ∧ an acknowledged snapshot of this epoch lacks it (its grace started:
/// `eligibleAt` is set) ∧ the grace passed on the awake clock **before** an install whose acknowledgement came back
/// (the fresh acknowledgement) ∧ the generation that dropped it is committed ∧ no lease ∧ no publication of it in
/// flight ∧ the store is not degraded (store-1 S1-11) ∧ its root was not replaced (ADR draft B-15). "No publication
/// in flight" needs no check of its own: a key in `publishing` is never doomed, because `acquireReference` makes a
/// rescued or replaced key live synchronously, before any await, and a new key enters the blob table only when its
/// placement finished. The store owns no task: `nextDeadline()` reports only what time alone unblocks, and the
/// engine's alarm calls `runDueWork()`.
extension AssetStore {
    /// Why a doomed key cannot be deleted yet (or that it can).
    enum DeletionBlocker: Sendable, Hashable {
        /// Deletable now.
        case none
        /// Not doomed (live, being deleted, or unknown).
        case notDoomed
        /// The store is degraded: every deletion waits for the next `apply` (store-1 S1-11).
        case degraded
        /// The root was replaced or vanished (ADR draft B-15): the path may now belong to another store, so nothing
        /// under it is deleted any more.
        case unavailable
        /// No acknowledged snapshot of this epoch lacks it yet.
        case acknowledgement
        /// The generation that dropped it is not committed yet.
        case commit
        /// A lease holds it.
        case lease
        /// Its awake-clock grace ends at this instant.
        case grace(MonotonicInstant)
        /// The grace ended, but no install has been acknowledged since (ADR-017). `unanswered` when an install
        /// started after the grace already came back unacknowledged: the key then keeps no deadline (store-1 S1-13),
        /// and the next `runDueWork()` or acknowledged install retries.
        case freshAcknowledgement(unanswered: Bool)
    }

    /// The first condition that keeps `key` from being deleted now.
    func deletionBlocker(_ key: BlobKey) -> DeletionBlocker {
        guard case .doomed(let info)? = self.state.core.blobTable[key] else {
            return .notDoomed
        }
        if self.state.core.unavailable != nil {
            return .unavailable
        }
        if self.state.core.degraded {
            return .degraded
        }
        guard let eligibleAt = info.eligibleAt else {
            return .acknowledgement
        }
        if self.state.core.committedGeneration < info.droppedInGeneration {
            return .commit
        }
        if let leases = self.state.cleanup.leases[key], !leases.isEmpty {
            return .lease
        }
        if eligibleAt > self.environment.time.uptimeNow() {
            return .grace(eligibleAt)
        }
        guard let fresh = self.state.core.snapshots.lastAcknowledgedInstallStart, fresh >= eligibleAt else {
            let attempted = self.state.core.snapshots.lastInstallStart.map { $0 >= eligibleAt } ?? false
            return .freshAcknowledgement(unanswered: attempted)
        }
        return .none
    }

    /// `nextDeadline()`: the earliest instant at which time alone gives `runDueWork()` something to do.
    func nextDeadlineInternal() -> MonotonicInstant? {
        guard self.state.core.phase == .open else {
            return nil
        }
        let now = self.environment.time.monotonicNow()
        var deadline: MonotonicInstant?
        func consider(_ instant: MonotonicInstant) {
            deadline = deadline.map { min($0, instant) } ?? instant
        }
        let commits = self.state.core.commits
        // While `apply` writes behind the commit fence its own commit, right after the last write, covers every
        // pending mutation; reporting the window would only make the alarm spin (ADR draft B-23).
        if commits.soonPending, !commits.inFlight, self.state.core.unavailable == nil, !self.state.core.applyGate.writing {
            consider(self.scheduledCommitOpens() ?? now)
        }
        if self.state.core.snapshots.installDue {
            consider(self.installWindowOpens() ?? now)
        }
        let uptime = self.environment.time.uptimeNow()
        for key in self.state.core.blobTable.keys {
            switch self.deletionBlocker(key) {
            case .none, .freshAcknowledgement(unanswered: false):
                consider(now)
            case .grace(let eligibleAt):
                // The grace runs on the awake clock; the alarm runs on the monotonic one. After a device sleep the
                // alarm fires early and `runDueWork()` reports the rest.
                consider(now.adding(seconds: eligibleAt.seconds(since: uptime)))
            case .notDoomed, .unavailable, .degraded, .acknowledgement, .commit, .lease, .freshAcknowledgement(unanswered: true):
                continue
            }
        }
        return deadline
    }

    /// `runDueWork()`: the coalesced commit, the trailing install (or the fresh install that proves the main actor
    /// ran after a grace ended), then reap batches.
    func performRunDueWork() async -> StoreWorkReport {
        var report = StoreWorkReport(committed: false, installedSnapshot: false, reapedKeys: 0, reapedBytes: 0, nextDeadline: nil)
        guard self.state.core.phase == .open else {
            return report
        }
        let now = self.environment.time.monotonicNow()
        let commits = self.state.core.commits
        if commits.soonPending, !commits.inFlight, self.state.core.unavailable == nil, !self.state.core.applyGate.writing,
            (self.scheduledCommitOpens() ?? now) <= now
        {
            do throws(StoreError) {
                // REENTRANCY: R5 — the phase; a failure leaves the state dirty and a backed-off window retries it.
                try await self.commitNow(.ordered)
                report.committed = true
            } catch {
                report.committed = false
            }
        }
        guard self.state.core.phase == .open else {
            return report
        }
        let trailingDue = self.state.core.snapshots.installDue && (self.installWindowOpens() ?? now) <= self.environment.time.monotonicNow()
        let freshNeeded = self.state.core.blobTable.keys.contains { key in
            if case .freshAcknowledgement = self.deletionBlocker(key) {
                return true
            }
            return false
        }
        if trailingDue || freshNeeded {
            // REENTRANCY: R12 — the awake-clock deadline passed before this install (its start instant is what the
            // acknowledgement certifies); deletable state is recomputed from scratch after the acknowledgement.
            await self.installSnapshot()
            report.installedSnapshot = true
        }
        // REENTRANCY: R7 — `reap` re-checks every key and the phase after each deletion unit.
        let reaped = await self.reap(maxKeys: Int.max)
        report.reapedKeys = reaped.filesRemoved
        report.reapedBytes = reaped.bytesFreed
        report.nextDeadline = self.nextDeadlineInternal()
        return report
    }

    /// `reapDeletable(maxKeys:)`: deletes up to `maxKeys` deletable keys in sorted order, in units of
    /// `deletionBatchSize` (P-13); failed unlinks stay doomed with backoff. `bytesDeferred` counts doomed bytes whose
    /// only blocker is a lease.
    func reap(maxKeys: Int) async -> CleanupResult {
        var result = CleanupResult()
        guard self.state.core.phase == .open, maxKeys > 0, let layout = self.state.core.layout else {
            return result
        }
        // A cursor over the sorted keys: the keys a time-bounded unit did not attempt stay in place and lead the next
        // batch, so the run is linear in the keys (S3-PERF-04).
        var queue = ReapQueue(self.state.core.blobTable.keys.filter { self.deletionBlocker($0) == .none }.sorted())
        let batchSize = max(1, self.configuration.deletionBatchSize)
        let fileSystem = self.environment.fileSystem
        let time = self.environment.time
        var budget = maxKeys
        while !queue.isEmpty, budget > 0, self.state.core.phase == .open {
            let batch = queue.nextBatch(limit: min(batchSize, budget)) { key in
                // Re-validated per key: the state may have changed during the previous unit.
                guard self.deletionBlocker(key) == .none, case .doomed(let info)? = self.state.core.blobTable[key] else {
                    return false
                }
                self.state.core.deletingDooms[key] = info
                self.state.core.blobTable[key] = .deleting
                return true
            }
            guard !batch.isEmpty else {
                break
            }
            let keys = batch
            // REENTRANCY: R7 — keys in `.deleting` are gone, or back to `doomed` with backoff on failure (or unchanged
            // when the unit's time budget ran out before them); waiting publishers are resumed; the loop re-checks the
            // phase before the next batch.
            let outcome = await self.runUnit(on: self.environment.metadataExecutor) {
                BlobDeletionUnit.run(fileSystem: fileSystem, layout: layout, keys: keys, time: time, budget: BlobDeletionUnit.budget)
            }
            let uptime = self.environment.time.uptimeNow()
            for (position, key) in batch.enumerated() {
                let info = self.state.core.deletingDooms.removeValue(forKey: key)
                if position >= outcome.attempted {
                    // Not attempted: back to doomed as it was; it stays first in line for the next unit (`consume`).
                    if let info {
                        self.state.core.blobTable[key] = .doomed(info)
                    }
                } else if outcome.failures[key] != nil, var doom = info {
                    doom.failedUnlinks += 1
                    doom.eligibleAt = uptime.adding(seconds: AssetStore.unlinkBackoff(afterFailures: doom.failedUnlinks))
                    self.state.core.blobTable[key] = .doomed(doom)
                } else {
                    self.state.core.blobTable[key] = nil
                    // Unlinked: a count of its doom stays (the bytes are gone for good) and is no longer tracked.
                    self.state.core.countedReleases[key] = nil
                    result.bytesFreed += self.state.core.blobBytes.removeValue(forKey: key) ?? 0
                    result.filesRemoved += 1
                }
                self.resumeKeyWaiters(key)
            }
            queue.consume(attempted: outcome.attempted)
            budget -= outcome.attempted
            // The processed keys leave DOOMED with the next commit (a lazy mutation).
            self.markDirtyInternal(.lazy)
        }
        for key in self.state.core.blobTable.keys where self.deletionBlocker(key) == .lease {
            result.bytesDeferred += self.state.core.blobBytes[key] ?? 0
        }
        return result
    }

    /// The backoff after `failures` failed unlinks of one key: 1 s, doubling, at most 5 minutes.
    static func unlinkBackoff(afterFailures failures: Int) -> TimeInterval {
        min(300, pow(2, Double(max(0, min(failures, 16) - 1))))
    }
}
