import Foundation
import ZTronAssetModel

/// What a verified file is bound to (`bindVerifiedFile`): the records that still carry this content identity
/// (`publish`) or still expect this digest (`adoptVerifiedFile`, legacy migration).
enum BindingExpectation: Sendable, Hashable {
    /// Records whose current content identity is this one and that are not `failed`.
    case identity(ContentIdentity)
    /// Records whose adoption key is this digest and that accept adoption (ADR-018).
    case digest(ContentHash)

    /// Whether `record` still wants the verified bytes (REENTRANCY R2, R4, R11).
    func accepts(_ record: AssetRecord) -> Bool {
        switch self {
        case .identity(let identity):
            if case .failed = record.residency {
                return false
            }
            return record.entry.contentIdentity == identity
        case .digest(let digest):
            return record.expectedBlob == digest && record.acceptsAdoption
        }
    }
}

/// How `acquireReference` gained its provisional reference.
enum ReferenceAcquisition: Sendable, Hashable {
    /// The key was unknown: this publication claimed it (`publishing`) and places the file exclusively.
    case new
    /// The key was live: one more reference; the existing file is kept if it is complete (dedupe).
    case reused
    /// The key was doomed `unreferenced`: rescued (ADR-018); if nothing ends up bound it is doomed again afresh
    /// with `previous`'s reason (ADR draft B-25).
    case rescued(previous: DoomInfo)
    /// The key was doomed `purged` or `corrupt`: the verified bytes replace the name (ADR-018, store-1 S1-06); the
    /// key is held in `publishing`, and its doom in `replacingDooms` (so every commit meanwhile still records it),
    /// until the replacement is in place.
    case replaced(previous: DoomInfo)
}

/// The reference discipline of ADR-018 and the shared tail of publication (ARCHITECTURE §4.3 steps 7–10; WP-B).
extension AssetStore {
    /// Releases one reference to `key`. A key left without references is doomed with `reason`, since the next
    /// snapshot version (it is absent from every snapshot built from now on) and dropped by the next generation
    /// (or `droppedInGeneration` when the caller knows better, e.g. `0` for a key no committed generation ever
    /// referenced, REENTRANCY R4).
    func releaseReference(_ key: BlobKey, dooming reason: DoomReason, droppedInGeneration: UInt64? = nil) {
        guard case .live(let references)? = self.state.core.blobTable[key] else {
            return
        }
        guard references <= 1 else {
            self.state.core.blobTable[key] = .live(references: references - 1)
            return
        }
        self.state.core.blobTable[key] = .doomed(
            DoomInfo(
                reason: reason,
                sinceSnapshotVersion: self.state.core.snapshots.version + 1,
                droppedInGeneration: droppedInGeneration ?? self.state.core.nextGeneration
            )
        )
        self.scheduleDoomedKey()
    }

    /// A key just became doomed: the generation that drops it and a snapshot without it are both made deadlines,
    /// so the deletion protocol advances even when no other mutation follows (a provisional reference dropped after
    /// a failed placement, review probe P3); otherwise the bytes would stay `pendingReclaim` for good.
    private func scheduleDoomedKey() {
        self.markDirtyInternal(.soon)
        self.state.core.snapshots.installDue = true
    }

    /// Gains a reference without I/O where that is safe: a live key, or a key doomed `unreferenced` whose file is
    /// still on disk (a rescue). Returns `false` for a key that is unknown, being deleted, or doomed `purged` or
    /// `corrupt` (never re-adopted, ADR-018).
    func gainReferenceInPlace(_ key: BlobKey) -> Bool {
        switch self.state.core.blobTable[key] {
        case .live(let references)?:
            self.state.core.blobTable[key] = .live(references: references + 1)
            return true
        case .doomed(let info)? where info.reason == .unreferenced:
            self.state.core.blobTable[key] = .live(references: 1)
            self.takeBackCountedRelease(of: key)
            return true
        default:
            return false
        }
    }

    /// Counts the bytes of a live blob that `apply` or `admit` just doomed toward the need of a quota eviction that
    /// measured before (`EvictionState.releasedBytes`, OI-14) and remembers the count in `countedReleases`, so that a
    /// rescue of the same doom takes it back.
    func countRelease(of key: BlobKey, bytes: Int64) {
        self.state.eviction.releasedBytes = self.state.eviction.releasedBytes.addingSaturating(bytes)
        self.state.core.countedReleases[key] = bytes
    }

