import Foundation
import ZTronAssetModel

/// The R-INT-3 bookkeeping (store.md §5.4, ADR-032): pure, so the transport, publication and local-corruption paths
/// count alike.
enum IntegrityBookkeeping {
    /// One failure's outcome: the new history, and the quarantine end, or `nil` once the entry is to be `failed`.
    struct Step: Sendable, Hashable {
        /// The history to persist.
        var history: IntegrityHistory
        /// Not fetched before this instant; `nil` when `maxIntegrityAttempts` is reached.
        var quarantinedUntil: Date?
    }

    /// The history after one more failure of `identity` at `now`: a failure of another identity than the recorded one
    /// starts the count again; the backoff is `policy.integrityBackoff(afterAttempt:)` (a non-finite one waits
    /// forever, `Date.distantFuture`).
    static func failure(after history: IntegrityHistory, of identity: ContentIdentity, at now: Date, policy: StoragePolicy) -> Step {
        var next = history.failedIdentity == identity ? history : IntegrityHistory(attempts: 0, failedIdentity: identity)
        next.attempts = next.attempts == .max ? .max : next.attempts + 1
        guard let backoff = policy.integrityBackoff(afterAttempt: Int(next.attempts)) else {
            next.nextEligibleAt = nil
            return Step(history: next, quarantinedUntil: nil)
        }
        let until = backoff.isFinite ? now.addingTimeInterval(max(0, backoff)) : Date.distantFuture
        next.nextEligibleAt = until
        return Step(history: next, quarantinedUntil: until)
    }

    /// `ids` without repetitions, in first-seen order.
    static func unique(_ ids: [AssetID]) -> [AssetID] {
        var seen: Set<AssetID> = []
        return ids.filter { seen.insert($0).inserted }
    }
}

extension AssetStore {
    /// Quarantines every record referencing `key` (R-CLN-8): each one's history counts a failure of its identity, it
    /// becomes `quarantined(until:)` or, at the cap, `failed(.unreadable)`, and the blob is doomed `corrupt` (never
    /// re-adopted or rescued, ADR-018). `known` are the holders the caller saw (`holders(of:known:scan:)` finds the rest
    /// without a full index unless the counts disagree, C2), and `scan` the turn's scan of the records, if the caller
    /// already needed one for this blob. Synchronous. Returns the ids it quarantined, sorted.
    @discardableResult
    func quarantine(blob key: BlobKey, known: [AssetID], scan: inout HolderScan) -> [AssetID] {
        let now = self.environment.time.now()
        let ids = self.holders(of: key, known: known, scan: &scan).sorted { $0.rawValue < $1.rawValue }
        for id in ids {
            guard var record = self.state.core.records[id] else {
                continue
            }
            let step = IntegrityBookkeeping.failure(after: record.integrity, of: record.entry.contentIdentity, at: now, policy: self.configuration.policy)
            record.integrity = step.history
            self.state.core.records[id] = record
            let residency: Residency = step.quarantinedUntil.map { .quarantined(until: $0) } ?? .failed(.unreadable)
            self.setResidency(residency, of: id, dooming: .corrupt)
        }
        return ids
    }

    /// Persists bookkeeping written synchronously by the caller: one ordered commit, after a snapshot install when a
    /// blob left the snapshot (it must be acknowledged before the reaper may delete it).
    func persistBookkeeping(changed: Bool, droppedBlobs: Bool) async throws(StoreError) {
        guard changed else {
            return
        }
        self.markDirty(.soon)
        if droppedBlobs {
            // REENTRANCY: R17 — nothing but the phase: the bookkeeping was written synchronously by the caller.
            await self.publishSnapshot(urgency: .bulk)
        }
        // REENTRANCY: R17 — as above; a failed commit leaves it dirty (R5) and throws.
        try await self.requireCommitted(.ordered)
    }
}
