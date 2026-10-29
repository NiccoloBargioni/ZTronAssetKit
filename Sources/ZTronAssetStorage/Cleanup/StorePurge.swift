import Foundation
import ZTronAssetModel

/// User purge (R-CLN-6; store.md §6.5): select, doom as `purged`, clear the stamp in the same commit, then wait out the
/// deletion protocol in the caller's task and reap.
extension AssetStore {
    /// Records a purge changes, or orphans a GC sweep dooms, between two releases of the actor (C2: one `setResidency`
    /// per record held the actor for 17 ms at 10,000 records and 210 ms at `maxEntries`, review round 3; one doom per
    /// orphan 9.7 ms for 10,000 orphans, review of the L3 close-out).
    static let cleanupChunk = 1_000

    /// `purge(_:)`. The selection is computed, grouped by blob and sorted off the actor from a value snapshot (C2,
    /// orchestrator ruling R4 at the L3 close-out), then applied in chunks of about `CleanupState.chunk` records that end
    /// only at a blob boundary, with the actor released in between, each blob and record re-validated when it is purged. A
    /// blob of more records than a chunk is purged a chunk of records per turn instead (`purgeAcrossTurns`; Stage 3
    /// ruling S3C-2).
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
        var reclaim: [PurgeSelection.Reclaim] = []
        var purged = 0
        var start = 0
        while start < selection.count {
            if start > 0 {
                // The actor is released between chunks by a no-op metadata unit (C2), as quota eviction's (C-21).
                // REENTRANCY: c-5 (proposed) — the phase and writability, then per blob and record in `purgeChunk`.
                await self.runUnit(on: self.environment.metadataExecutor) {}
                try self.checkLive()
                try self.checkWritable()
            }
            let chunk = max(1, self.state.cleanup.chunk)
            if selection[start].ids.count > chunk {
                // A blob of more records than a chunk is purged `chunk` records per turn (C2 at the reference scale,
                // Stage 3 ruling S3C-2), in a chunk of its own.
                // REENTRANCY: s3c-2 (proposed) — inside, after each release between its turns: the phase, writability and
                // the blob and records of the turn; the next group starts after a release, as every chunk does.
                purged += try await self.purgeAcrossTurns(selection[start], request: request, chunk: chunk, reclaim: &reclaim)
                start += 1
                continue
            }
            // A chunk ends only at a blob boundary: a blob's records are purged in one turn or not at all; a blob of more
            // records than a chunk is never joined to one.
            var end = start
            var records = 0
            repeat {
                records += selection[end].ids.count
                end += 1
            } while end < selection.count && records < chunk && selection[end].ids.count <= chunk
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

    /// Purges one chunk of the selection (one actor turn) and returns how many records it purged. Each blob and record is
    /// re-validated against the state as it is now (REENTRANCY c-5). `.all` and `.scope`: each selected record that still
    /// references its blob. `.evictable`: a blob still live, unleased and not being placed, whose every current holder
    /// (`holders(of:known:scan:)`, O(holders) unless a record was bound to it since the selection, then from the chunk's
    /// one scan of the records) is still neither essential nor pinned, loses all of them; one that is not stays with all
    /// of them, as the selection's rule says.
    func purgeChunk(_ groups: ArraySlice<PurgeSelection.Group>, request: PurgeRequest, reclaim: inout [PurgeSelection.Reclaim]) -> Int {
        var purged = 0
        var scan = HolderScan(blobs: request == .evictable ? groups.map(\.blob) : [])
        for group in groups {
            var bytes: Int64?
            let ids: [AssetID]
            switch request {
            case .evictable:
                guard case .live? = self.state.core.blobTable[group.blob], self.state.cleanup.leases[group.blob]?.isEmpty ?? true,
                    !self.state.core.publishing.contains(group.blob)
                else {
                    continue
                }
                let holders = self.holders(of: group.blob, known: group.ids, scan: &scan)
                guard holders.allSatisfy({ self.state.core.records[$0].map { $0.entry.policy != .essential && !$0.pinned } ?? false }) else {
                    continue
                }
                ids = holders
            case .all, .scope:
                ids = group.ids
            }
            for id in ids {
                guard let record = self.state.core.records[id], record.referencedBlob == group.blob else {
                    continue
                }
                bytes = EvictionOrder.recordedSize(record)
                self.setResidency(.absent(.purged), of: id, dooming: .purged)
                purged += 1
            }
            // A blob is in one group only, so it is waited for once.
            if let bytes {
                reclaim.append(PurgeSelection.Reclaim(key: group.blob, bytes: bytes))
                // Bytes a maintenance eviction measured as used are released now (`EvictionState.releasedBytes`).
                if case .doomed? = self.state.core.blobTable[group.blob] {
                    self.state.eviction.releasedBytes = self.state.eviction.releasedBytes.addingSaturating(bytes)
                }
            }
        }
        return purged
    }

    /// Purges one blob of more records than a chunk, `chunk` records per actor turn with a no-op metadata unit between
    /// turns (C2 at the reference scale: one blob that 10,000 ids share held the actor 13.4 ms in one turn, ruling R8 at
    /// the L3 close-out; Stage 3 ruling S3C-2). The first turn is the caller's. Each turn purges the next `chunk` selected
    /// records that still reference the blob, as `purgeChunk` does; `.evictable` re-validates the blob and the turn's
    /// holders first (`purgeTurnIDs`), and a turn whose check fails stops the blob there, the records purged in earlier
    /// turns staying purged and the rest keeping the blob (a split one turn never made; C2 is the reason, and only blobs
    /// of more records than a chunk are purged this way). The blob is waited for once, its bytes released in the turn it
    /// is doomed. Returns how many records it purged.
    func purgeAcrossTurns(
        _ group: PurgeSelection.Group,
        request: PurgeRequest,
        chunk: Int,
        reclaim: inout [PurgeSelection.Reclaim]
    ) async throws(StoreError) -> Int {
        var purged = 0
        var bytes: Int64?
        var released = false
        // The ids left to purge from `offset` on (`.evictable`: the holders, read again when their count changed).
        var known = group.ids
        var offset = 0
        var first = true
        while let ids = self.purgeTurnIDs(group, request: request, chunk: chunk, known: &known, offset: &offset, first: first) {
            first = false
            for id in ids {
                guard let record = self.state.core.records[id], record.referencedBlob == group.blob else {
                    continue
                }
                bytes = EvictionOrder.recordedSize(record)
                self.setResidency(.absent(.purged), of: id, dooming: .purged)
                purged += 1
            }
            // Bytes a maintenance eviction measured as used are released in the turn the blob is doomed.
            if !released, let bytes, case .doomed? = self.state.core.blobTable[group.blob] {
                self.state.eviction.releasedBytes = self.state.eviction.releasedBytes.addingSaturating(bytes)
                released = true
            }
            if offset >= known.count {
                break
            }
            // REENTRANCY: s3c-2 (proposed) — the phase and writability, then the next turn's checks (`purgeTurnIDs`):
            // `.all` and `.scope` re-read each record (it still references the blob, above), `.evictable` the blob (live,
            // unleased, not being placed) and the turn's holders (neither essential nor pinned; all of them, read again,
            // when the blob's reference count no longer matches the ids left).
            await self.runUnit(on: self.environment.metadataExecutor) {}
            try self.checkLive()
            try self.checkWritable()
        }
        if let bytes {
            reclaim.append(PurgeSelection.Reclaim(key: group.blob, bytes: bytes))
        }
        return purged
    }

    /// The ids one turn of `purgeAcrossTurns` purges: the next `chunk` of `known` from `offset`, or `nil` when none is
    /// left or, for `.evictable`, the blob may not be purged any further. `.evictable` purges only while the blob is live,
    /// unleased and not being placed and its holders are neither essential nor pinned. The `first` turn checks every
    /// holder, as `purgeChunk` does in its one turn, so a blob whose holder was pinned before it is kept whole; a later
    /// turn checks its own ids that still hold the blob, in O(`chunk`), while the blob table counts as many references as
    /// ids are left. Otherwise (a publication in flight holds a provisional reference, or an id was bound to the blob or
    /// left it since) the holders are read again (`holders(of:known:scan:)`) and every one of them is checked.
    func purgeTurnIDs(
        _ group: PurgeSelection.Group,
        request: PurgeRequest,
        chunk: Int,
        known: inout [AssetID],
        offset: inout Int,
        first: Bool
    ) -> ArraySlice<AssetID>? {
        guard offset < known.count else {
            return nil
        }
        let purgeable = { (id: AssetID) -> Bool in
            guard let record = self.state.core.records[id], record.referencedBlob == group.blob else {
                return true
            }
            return record.entry.policy != .essential && !record.pinned
        }
        if request == .evictable {
            guard case .live(let references)? = self.state.core.blobTable[group.blob],
                self.state.cleanup.leases[group.blob]?.isEmpty ?? true, !self.state.core.publishing.contains(group.blob)
            else {
                return nil
            }
            if references != known.count - offset {
                var scan = HolderScan(blobs: [group.blob])
                known = self.holders(of: group.blob, known: Array(known[offset...]), scan: &scan)
                offset = 0
                guard !known.isEmpty, known.allSatisfy(purgeable) else {
                    return nil
                }
            }
        }
        let end = min(offset + chunk, known.count)
        let ids = known[offset..<end]
        guard request != .evictable || (first ? known[offset...] : ids).allSatisfy(purgeable) else {
            return nil
        }
        offset = end
        return ids
    }

    /// Waits until every blob of `reclaim` is reaped, rescued, or blocked by something waiting cannot clear (a lease, a
    /// sink that does not acknowledge, an uncommitted generation, a degraded or unavailable store, a failed unlink's
    /// backoff), reaping whatever is deletable and installing once the fresh snapshot ADR-017 needs after the grace.
    /// A blob another reaper run is deleting (the engine's `runDueWork()`, another purge's wait) is waited for: its
    /// deletion unit ends on its own, and stopping there reported its bytes neither freed nor deferred (review of the L3
    /// close-out cycle 7, probe ZP7-purge-deleting). Reads only the blob table's doom bookkeeping (`DoomInfo.eligibleAt`)
    /// and the leases. Each round makes one pass over the blobs still pending, in chunks of `CleanupState.chunk` with the
    /// actor released in between (C2: one turn over the selection of a full-store purge took 27.6 ms at `maxEntries`,
    /// review of the L3 close-out). Returns the bytes of the selection that were deleted and of those still leased.
    func awaitReclaim(_ reclaim: [PurgeSelection.Reclaim]) async throws(StoreError) -> (freed: Int64, deferred: Int64) {
        var pending = reclaim
        var freed: Int64 = 0
        var deferred: Int64 = 0
        var freshInstalled = false
        while true {
            try self.checkLive()
            // REENTRANCY: R7, R9 — every key is recomputed from the blob table below.
            _ = await self.reapDeletable(maxKeys: Int.max)
            try self.checkLive()
            var pass = PurgeSelection.ReclaimPass()
            var start = 0
            while start < pending.count {
                if start > 0 {
                    // REENTRANCY: R9 — the phase below; every later key is classified from the blob table as it is then (one
                    // reaped or rescued meanwhile counts as such), and the round's figures only decide whether to wait,
                    // install or stop: the next round, or the reaper, sees what changed.
                    await self.runUnit(on: self.environment.metadataExecutor) {}
                    try self.checkLive()
                }
                let end = min(start + max(1, self.state.cleanup.chunk), pending.count)
                self.reclaimPass(pending[start..<end], into: &pass)
                start = end
            }
            freed = freed.addingSaturating(pass.freed)
            pending = pass.pending
            deferred = pass.deferred
            guard !pending.isEmpty else {
                break
            }
            if let wake = pass.wake {
                freshInstalled = false
                do throws(CancellationError) {
                    // REENTRANCY: R9 — the timer only pokes: the loop recomputes the deletable state and the phase.
                    try await self.environment.time.sleep(until: wake)
                } catch {
                    throw .cancelled
                }
            } else if pass.graceOver, !freshInstalled {
                freshInstalled = true
                // REENTRANCY: R12, R9 — the grace ended before this install started; the loop reaps and recomputes.
                await self.publishSnapshot(urgency: .userInitiated)
            } else if !pass.inFlight.isEmpty {
                // Read in this turn, so the deletion awaited is still running and its end resumes the wait (the reaper
                // resumes a key's waiters after every deletion unit, and `close()` all of them). One that ended since
                // the pass saw it needs no wait: the next round classifies it again.
                if let key = pass.inFlight.first(where: { self.state.core.blobTable[$0] == .deleting }) {
                    // REENTRANCY: R9 amendment (cycle 8) — the loop re-checks the phase, reaps, and classifies every
                    // pending key from the blob table again; a cancelled caller leaves here as from the grace wait.
                    await self.waitForKey(key)
                    if Task.isCancelled {
                        throw .cancelled
                    }
                }
            } else {
                break
            }
        }
        return (freed, deferred)
    }

    /// Classifies `items` against the blob table now, O(1) each: a key gone from it was freed, a live one was rescued;
    /// a doomed or deleting one stays pending (its bytes deferred while a lease holds it), a deleting one is noted as in
    /// flight, and a doomed one whose grace runs sets the wake-up, or asks for the fresh install once its grace ended (one
    /// with a failed unlink waits for the reaper's backoff, one not yet acknowledged for an install).
    func reclaimPass(_ items: ArraySlice<PurgeSelection.Reclaim>, into pass: inout PurgeSelection.ReclaimPass) {
        let uptime = self.environment.time.uptimeNow()
        let monotonic = self.environment.time.monotonicNow()
        for item in items {
            let doom: DoomInfo?
            switch self.state.core.blobTable[item.key] {
            case nil:
                pass.freed = pass.freed.addingSaturating(item.bytes)
                continue
            case .live?:
                continue
            case .doomed(let info)?:
                doom = info
            case .deleting?:
                doom = nil
                pass.inFlight.append(item.key)
            }
            pass.pending.append(item)
            if !(self.state.cleanup.leases[item.key]?.isEmpty ?? true) {
                pass.deferred = pass.deferred.addingSaturating(item.bytes)
            }
            guard let doom, let eligibleAt = doom.eligibleAt, doom.failedUnlinks == 0 else {
                continue
            }
            if eligibleAt > uptime {
                let instant = monotonic.adding(seconds: eligibleAt.seconds(since: uptime))
                pass.wake = pass.wake.map { min($0, instant) } ?? instant
            } else {
                pass.graceOver = true
            }
        }
    }
}

/// The pure part of purge (run on the bulk executor, C2).
enum PurgeSelection {
    /// One purged blob the purge waits for, and the bytes it frees.
    struct Reclaim: Sendable, Hashable {
        /// The blob.
        let key: BlobKey
        /// Its recorded size.
        let bytes: Int64
    }

