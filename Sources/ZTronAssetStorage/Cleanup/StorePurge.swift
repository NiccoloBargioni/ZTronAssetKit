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
            guard let record = self.state.core.records[id], let key = record.referencedBlob else {
                continue
            }
            reclaim[key] = EvictionOrder.recordedSize(record)
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
        if !selection.isEmpty {
            // C-4: the purge is committed, so the reaper frees its bytes even when the caller leaves during the grace
            // wait (`.cancelled`); it is stamped now, and again when the wait ends.
            self.stampCleanup()
        }
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
    /// sink that does not acknowledge, an uncommitted generation, a degraded or unavailable store, a failed unlink's
    /// backoff), reaping whatever is deletable and installing once the fresh snapshot ADR-017 needs after the grace.
    /// Reads only the blob table's doom bookkeeping (`DoomInfo.eligibleAt`) and the leases. Returns the bytes of the
    /// selection that were deleted and of those still leased.
    func awaitReclaim(_ reclaim: [BlobKey: Int64]) async throws(StoreError) -> (freed: Int64, deferred: Int64) {
        var pending = reclaim
        var freed: Int64 = 0
        var freshInstalled = false
        while true {
            try self.checkLive()
            // REENTRANCY: R7, R9 — every key is recomputed from the blob table below.
            _ = await self.reapDeletable(maxKeys: Int.max)
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
            guard !pending.isEmpty else {
                break
            }
            let uptime = self.environment.time.uptimeNow()
            var wake: MonotonicInstant?
            var graceOver = false
            for key in pending.keys {
                guard case .doomed(let info)? = self.state.core.blobTable[key], let eligibleAt = info.eligibleAt, info.failedUnlinks == 0 else {
                    continue
                }
                if eligibleAt > uptime {
                    let instant = self.environment.time.monotonicNow().adding(seconds: eligibleAt.seconds(since: uptime))
                    wake = wake.map { min($0, instant) } ?? instant
                } else {
                    graceOver = true
                }
            }
            if let wake {
                freshInstalled = false
                do throws(CancellationError) {
                    // REENTRANCY: R9 — the timer only pokes: the loop recomputes the deletable state and the phase.
                    try await self.environment.time.sleep(until: wake)
                } catch {
                    throw .cancelled
                }
            } else if graceOver, !freshInstalled {
                freshInstalled = true
                // REENTRANCY: R12, R9 — the grace ended before this install started; the loop reaps and recomputes.
                await self.publishSnapshot(urgency: .userInitiated)
            } else {
                break
            }
        }
        var deferred: Int64 = 0
        for (key, bytes) in pending where !(self.state.cleanup.leases[key]?.isEmpty ?? true) {
            deferred = deferred.addingSaturating(bytes)
        }
        return (freed, deferred)
    }
}
