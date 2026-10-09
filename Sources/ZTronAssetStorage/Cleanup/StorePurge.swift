import Foundation
import ZTronAssetModel

/// User purge (R-CLN-6; store.md §6.5): select, doom as `purged`, clear the stamp in the same commit, then wait out the
/// deletion protocol in the caller's task and reap.
extension AssetStore {
    /// Records a purge changes between two releases of the actor (C2: one `setResidency` per record held the actor for
    /// 17 ms at 10,000 records and 210 ms at `maxEntries`, review round 3).
    static let cleanupChunk = 1_000

    /// `purge(_:)`. The selection is computed and sorted off the actor from a value snapshot (C2, orchestrator ruling R4
    /// at the L3 close-out), then applied in chunks of `CleanupState.chunk` records with the actor released in between,
    /// each record re-validated when it is purged.
    func performPurge(_ request: PurgeRequest) async throws(StoreError) -> PurgeResult {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        // Before any await of the purge itself (RE-S11, ruling R4): a run that began earlier cannot write its stamp any
        // more, and every commit from here on, the intermediate ones of a chunked purge included, says a sync is due
        // (R-CLN-6: each purge makes a sync due).
        self.state.core.purgeEpoch += 1
        var changed = self.clearStampForPurge()
        let records = self.state.core.records
        let blobTable = self.state.core.blobTable
        let publishing = self.state.core.publishing
        let leases = self.state.cleanup.leases
        // REENTRANCY: c-5 (proposed) — the phase and writability below; the selection describes the state when the unit
        // was submitted, so every record is re-validated when it is purged (`purgeChunk`).
        let selection = await self.runUnit(on: self.environment.bulkExecutor) {
            PurgeSelection.select(request, records: records, blobTable: blobTable, publishing: publishing, leases: leases)
        }
        try self.checkLive()
        try self.checkWritable()
        var reclaim: [BlobKey: Int64] = [:]
        var purged = 0
        var start = 0
        while start < selection.count {
            if start > 0 {
                // The actor is released between chunks by a no-op metadata unit (C2), as quota eviction's (C-21).
                // REENTRANCY: c-5 (proposed) — the phase and writability, then per record in `purgeChunk`.
                await self.runUnit(on: self.environment.metadataExecutor) {}
                try self.checkLive()
                try self.checkWritable()
            }
            let end = min(start + max(1, self.state.cleanup.chunk), selection.count)
            purged += self.purgeChunk(selection[start..<end], request: request, reclaim: &reclaim)
            start = end
        }
        if purged > 0 {
            // In the turn of the last chunk: a sync that read the epoch during the selection or between chunks saw part of
            // the selection still present, so it may not stamp either, and a stamp it wrote meanwhile goes.
            self.state.core.purgeEpoch += 1
            changed = self.clearStampForPurge() || changed
        }
        guard changed || purged > 0 else {
            return PurgeResult(bytesFreed: 0, bytesDeferred: 0, assetsRemoved: 0)
        }
        if purged > 0 {
            // REENTRANCY: R17 — nothing but the phase: the selection was purged synchronously above.
            await self.publishSnapshot(urgency: .userInitiated)
        }
        // REENTRANCY: R17 — as above; the stamp is cleared in this very generation.
        try await self.requireCommitted(.ordered)
        if purged > 0 {
            // C-4: the purge is committed, so the reaper frees its bytes even when the caller leaves during the grace
            // wait (`.cancelled`); it is stamped now, and again when the wait ends.
            self.stampCleanup()
        }
        // REENTRANCY: R9 — `awaitReclaim` recomputes the deletable state of the selection from scratch after each await.
        let (freed, deferred) = try await self.awaitReclaim(reclaim)
        if purged > 0 {
            self.stampCleanup()
        }
        return PurgeResult(bytesFreed: freed, bytesDeferred: deferred, assetsRemoved: purged)
    }

    /// Clears the stamp and makes a sync due (R-CLN-6), marked dirty; whether anything changed.
    func clearStampForPurge() -> Bool {
        guard self.state.core.stamp != nil || !self.state.core.syncDue else {
            return false
        }
        self.state.core.stamp = nil
        self.state.core.syncDue = true
        self.markDirty(.soon)
        return true
    }

