import Foundation
import ZTronAssetModel

/// Manifest application, point admission, stamps and the adoption report (R-SYN-8, R-CLN-1, R-CLN-10; ADR-018,
/// ADR-030; WP-B).
extension AssetStore {
    /// `apply(_:etag:eviction:)`: one committed generation holding relocations, prunes, content changes and adoption
    /// by hash (before any dereference, store-1 S1-05); installs a snapshot at once.
    func performApply(_ manifest: ValidatedManifest, etag: ETag?, eviction: EvictionPlan?) async throws(StoreError) -> ApplyReport {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        // REENTRANCY: b-5 (proposed) — `confirmOrphans` re-checks the phase and the orphan table after its unit.
        let confirmed = try await self.confirmOrphans(for: manifest)
        let diff = ManifestDiff.compute(from: self.state.core.appliedManifest, to: manifest)
        let unchanged =
            diff.isEmpty && eviction == nil && !self.state.core.degraded && manifest == self.state.core.appliedManifest
            && etag == self.state.core.etag
        let now = self.environment.time.now()
        var report = ApplyReport(generation: 0)
        if !unchanged {
            report = self.applyDiff(diff, manifest: manifest, etag: etag, now: now)
        }
        // Adoption before any dereference (store-1 S1-05): a key moving from a removed id to an added one is bound
        // before the prune releases it, so it is never doomed.
        for id in diff.targetOrder where self.adoptKnownBlob(for: id, orphans: confirmed, now: now) {
            report.reused.append(id)
        }
        if !unchanged {
            report.pruned = self.prune(diff.removed)
        }
        if !unchanged || !report.reused.isEmpty {
            if let eviction {
                report.evicted = self.applyEviction(eviction)
            }
            self.state.core.degraded = false
            self.markDirtyInternal(.soon)
        }
        // REENTRANCY: R5 — nothing but the phase: every mutation above was made synchronously; the report describes
        // them and the generation is read after the commit.
        try await self.requireCommittedInternal(.ordered)
        report.generation = self.state.core.committedGeneration
        if !unchanged || !report.reused.isEmpty {
            // REENTRANCY: R6 — nothing: the report was built before the install.
            await self.publishSnapshotInternal(urgency: .userInitiated)
        }
        return report
    }

    /// Applies additions, content changes and relocations synchronously (adoption and prunes follow).
    private func applyDiff(_ diff: ManifestDiff, manifest: ValidatedManifest, etag: ETag?, now: Date) -> ApplyReport {
        var report = ApplyReport(generation: 0)
        for id in diff.added {
            guard let entry = diff.upserts[id] else {
                continue
            }
            self.insertRecord(for: entry, now: now)
            report.added.append(id)
        }
        for id in diff.contentChanged {
            guard let entry = diff.upserts[id] else {
                continue
            }
            self.changeContent(of: id, to: entry, now: now)
            report.contentChanged.append(id)
        }
        for id in diff.metadataChanged {
            guard let entry = diff.upserts[id], var record = self.state.core.records[id] else {
                continue
            }
            record.entry = entry
            record.revision += 1
            self.state.core.records[id] = record
            self.refreshPresentEntry(id)
            report.relocated.append(id)
        }
        self.state.core.appliedManifest = manifest
        self.state.core.etag = etag
        return report
    }

    /// Removes the records of ids the manifest no longer lists and dooms their blobs (R-CLN-1); the reaper deletes
    /// them after acknowledgement, grace, commit and leases (ARCHITECTURE §4.4).
    private func prune(_ removed: [AssetID]) -> [AssetID] {
        var pruned: [AssetID] = []
        for id in removed {
            guard let record = self.state.core.records.removeValue(forKey: id) else {
                continue
            }
            self.state.core.presentTable[id] = nil
            pruned.append(id)
            if let blob = record.referencedBlob {
                self.releaseReference(blob, dooming: .unreferenced)
            }
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
    /// manifest's ETag (sync.md §6.5, sync-2 S2-28); committed before it returns.
    func performAdmit(_ entry: ManifestEntry) async throws(StoreError) {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
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
        if let manifest = try? ValidatedManifest(
            entries: entries,
            quarantined: applied.quarantined,
            quarantinedCount: applied.quarantinedCount,
            shape: applied.shape,
            digest: applied.digest
        ) {
            self.state.core.appliedManifest = manifest
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
