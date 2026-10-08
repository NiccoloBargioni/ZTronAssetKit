import Foundation
import ZTronAssetModel

/// Manifest application, point admission, stamps and the adoption report (R-SYN-8, R-CLN-1, R-CLN-10; ADR-018,
/// ADR-030; WP-B).
extension AssetStore {
    /// `apply(_:etag:eviction:)`: one committed generation holding relocations, prunes, content changes and adoption
    /// by hash (before any dereference, store-1 S1-05); installs a snapshot at once. Its writes yield between chunks
    /// (C2) behind the commit fence, so no generation ever holds the new manifest and ETag with part of the records
    /// (R-NET-5: a later `304` would keep them at the old content for good; ADR draft B-23).
    func performApply(_ manifest: ValidatedManifest, etag: ETag?, eviction: EvictionPlan?) async throws(StoreError) -> ApplyReport {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        // REENTRANCY: b-7 (proposed) — the gate loop re-reads the gate and the phase: one `apply` or `admit` at a time.
        try await self.acquireApplyGate()
        defer {
            self.releaseApplyGate()
        }
        // REENTRANCY: b-5 (proposed) — `confirmOrphans` re-checks the phase and the orphan table after its unit.
        let confirmed = try await self.confirmOrphans(for: manifest)
        let now = self.environment.time.now()
        // REENTRANCY: b-6 (proposed) — `planOffActor` re-checks the phase and recomputes when the applied manifest
        // changed during its unit; the writes below re-read the live state, and every adoption candidate is
        // re-validated by `adoptKnownBlob`.
        let plan = try await self.planOffActor(to: manifest, orphans: confirmed, now: now)
        let diff = plan.diff
        let unchanged = diff.isEmpty && eviction == nil && !self.state.core.degraded && plan.identical && etag == self.state.core.etag
        var report = ApplyReport(generation: 0)
        var swept = 0
        // The commit fence (ADR draft B-23), raised in the same turn as the phase check above: from the first write
        // to the last, no commit, adoption report or `close()` captures a half-applied manifest, and the writes run
        // to the end whatever happens meanwhile (nothing below throws until the commit).
        self.state.core.applyGate.writing = true
        if !unchanged {
            // REENTRANCY: b-7 (proposed) — `applyDiff` yields between chunks behind the fence; each write re-reads
            // the record it changes.
            report = await self.applyDiff(diff, newRecords: plan.newRecords, manifest: manifest, etag: etag, now: now, swept: &swept)
        }
        // Adoption before any dereference (store-1 S1-05): a key moving from a removed id to an added one is bound
        // before the prune releases it, so it is never doomed.
        for id in plan.adoptionCandidates {
            if self.adoptKnownBlob(for: id, orphans: confirmed, now: now) {
                report.reused.append(id)
            }
            // REENTRANCY: b-7 (proposed) — behind the fence; the next candidate is re-validated by `adoptKnownBlob`
            // against the state as it is then.
            await self.pace(&swept)
        }
        if !unchanged {
            // REENTRANCY: b-7 (proposed) — `prune` yields between chunks behind the fence and removes only records
            // still present.
            report.pruned = await self.prune(diff.removed, swept: &swept)
        }
        if !unchanged || !report.reused.isEmpty {
            if let eviction {
                report.evicted = self.applyEviction(eviction)
            }
            self.state.core.degraded = false
            self.markDirtyInternal(.soon)
        }
        self.endApplyWrites()
        // REENTRANCY: R5 — nothing but the phase: every mutation above was made before the await; the report
        // describes them and the generation is read after the commit.
        try await self.requireCommittedInternal(.ordered)
        report.generation = self.state.core.committedGeneration
        if !unchanged || !report.reused.isEmpty {
            // REENTRANCY: R6 — nothing: the report was built before the install.
            await self.publishSnapshotInternal(urgency: .userInitiated)
        }
        return report
    }

    /// How many records a sweep of `apply` handles between two yields of the actor (C2: about 6 µs per adoption in
    /// release on a Mac, so a chunk holds the actor for a few milliseconds even on a slower device).
    static let sweepChunk = 512