    /// What one round of `awaitReclaim` found over the blobs still pending.
    struct ReclaimPass: Sendable {
        /// The blobs still doomed or being deleted.
        var pending: [Reclaim] = []
        /// The bytes of those gone from the blob table.
        var freed: Int64 = 0
        /// The bytes of the pending ones a lease holds.
        var deferred: Int64 = 0
        /// The earliest end of a running grace, on the monotonic clock.
        var wake: MonotonicInstant?
        /// A pending blob's grace ended: the fresh install ADR-017 needs may unblock it.
        var graceOver = false
        /// The pending blobs another reaper run was deleting when the pass reached them, in pass order: each deletion
        /// unit ends on its own, so the wait goes on until it did.
        var inFlight: [BlobKey] = []
    }

    /// The selected records of one blob, as they were when the selection was made.
    struct Group: Sendable, Hashable {
        /// The blob.
        let blob: BlobKey
        /// Its selected records, sorted by identifier.
        let ids: [AssetID]
    }

    /// The records a purge removes, grouped by the blob they hold and sorted by each group's first identifier: every
    /// record holding a blob (`.all`), those in the scope (`.scope`), or the records of every blob eviction could take
    /// regardless of residency (`.evictable`: live, not being placed, unleased, and none of its records essential or
    /// pinned; a blob shared with such a record stays with all its records).
    static func select(
        _ request: PurgeRequest,
        records: [AssetID: AssetRecord],
        blobTable: [BlobKey: BlobState],
        publishing: Set<BlobKey>,
        leases: [BlobKey: [UInt64: AssetID]]
    ) -> [Group] {
        var byKey: [BlobKey: [(AssetID, AssetRecord)]] = [:]
        for (id, record) in records {
            if let key = record.referencedBlob {
                byKey[key, default: []].append((id, record))
            }
        }
        var selected: [Group] = []
        for (key, holders) in byKey {
            let ids: [AssetID]
            switch request {
            case .all:
                ids = holders.map(\.0)
            case .scope(let scope):
                ids = holders.filter { scope.contains($0.1.entry) }.map(\.0)
            case .evictable:
                guard case .live? = blobTable[key], !publishing.contains(key), leases[key]?.isEmpty ?? true,
                    holders.allSatisfy({ $0.1.entry.policy != .essential && !$0.1.pinned })
                else {
                    continue
                }
                ids = holders.map(\.0)
            }
            if !ids.isEmpty {
                selected.append(Group(blob: key, ids: ids.sorted { $0.rawValue < $1.rawValue }))
            }
        }
        return selected.sorted { $0.ids[0].rawValue < $1.ids[0].rawValue }
    }
}
