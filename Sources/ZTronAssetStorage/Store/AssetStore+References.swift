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
    /// The key was doomed `unreferenced`: rescued (ADR-018); `previous` is restored if nothing ends up bound.
    case rescued(previous: DoomInfo)
    /// The key was doomed `purged` or `corrupt`: the verified bytes replace the name (ADR-018, store-1 S1-06).
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
            return true
        default:
            return false
        }
    }

    /// `setResidency(_:of:dooming:)`: moves a record to `residency`, releasing its previous blob (doomed with
    /// `reason` when that was the last reference). A transition to `present` is honoured only for a key that can be
    /// referenced in place (live, or rescuable); every other one leaves the record unchanged.
    func setResidencyInternal(_ residency: Residency, of id: AssetID, dooming reason: DoomReason) {
        guard var record = self.state.core.records[id] else {
            return
        }
        let previous = record.referencedBlob
        if case .present(let blob, _, _) = residency, !self.gainReferenceInPlace(blob) {
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
    /// in-flight publication or deletion of the same key, then decides from the blob table as it is **now**
    /// (REENTRANCY R3), and holds a provisional reference until the caller binds its records.
    func acquireReference(_ key: BlobKey) async throws(StoreError) -> ReferenceAcquisition {
        while true {
            try self.checkLive()
            switch self.state.core.blobTable[key] {
            case .deleting?:
                // REENTRANCY: R3 — the loop re-reads `blobTable[key]` once the deletion unit finished.
                await self.waitForKey(key)
            case nil where self.state.core.publishing.contains(key):
                // REENTRANCY: R3 — the loop re-reads `blobTable[key]` once the other publication finished.
                await self.waitForKey(key)
            case .live(let references)?:
                self.state.core.blobTable[key] = .live(references: references + 1)
                return .reused
            case .doomed(let info)? where info.reason == .unreferenced:
                self.state.core.blobTable[key] = .live(references: 1)
                return .rescued(previous: info)
            case .doomed(let info)?:
                self.state.core.blobTable[key] = .live(references: 1)
                return .replaced(previous: info)
            case nil:
                self.state.core.publishing.insert(key)
                return .new
            }
        }
    }

    /// Steps 7–10 of publication for a file that is already verified: acquire the reference, place the file
    /// (barrier, fan-out, exclusive rename, or dedupe), re-validate every record after the await, bind the ones
    /// that still want these bytes, and drop the provisional reference. Throws `.superseded` when none does.
    /// Publishes no snapshot (callers decide the urgency, ARCHITECTURE §13.5 item 4).
    func bindVerifiedFile(
        at source: URL,
        sidecar: URL?,
        key: BlobKey,
        byteCount: Int64,
        ids: [AssetID],
        expecting expectation: BindingExpectation
    ) async throws(StoreError) -> (locations: [AssetID: AssetLocation], rescued: Bool) {
        guard let layout = self.state.core.layout else {
            throw .notOpen
        }
        // REENTRANCY: R3 — `acquireReference` re-reads the blob table after each of its waits.
        let acquisition = try await self.acquireReference(key)
        let fileSystem = self.environment.fileSystem
        let reuse = acquisition == .reused || { if case .rescued = acquisition { return true } else { return false } }()
        let replace: Bool = {
            if case .replaced = acquisition {
                return true
            }
            return false
        }()
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
        if acquisition == .new {
            self.state.core.publishing.remove(key)
        }
        switch placement {
        case .failure(let error):
            self.dropProvisionalReference(key, acquisition, boundAny: false)
            self.resumeKeyWaiters(key)
            throw .fileSystem(error)
        case .success(let outcome):
            if acquisition == .new {
                self.state.core.blobTable[key] = .live(references: 1)
            }
            if case .placed(createdFanOut: true) = outcome {
                self.state.core.commits.blobsDirectoryDirty = true
            }
            if case .placed = outcome {
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

    /// Releases the provisional reference `acquireReference` took. A rescued or replaced key that ended up bound to
    /// nothing gets its previous doom back (its dropping generation may not be committed yet); a new key that ended
    /// up bound to nothing is doomed as never committed (`droppedInGeneration = 0`, REENTRANCY R4).
    private func dropProvisionalReference(_ key: BlobKey, _ acquisition: ReferenceAcquisition, boundAny: Bool) {
        switch acquisition {
        case .rescued(let previous), .replaced(let previous):
            if !boundAny, case .live(references: 1)? = self.state.core.blobTable[key] {
                self.state.core.blobTable[key] = .doomed(previous)
                return
            }
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