    /// Counts one item of a long sweep and yields the actor after every `sweepChunk` items (C2, as REENTRANCY R8
    /// does for eviction and reconciliation chunks). It never throws: the writes run behind the commit fence and
    /// always run to the end, because a half-applied state must never be the one a commit or `close()` persists
    /// (ADR draft B-23).
    private func pace(_ swept: inout Int) async {
        swept += 1
        guard swept % AssetStore.sweepChunk == 0 else {
            return
        }
        // REENTRANCY: b-7 (proposed) — nothing stops the writes: the fence is up, so nothing persists or reports
        // the half-applied state and `close()` waits for the fence before its durable commit; the gate keeps the
        // plan and the applied manifest unchanged; every caller re-reads the record it touches next; the phase and
        // writability are re-checked by `apply`'s commit after the last write.
        await Task.yield()
    }

    /// Lowers the commit fence after `apply`'s last write and resumes everything that waited for it (ADR draft
    /// B-23).
    func endApplyWrites() {
        self.state.core.applyGate.writing = false
        self.resumeApplyWriteWaiters()
    }

    /// Waits until no other `apply` or `admit` runs, then holds the gate: their plans and writes, which yield
    /// between chunks, never interleave (C2, proposed REENTRANCY row b-7).
    private func acquireApplyGate() async throws(StoreError) {
        while self.state.core.applyGate.held {
            // REENTRANCY: b-7 (proposed) — the loop re-reads the gate and the phase once the holder released it.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.state.core.applyGate.waiters.append(continuation)
            }
            try self.checkLive()
        }
        self.state.core.applyGate.held = true
    }

    /// Releases the gate and resumes every waiter; each re-checks it. The commit fence is already down: nothing
    /// between raising it and `endApplyWrites()` can throw (the compiler checks it: no `try` in that region).
    private func releaseApplyGate() {
        self.state.core.applyGate.held = false
        self.resumeApplyWaiters()
    }

    /// The apply plan (diff, identity, new records, adoption candidates), computed on the bulk executor from values
    /// captured here (C2, review probe P4). It is used only if no `apply` or `admit` replaced the applied manifest
    /// during the unit; otherwise it is computed again against the new one.
    private func planOffActor(to manifest: ValidatedManifest, orphans: [BlobKey: Int64], now: Date) async throws(StoreError) -> ApplyPlan {
        while true {
            let revision = self.state.core.manifestRevision
            let applied = self.state.core.appliedManifest
            let records = self.state.core.records
            let blobTable = self.state.core.blobTable
            // REENTRANCY: b-6 (proposed) — the phase and writability, then `manifestRevision`: a plan made against a
            // manifest replaced meanwhile is discarded and made again; records and blobs that changed meanwhile are
            // re-read by the synchronous writes and by `adoptKnownBlob`.
            let plan = await self.runUnit(on: self.environment.bulkExecutor) {
                ApplyPlan.compute(applied: applied, manifest: manifest, records: records, blobTable: blobTable, orphans: orphans, now: now)
            }
            try self.checkLive()
            try self.checkWritable()
            if self.state.core.manifestRevision == revision {
                return plan
            }
        }
    }

    /// Applies additions, content changes and relocations (adoption and prunes follow), yielding between chunks
    /// behind the commit fence.
    private func applyDiff(
        _ diff: ManifestDiff,
        newRecords: [AssetID: AssetRecord],
        manifest: ValidatedManifest,
        etag: ETag?,
        now: Date,
        swept: inout Int
    ) async -> ApplyReport {
        var report = ApplyReport(generation: 0)
        self.state.core.appliedManifest = manifest
        self.state.core.manifestRevision += 1
        self.state.core.etag = etag
        report.added.reserveCapacity(diff.added.count)
        for id in diff.added {
            if let record = newRecords[id] {
                // A record the manifest did not list (detached) is replaced as `insertRecord` would.
                if let previous = self.state.core.records.updateValue(record, forKey: id) {
                    if let blob = previous.referencedBlob {
                        self.releaseReference(blob, dooming: .unreferenced)
                    }
                    self.refreshPresentEntry(id)
                }
                report.added.append(id)
            } else if let entry = diff.upserts[id] {
                self.insertRecord(for: entry, now: now)
                report.added.append(id)
            }
            // REENTRANCY: b-7 (proposed) — behind the fence (see `pace`); the next id's record is re-read.
            await self.pace(&swept)
        }
        for id in diff.contentChanged {
            if let entry = diff.upserts[id] {
                self.changeContent(of: id, to: entry, now: now)
                report.contentChanged.append(id)
            }
            // REENTRANCY: b-7 (proposed) — as above.
            await self.pace(&swept)
        }
        for id in diff.metadataChanged {
            if let entry = diff.upserts[id], var record = self.state.core.records[id] {
                record.entry = entry
                record.revision += 1
                self.state.core.records[id] = record
                self.refreshPresentEntry(id)
                report.relocated.append(id)
            }
            // REENTRANCY: b-7 (proposed) — as above.
            await self.pace(&swept)
        }
        return report
    }

    /// Removes the records of ids the manifest no longer lists and dooms their blobs (R-CLN-1), yielding between
    /// chunks behind the commit fence; the reaper deletes them after acknowledgement, grace, commit and leases
    /// (ARCHITECTURE §4.4).
    private func prune(_ removed: [AssetID], swept: inout Int) async -> [AssetID] {
        var pruned: [AssetID] = []
        for id in removed {
            if let record = self.state.core.records.removeValue(forKey: id) {
                self.state.core.presentTable[id] = nil
                pruned.append(id)
                if let blob = record.referencedBlob {
                    self.releaseReference(blob, dooming: .unreferenced)
                }
            }
            // REENTRANCY: b-7 (proposed) — behind the fence (see `pace`); the next id is removed only if still present.
            await self.pace(&swept)
        }
        return pruned
    }

    /// A new record, absent until fetched or adopted.
    private func insertRecord(for entry: ManifestEntry, now: Date) {
        if let previous = self.state.core.records[entry.identifier]?.referencedBlob {
            self.releaseReference(previous, dooming: .unreferenced)
        }
        self.state.core.records[entry.identifier] = AssetRecord(
            entry: entry,
            residency: .absent(.neverFetched),
            expectedBlob: entry.checksum,
            lastAccess: now
        )
        self.refreshPresentEntry(entry.identifier)
    }

    /// A content change: the present blob stays (stale, still served); `failed` and `quarantined` end; the integrity
    /// history is reset (R-INT-3, ADR-032 as amended).
    private func changeContent(of id: AssetID, to entry: ManifestEntry, now: Date) {
        guard var record = self.state.core.records[id] else {
            self.insertRecord(for: entry, now: now)
            return
        }
        record.entry = entry
        record.revision += 1
        record.expectedBlob = entry.checksum
        record.integrity = .clean
        switch record.residency {
        case .failed, .quarantined:
            record.residency = .absent(.neverFetched)
        default:
            break
        }
        self.state.core.records[id] = record
        self.refreshPresentEntry(id)
    }

    /// Binds `id` to a blob the store already knows (live, rescuable, or an orphan confirmed on disk) when its
    /// record accepts adoption and expects that key and size; no I/O (store.md §2.6 7c).
    func adoptKnownBlob(for id: AssetID, orphans confirmed: [BlobKey: Int64], now: Date) -> Bool {
        guard var record = self.state.core.records[id], record.acceptsAdoption, let key = record.expectedKey,
            !self.state.core.publishing.contains(key)
        else {
            return false
        }
        let size: Int64
        switch self.state.core.blobTable[key] {
        case .live?:
            guard let known = self.state.core.blobBytes[key] else {
                return false
            }
            size = known
        case .doomed(let info)? where info.reason == .unreferenced:
            guard let known = self.state.core.blobBytes[key] else {
                return false
            }
            size = known
        case nil:
            guard let orphan = confirmed[key] else {
                return false
            }
            size = orphan
        default:
            return false
        }
        if let expectedSize = record.entry.byteSize, expectedSize != size {
            return false
        }
        if self.state.core.blobTable[key] == nil {
            self.state.core.blobTable[key] = .live(references: 1)
            self.state.core.blobBytes[key] = size
            self.state.core.orphans[key] = nil
        } else {
            _ = self.gainReferenceInPlace(key)
        }
        let previous = record.referencedBlob
        record.residency = .present(blob: key, byteSize: size, integrity: record.entry.checksum == key.hash ? .verified : .unverified)
        record.storedAt = now
        self.state.core.records[id] = record
        if let previous, previous != key {
            self.releaseReference(previous, dooming: .unreferenced)
        }
        self.state.core.commits.dirtyFanOuts.insert(key.hash.fanOut)
        self.refreshPresentEntry(id)
        return true
    }

    /// Re-stats the launch orphans a manifest could adopt, so `apply` never binds a record to a file that vanished
    /// since the launch listing (degraded rebuild, store.md §2.6).
    private func confirmOrphans(for manifest: ValidatedManifest) async throws(StoreError) -> [BlobKey: Int64] {
        guard !self.state.core.orphans.isEmpty, let layout = self.state.core.layout else {
            return [:]
        }
        var candidates: [BlobKey: Int64] = [:]
        for entry in manifest.entries {
            guard let checksum = entry.checksum, let ext = AssetFileExtension(entry.fileExtension) else {
                continue
            }
            let key = BlobKey(hash: checksum, ext: ext)
            if let size = self.state.core.orphans[key] {
                candidates[key] = size
            }
        }
        guard !candidates.isEmpty else {
            return [:]
        }
        let fileSystem = self.environment.fileSystem
        let listed = candidates
        // REENTRANCY: b-5 (proposed) — the phase; a candidate counts only if it is still an orphan of the same size
        // after the await (adopted or collected keys left the table meanwhile).
        let present = await self.runUnit(on: self.environment.metadataExecutor) { () -> [BlobKey: Int64] in
            var found: [BlobKey: Int64] = [:]
            for (key, size) in listed {
                if let info = try? fileSystem.itemInfo(at: layout.blobURL(key)), info.kind == .file, info.byteSize == size {
                    found[key] = size
                }
            }
            return found
        }
        try self.checkLive()
        return present.filter { self.state.core.orphans[$0.key] == $0.value && self.state.core.blobTable[$0.key] == nil }
    }

    /// `admit(_:)`: adds or updates one entry without reconciling anything else and without the fetched
    /// manifest's ETag (sync.md §6.5, sync-2 S2-28); committed before it returns. The applied manifest's digest becomes
    /// `admittedDigest(after:revision:)`, which matches no fetched manifest (ADR draft B-30): the applied entries no
    /// longer are any server payload, so a planner comparing digests always applies the next fetched manifest.
    func performAdmit(_ entry: ManifestEntry) async throws(StoreError) {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        // REENTRANCY: b-7 (proposed) — the gate loop re-reads the gate and the phase: one `apply` or `admit` at a time.
        try await self.acquireApplyGate()
        defer {
            self.releaseApplyGate()
        }
        let id = entry.identifier
        let now = self.environment.time.now()
        if let existing = self.state.core.records[id] {
            switch ManifestDiff.classify(old: existing.entry, new: entry) {
            case .unchanged, .added, .removed:
                return
            case .metadataChanged:
                var record = existing
                record.entry = entry
                record.revision += 1
                self.state.core.records[id] = record
                self.refreshPresentEntry(id)
            case .contentChanged:
                self.changeContent(of: id, to: entry, now: now)
            }
        } else {
            self.insertRecord(for: entry, now: now)
        }
        var entries = self.state.core.appliedManifest.entries
        if let index = self.state.core.appliedManifest.position(of: id) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        let applied = self.state.core.appliedManifest
        let revision = self.state.core.manifestRevision + 1
        if let manifest = try? ValidatedManifest(
            entries: entries,
            quarantined: applied.quarantined,
            quarantinedCount: applied.quarantinedCount,
            shape: applied.shape,
            digest: AssetStore.admittedDigest(after: applied.digest, revision: revision)
        ) {
            self.state.core.appliedManifest = manifest
            self.state.core.manifestRevision = revision
        }
        let adopted = self.adoptKnownBlob(for: id, orphans: [:], now: now)
        self.markDirtyInternal(.soon)
        // REENTRANCY: R5 — nothing but the phase: the admission was made synchronously above.
        try await self.requireCommittedInternal(.ordered)
        if adopted {
            // REENTRANCY: R6 — nothing.
            await self.publishSnapshotInternal(urgency: .userInitiated)
        }
    }

    /// The applied manifest's digest after an admission (ADR draft B-30): SHA-256 of a domain tag, the previous
    /// digest and the manifest revision. A fetched manifest's digest is the SHA-256 of its payload bytes
    /// (`ValidatedManifest`), so matching this one would take a SHA-256 preimage of it; every admission yields a new
    /// value, and it is persisted with the entries like any applied digest.
    static func admittedDigest(after previous: ContentHash, revision: UInt64) -> ContentHash {
        var message = Data("ZTronAssetKit.admitted-manifest.v1".utf8)
        message.append(0)
        for word in [previous.w0, previous.w1, previous.w2, previous.w3, revision] {
            message.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: word >> (56 - 8 * $0)) })
        }
        return ContentHash.sha256(of: message)
    }

    /// `markSynced(_:ifPurgeEpoch:)` (R-CLN-6).
    func performMarkSynced(_ stamp: SyncStamp, ifPurgeEpoch purgeEpoch: UInt64) async throws(StoreError) {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        guard purgeEpoch == self.state.core.purgeEpoch else {
            throw .purgeRaced
        }
        self.state.core.stamp = stamp
        self.state.core.syncDue = false
        self.markDirtyInternal(.soon)
        // REENTRANCY: R5 — nothing but the phase: a purge that lands meanwhile clears the stamp in its own commit.
        try await self.requireCommittedInternal(.ordered)
    }

    /// `markSyncDue()`.
    func performMarkSyncDue() async throws(StoreError) {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        self.state.core.stamp = nil
        self.state.core.syncDue = true
        self.markDirtyInternal(.soon)
        // REENTRANCY: R5 — nothing but the phase.
        try await self.requireCommittedInternal(.ordered)
    }

    /// `adoptionReport()`: captured synchronously, then the holding generation is committed durably; only what was
    /// captured is reported (R-CLN-10, H-7, REENTRANCY R15).
    func performAdoptionReport() async throws(StoreError) -> AdoptionReport {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        while self.state.core.applyGate.writing {
            // REENTRANCY: b-8 (proposed) — the phase and writability, then the fence again: the report is captured
            // only from a state no `apply` is half way through (ADR draft B-23).
            await self.waitForApplyWrites()
            try self.checkLive()
            try self.checkWritable()
        }
        let manifest = self.state.core.appliedManifest
        let scope = self.state.eviction.retentionScope
        var adopted: Set<String> = []
        var excluded: Set<String> = []
        for entry in manifest.entries {
            if let record = self.state.core.records[entry.identifier], record.referencedBlob != nil, !record.isStale {
                adopted.insert(entry.remotePath)
            }
            if !scope.contains(entry) {
                excluded.insert(entry.remotePath)
            }
        }
        let report = AdoptionReport(manifestRemotePaths: manifest.entries.map(\.remotePath), adoptedRemotePaths: adopted, excludedRemotePaths: excluded)
        // REENTRANCY: R15 — nothing: the report is the state captured before the await; a publication made meanwhile
        // is not reported; a failure throws and reports nothing.
        try await self.requireCommittedInternal(.durable)
        return report
    }
}