    /// A doomed key just became live again (a rescue): its bytes are back in `FreeSpace.usedBytes`. If `apply` or
    /// `admit` counted that doom toward `EvictionState.releasedBytes`, the count is taken back, so a quota eviction
    /// that measured before the doom no longer counts bytes that did not stay released, and one that measured after it
    /// frees them again (R-CLN-4, REENTRANCY R13; Stage 3 S3B-9, close-out cycle 2: a content swap in one `apply`
    /// doomed a blob and rescued it in the next adoption, and an overlapping run stopped 100 bytes above its target).
    /// Returns the bytes taken back, or `nil` when no count of this doom was recorded.
    @discardableResult
    func takeBackCountedRelease(of key: BlobKey) -> Int64? {
        guard let bytes = self.state.core.countedReleases.removeValue(forKey: key) else {
            return nil
        }
        self.state.eviction.releasedBytes -= bytes
        return bytes
    }

    /// `setResidency(_:of:dooming:)`: moves a record to `residency`, releasing its previous blob (doomed with
    /// `reason` when that was the last reference). A transition to `present` is honoured only for a key that can be
    /// referenced in place (live, or rescuable); every other one leaves the record unchanged.
    func setResidencyInternal(_ residency: Residency, of id: AssetID, dooming reason: DoomReason) {
        guard var record = self.state.core.records[id] else {
            return
        }
        let previous = record.referencedBlob
        // A key being placed or replaced (`publishing`) cannot be referenced without I/O yet.
        if case .present(let blob, _, _) = residency, self.state.core.publishing.contains(blob) || !self.gainReferenceInPlace(blob) {
            return
        }
        record.residency = residency
        self.state.core.records[id] = record
        if let previous {
            self.releaseReference(previous, dooming: reason)
        }
        self.refreshPresentEntry(id)
        self.markDirtyInternal(.soon)
    }

    /// The one operation that gains a reference for a verified file (ADR-018, store-2 S2-01): it waits for an
    /// in-flight publication, replacement or deletion of the same key, then decides from the blob table as it is
    /// **now** (REENTRANCY R3), and holds a provisional reference until the caller binds its records. A new or
    /// replaced key is held in `publishing` until its placement unit finished, so binders of one key are serialised:
    /// nobody binds a record to a name whose file is still being written or replaced (review probe P1).
    func acquireReference(_ key: BlobKey) async throws(StoreError) -> ReferenceAcquisition {
        while true {
            try self.checkLive()
            if self.state.core.publishing.contains(key) {
                // REENTRANCY: R3 — the loop re-reads `publishing` and `blobTable[key]` once the other publication
                // finished its placement.
                await self.waitForKey(key)
                continue
            }
            switch self.state.core.blobTable[key] {
            case .deleting?:
                // REENTRANCY: R3 — the loop re-reads `blobTable[key]` once the deletion unit finished.
                await self.waitForKey(key)
            case .live(let references)?:
                self.state.core.blobTable[key] = .live(references: references + 1)
                return .reused
            case .doomed(let info)? where info.reason == .unreferenced:
                self.state.core.blobTable[key] = .live(references: 1)
                // The provisional reference brings the bytes back; a counted doom is taken back until the publication
                // either binds (the entry goes with the reference) or is doomed afresh (it counts again).
                if let bytes = self.takeBackCountedRelease(of: key) {
                    self.state.core.provisionallyRescued[key] = bytes
                }
                return .rescued(previous: info)
            case .doomed(let info)?:
                self.state.core.blobTable[key] = .live(references: 1)
                self.state.core.publishing.insert(key)
                // Until the replacement rename, the bytes under the name are still the doomed ones: a commit
                // captured meanwhile must keep the doom, or a crash would let launch adopt them (review round 2
                // probe 3, ADR draft B-24).
                self.state.core.replacingDooms[key] = info
                return .replaced(previous: info)
            case nil:
                self.state.core.publishing.insert(key)
                return .new
            }
        }
    }

