import Foundation
import ZTronAssetModel

/// User purge (R-CLN-6; store.md §6.5): select, doom as `purged`, clear the stamp in the same commit, then wait out the
/// deletion protocol in the caller's task and reap.
extension AssetStore {
    /// `purge(_:)`.
    func performPurge(_ request: PurgeRequest) async throws(StoreError) -> PurgeResult {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        // Before any await of the purge itself (RE-S11): a run that began earlier cannot write its stamp any more.
        self.state.core.purgeEpoch += 1
        let selection = self.purgeSelection(request)
        var reclaim: [BlobKey: Int64] = [:]
        for id in selection {
            guard let key = self.state.core.records[id]?.referencedBlob else {
                continue
            }
            reclaim[key] = self.state.core.blobBytes[key] ?? 0
            self.setResidency(.absent(.purged), of: id, dooming: .purged)
        }
        var changed = !selection.isEmpty
        if request == .all || changed, self.state.core.stamp != nil || !self.state.core.syncDue {
            self.state.core.stamp = nil
            self.state.core.syncDue = true
            changed = true
        }
        guard changed else {
            return PurgeResult(bytesFreed: 0, bytesDeferred: 0, assetsRemoved: 0)
        }
        self.markDirty(.soon)
        if !selection.isEmpty {
            // REENTRANCY: R17 — nothing but the phase: the selection was purged synchronously above.
            await self.publishSnapshot(urgency: .userInitiated)
        }
        // REENTRANCY: R17 — as above; the stamp is cleared in this very generation.
        try await self.requireCommitted(.ordered)
        // REENTRANCY: R9 — `awaitReclaim` recomputes the deletable state of the selection from scratch after each await.
        let (freed, deferred) = try await self.awaitReclaim(reclaim)
        if !selection.isEmpty {
            self.stampCleanup()
        }
        return PurgeResult(bytesFreed: freed, bytesDeferred: deferred, assetsRemoved: selection.count)
    }

    /// The ids a purge removes, sorted: every record holding a blob (`.all`), those in the scope (`.scope`), or the records
    /// of every blob eviction could take regardless of residency (`.evictable`: not essential, pinned or leased; a blob
    /// shared with such a record stays with all its records).
    func purgeSelection(_ request: PurgeRequest) -> [AssetID] {
        var selected: [AssetID] = []
        switch request {
        case .all:
            selected = self.state.core.records.compactMap { $0.value.referencedBlob == nil ? nil : $0.key }
        case .scope(let scope):
            selected = self.state.core.records.compactMap { $0.value.referencedBlob != nil && scope.contains($0.value.entry) ? $0.key : nil }
        case .evictable:
            for (key, ids) in self.referenceIndex() {
                guard case .live? = self.state.core.blobTable[key], !self.state.core.publishing.contains(key),
                    self.state.cleanup.leases[key]?.isEmpty ?? true,
                    ids.allSatisfy({ self.state.core.records[$0].map { $0.entry.policy != .essential && !$0.pinned } ?? false })
                else {
                    continue
                }
                selected.append(contentsOf: ids)
            }
        }
        return selected.sorted { $0.rawValue < $1.rawValue }
    }

    /// Waits until every blob of `reclaim` is reaped, rescued, or blocked by something waiting cannot clear (a lease, a
    /// sink that does not acknowledge, an uncommitted generation, a degraded or unavailable store), reaping whatever is
    /// deletable and installing the fresh snapshot ADR-017 needs after the grace. Returns the bytes of the selection that
    /// were deleted and of those still leased.
    func awaitReclaim(_ reclaim: [BlobKey: Int64]) async throws(StoreError) -> (freed: Int64, deferred: Int64) {
        var pending = reclaim
        var freed: Int64 = 0
        var installedFresh = false
        while true {
            try self.checkLive()
            for (key, bytes) in pending {
                switch self.state.core.blobTable[key] {
                case nil:
                    freed = freed.addingSaturating(bytes)
                    pending[key] = nil
                case .live?:
                    pending[key] = nil
                case .doomed?, .deleting?:
                    break
                }
            }
            var reapable = false
            var fresh = false
            var wake: MonotonicInstant?
            for key in pending.keys {
                switch self.deletionBlocker(key) {
                case .none:
                    reapable = true
                case .freshAcknowledgement(unanswered: false):
                    fresh = true
                case .grace(let eligibleAt):
                    // A failed unlink's backoff is also a grace; waiting for it could last minutes, so a key that failed
                    // to unlink is left to the reaper.
                    if case .doomed(let info)? = self.state.core.blobTable[key], info.failedUnlinks > 0 {
                        continue
                    }
                    let instant = self.environment.time.monotonicNow().adding(seconds: eligibleAt.seconds(since: self.environment.time.uptimeNow()))
                    wake = wake.map { min($0, instant) } ?? instant
                case .notDoomed, .degraded, .unavailable, .acknowledgement, .commit, .lease, .freshAcknowledgement(unanswered: true):
                    break
                }
            }
            if reapable {
                // REENTRANCY: R7, R9 — the loop recomputes every key's state from scratch.
                _ = await self.reapDeletable(maxKeys: Int.max)
            } else if fresh, !installedFresh {
                installedFresh = true
                // REENTRANCY: R12, R9 — the grace ended before this install; the loop recomputes the blockers after it.
                await self.publishSnapshot(urgency: .userInitiated)
            } else if let wake {
                installedFresh = false
                do throws(CancellationError) {
                    // REENTRANCY: R9 — the timer only pokes: the loop recomputes the deletable state and the phase.
                    try await self.environment.time.sleep(until: wake)
                } catch {
                    throw .cancelled
                }
            } else {
                break
            }
        }
        var deferred: Int64 = 0
        for (key, bytes) in pending where self.deletionBlocker(key) == .lease {
            deferred = deferred.addingSaturating(bytes)
        }
        return (freed, deferred)
    }
}