    /// Purges one chunk of the selection (one actor turn) and returns how many records it purged. Each record is
    /// re-validated against the state as it is now: it still references the blob recorded at selection, and for
    /// `.evictable` it is still neither essential nor pinned and its blob neither leased nor being placed (REENTRANCY
    /// c-5). O(1) per record.
    func purgeChunk(_ items: ArraySlice<PurgeSelection.Item>, request: PurgeRequest, reclaim: inout [BlobKey: Int64]) -> Int {
        var purged = 0
        for item in items {
            guard let record = self.state.core.records[item.id], record.referencedBlob == item.blob else {
                continue
            }
            if request == .evictable {
                guard record.entry.policy != .essential, !record.pinned, self.state.cleanup.leases[item.blob]?.isEmpty ?? true,
                    !self.state.core.publishing.contains(item.blob)
                else {
                    continue
                }
            }
            reclaim[item.blob] = EvictionOrder.recordedSize(record)
            self.setResidency(.absent(.purged), of: item.id, dooming: .purged)
            purged += 1
        }
        return purged
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
            // One pass over the selection per round (C2: O(1) per key).
            let uptime = self.environment.time.uptimeNow()
            let monotonic = self.environment.time.monotonicNow()
            var wake: MonotonicInstant?
            var graceOver = false
            for (key, bytes) in pending {
                switch self.state.core.blobTable[key] {
                case nil:
                    freed = freed.addingSaturating(bytes)
                    pending[key] = nil
                case .live?:
                    pending[key] = nil
                case .doomed(let info)?:
                    guard let eligibleAt = info.eligibleAt, info.failedUnlinks == 0 else {
                        continue
                    }
                    if eligibleAt > uptime {
                        let instant = monotonic.adding(seconds: eligibleAt.seconds(since: uptime))
                        wake = wake.map { min($0, instant) } ?? instant
                    } else {
                        graceOver = true
                    }
                case .deleting?:
                    break
                }
            }
            guard !pending.isEmpty else {
                break
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

/// The pure part of purge (run on the bulk executor, C2).
enum PurgeSelection {
    /// One selected record and the blob it held at selection.
    struct Item: Sendable, Hashable {
        /// The record.
        let id: AssetID
        /// The blob it referenced when the selection was made.
        let blob: BlobKey
    }

    /// The records a purge removes, sorted by identifier: every record holding a blob (`.all`), those in the scope
    /// (`.scope`), or the records of every blob eviction could take regardless of residency (`.evictable`: live, not
    /// being placed, unleased, and none of its records essential or pinned; a blob shared with such a record stays with
    /// all its records).
    static func select(
        _ request: PurgeRequest,
        records: [AssetID: AssetRecord],
        blobTable: [BlobKey: BlobState],
        publishing: Set<BlobKey>,
        leases: [BlobKey: [UInt64: AssetID]]
    ) -> [Item] {
        var selected: [Item] = []
        switch request {
        case .all:
            selected = records.compactMap { id, record in record.referencedBlob.map { Item(id: id, blob: $0) } }
        case .scope(let scope):
            selected = records.compactMap { id, record in
                scope.contains(record.entry) ? record.referencedBlob.map { Item(id: id, blob: $0) } : nil
            }
        case .evictable:
            var byKey: [BlobKey: [(AssetID, AssetRecord)]] = [:]
            for (id, record) in records {
                if let key = record.referencedBlob {
                    byKey[key, default: []].append((id, record))
                }
            }
            for (key, holders) in byKey {
                guard case .live? = blobTable[key], !publishing.contains(key), leases[key]?.isEmpty ?? true,
                    holders.allSatisfy({ $0.1.entry.policy != .essential && !$0.1.pinned })
                else {
                    continue
                }
                selected.append(contentsOf: holders.map { Item(id: $0.0, blob: key) })
            }
        }
        return selected.sorted { $0.id.rawValue < $1.id.rawValue }
    }
}