    /// Steps 7–10 of publication for a file that is already verified: acquire the reference, then place and bind
    /// (`placeAndBind`). Throws `.superseded` when no record wants the bytes any more. Publishes no snapshot (callers
    /// decide the urgency, ARCHITECTURE §13.5 item 4).
    func bindVerifiedFile(
        at source: URL,
        sidecar: URL?,
        key: BlobKey,
        byteCount: Int64,
        ids: [AssetID],
        expecting expectation: BindingExpectation
    ) async throws(StoreError) -> (locations: [AssetID: AssetLocation], rescued: Bool) {
        // REENTRANCY: R3 — `acquireReference` re-reads the blob table after each of its waits.
        let acquisition = try await self.acquireReference(key)
        // REENTRANCY: R4 — `placeAndBind` re-validates every record after its placement unit.
        return try await self.placeAndBind(
            source: source,
            sidecar: sidecar,
            key: key,
            byteCount: byteCount,
            ids: ids,
            expecting: expectation,
            acquisition: acquisition
        )
    }

    /// Places `source` under `key` for a held acquisition (barrier, fan-out, exclusive rename, replacement or
    /// dedupe), then binds the records that still want these bytes (`bindRecords`).
    func placeAndBind(
        source: URL,
        sidecar: URL?,
        key: BlobKey,
        byteCount: Int64,
        ids: [AssetID],
        expecting expectation: BindingExpectation,
        acquisition: ReferenceAcquisition
    ) async throws(StoreError) -> (locations: [AssetID: AssetLocation], rescued: Bool) {
        guard let layout = self.state.core.layout else {
            self.abandonAcquisition(key, acquisition)
            throw .notOpen
        }
        let fileSystem = self.environment.fileSystem
        let reuse: Bool
        let replace: Bool
        switch acquisition {
        case .reused, .rescued:
            (reuse, replace) = (true, false)
        case .replaced:
            (reuse, replace) = (false, true)
        case .new:
            (reuse, replace) = (false, false)
        }
        // REENTRANCY: R4 — identity (or expectation) and extension are re-validated per record below; on a change
        // the key loses its provisional reference (doomed with `droppedInGeneration = 0` when it was new); no URL
        // is returned for a record that changed; `publishing[key]` is removed; every table update is
        // read-modify-write.
        let placement = await self.runUnit(on: self.environment.metadataExecutor) {
            BlobPlacementUnit.run(
                fileSystem: fileSystem,
                layout: layout,
                source: source,
                sidecar: sidecar,
                key: key,
                byteCount: byteCount,
                reuseExisting: reuse,
                replaceExisting: replace
            )
        }
        if placement.createdFanOut {
            // On failure too: the fan-out exists now, and the next placement into it cannot know it is new (review
            // round 3, probe 4), so `blobs/` is barrier-synced by the next commit either way.
            self.state.core.commits.blobsDirectoryDirty = true
        }
        switch placement.outcome {
        case .failure(let error):
            self.abandonAcquisition(key, acquisition)
            throw .fileSystem(error)
        case .success(let outcome):
            self.releasePublishing(key, acquisition)
            if acquisition == .new {
                self.state.core.blobTable[key] = .live(references: 1)
            }
            if outcome == .placed {
                self.state.core.blobBytes[key] = byteCount
            } else if self.state.core.blobBytes[key] == nil {
                self.state.core.blobBytes[key] = byteCount
            }
            self.state.core.orphans[key] = nil
            self.state.core.commits.dirtyFanOuts.insert(key.hash.fanOut)
            self.resumeKeyWaiters(key)
        }
        guard self.state.core.phase == .open || self.state.core.phase == .opening else {
            self.dropProvisionalReference(key, acquisition, boundAny: false)
            throw .closed
        }
        return try self.bindRecords(key: key, byteCount: byteCount, ids: ids, expecting: expectation, acquisition: acquisition)
    }

    /// Binds every id whose record still wants the bytes to `key`, whose file is in place, and drops the
    /// provisional reference. Synchronous: nothing can change between the decision and the binding. Throws
    /// `.superseded` when no record wants the bytes any more.
    func bindRecords(
        key: BlobKey,
        byteCount: Int64,
        ids: [AssetID],
        expecting expectation: BindingExpectation,
        acquisition: ReferenceAcquisition
    ) throws(StoreError) -> (locations: [AssetID: AssetLocation], rescued: Bool) {
        let now = self.environment.time.now()
        var locations: [AssetID: AssetLocation] = [:]
        for id in ids where locations[id] == nil {
            guard var record = self.state.core.records[id], expectation.accepts(record),
                AssetFileExtension(record.entry.fileExtension) == key.ext
            else {
                continue
            }
            let previous = record.referencedBlob
            if previous != key {
                _ = self.gainReferenceInPlace(key)
            }
            record.residency = .present(blob: key, byteSize: byteCount, integrity: record.entry.checksum == key.hash ? .verified : .unverified)
            record.integrity = .clean
            record.storedAt = now
            record.lastAccess = max(record.lastAccess, now)
            if record.entry.checksum == nil {
                // R-INT-6: a checksum-less entry records the digest of the bytes actually written.
                record.expectedBlob = key.hash
            }
            self.state.core.records[id] = record
            if let previous, previous != key {
                self.releaseReference(previous, dooming: .unreferenced)
            }
            self.refreshPresentEntry(id)
            if let location = self.state.core.presentTable[id]?.location {
                locations[id] = location
            }
        }
        self.dropProvisionalReference(key, acquisition, boundAny: !locations.isEmpty)
        self.markDirtyInternal(.soon)
        guard !locations.isEmpty else {
            throw .superseded(ids.first ?? AssetID(""))
        }
        let rescued: Bool
        if case .rescued = acquisition {
            rescued = true
        } else {
            rescued = false
        }
        return (locations, rescued)
    }

    /// Gives up an acquisition before anything was bound: the key leaves `publishing`, the provisional reference is
    /// dropped (a rescued or replaced key gets its doom back) and the binders waiting for the key are resumed.
    func abandonAcquisition(_ key: BlobKey, _ acquisition: ReferenceAcquisition) {
        self.releasePublishing(key, acquisition)
        self.dropProvisionalReference(key, acquisition, boundAny: false)
        self.resumeKeyWaiters(key)
    }

    /// A new or replaced key leaves `publishing` once its placement finished (or was given up); a replaced key's
    /// persisted doom goes with it (the bytes under the name are now the verified ones, or the doom is renewed by
    /// `dropProvisionalReference` in the same turn).
    private func releasePublishing(_ key: BlobKey, _ acquisition: ReferenceAcquisition) {
        switch acquisition {
        case .new:
            self.state.core.publishing.remove(key)
        case .replaced:
            self.state.core.publishing.remove(key)
            self.state.core.replacingDooms[key] = nil
        case .reused, .rescued:
            break
        }
    }

    /// Releases the provisional reference `acquireReference` took. A rescued or replaced key that ended up bound to
    /// nothing is doomed again with its previous reason, but **afresh** (ADR draft B-25): while the reference was
    /// held the key was live, so another record may have gained it, appeared in an acknowledged snapshot and lost it
    /// again (a plain decrement, no doom); the old `eligibleAt` would then let the reaper unlink it with no grace
    /// after the snapshot that dropped it (I-3, review round 2 probe 1). A new key that ended up bound to nothing is
    /// doomed as never committed (`droppedInGeneration = 0`, REENTRANCY R4).
    private func dropProvisionalReference(_ key: BlobKey, _ acquisition: ReferenceAcquisition, boundAny: Bool) {
        switch acquisition {
        case .rescued(let previous), .replaced(let previous):
            if !boundAny, case .live(references: 1)? = self.state.core.blobTable[key] {
                self.state.core.blobTable[key] = .doomed(
                    DoomInfo(
                        reason: previous.reason,
                        sinceSnapshotVersion: self.state.core.snapshots.version + 1,
                        droppedInGeneration: max(previous.droppedInGeneration, self.state.core.nextGeneration),
                        failedUnlinks: previous.failedUnlinks
                    )
                )
                self.scheduleDoomedKey()
                // The bytes left `usedBytes` again: a count a rescue took back counts again.
                if let bytes = self.state.core.provisionallyRescued.removeValue(forKey: key) {
                    self.countRelease(of: key, bytes: bytes)
                }
                return
            }
            // Bound, or held by another reference: the bytes stay in `usedBytes`.
            self.state.core.provisionallyRescued[key] = nil
            self.releaseReference(key, dooming: .unreferenced)
        case .new:
            if case .live? = self.state.core.blobTable[key] {
                self.releaseReference(key, dooming: .unreferenced, droppedInGeneration: 0)
            }
        case .reused:
            self.releaseReference(key, dooming: .unreferenced)
        }
    }
}
