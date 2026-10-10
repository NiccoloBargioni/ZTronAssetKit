import Foundation
import ZTronAssetModel

/// `storageReport()` (R-CLN-9).
extension AssetStore {
    /// Builds the report: one free-space unit and one staging listing (only once open), then one bulk unit that sums
    /// the records and the evictable bytes from a value snapshot (C2: the per-blob sums held the actor 3.7 ms at 10,000
    /// records and 63 ms at `maxEntries`, review round 3), then the few figures O(1) per lease or orphan on the actor.
    func performStorageReport() async -> StorageReport {
        var space: FreeSpace?
        var stagingBytes: Int64 = 0
        // REENTRANCY: R1 — nothing was read before it; a store that is not open reports without I/O.
        if (try? await self.awaitOpen()) != nil {
            // REENTRANCY: R13 — the figures are a snapshot; the state is read after the await.
            space = try? await self.freeSpace()
            // REENTRANCY: c-2 (proposed) — nothing: the staging size is a snapshot; the state is read afterwards.
            stagingBytes = await self.measureStagingBytes()
        }
        let rules = EvictionOrder.Rules(
            policy: self.configuration.policy,
            scope: self.state.eviction.retentionScope,
            protecting: [],
            now: self.environment.time.now()
        )
        let records = self.state.core.records
        let blobTable = self.state.core.blobTable
        let publishing = self.state.core.publishing
        let leases = self.state.cleanup.leases
        // REENTRANCY: c-2 (proposed), R13 — nothing: the sums describe the snapshot taken when the unit was submitted;
        // the pending and orphan bytes are read from the state after it.
        let figures = await self.runUnit(on: self.environment.bulkExecutor) {
            StorageFigures(records: records, blobTable: blobTable, publishing: publishing, leases: leases, rules: rules)
        }
        // Doomed bytes: the unleased ones from `freeSpace()`, the leased ones from the sizes recorded with the leases.
        var pending = space?.pendingReclaim ?? 0
        for (key, bytes) in self.state.cleanup.leasedBytes where !(self.state.cleanup.leases[key]?.isEmpty ?? true) {
            switch self.state.core.blobTable[key] {
            case .doomed?, .deleting?:
                pending = pending.addingSaturating(bytes)
            case .live?, nil:
                break
            }
        }
        // O(1) per orphan: one doomed or claimed since the last GC is no longer an orphan.
        let orphans = (self.state.cleanup.orphans ?? [:]).filter { self.state.core.blobTable[$0.key] == nil && !self.state.core.publishing.contains($0.key) }
            .values.reduce(Int64(0)) { $0.addingSaturating($1) }
        return StorageReport(
            bytesByKind: figures.bytesByKind,
            bytesByState: ResidencyBytes(present: figures.present, stale: figures.stale, pendingDeletion: pending),
            pinnedBytes: figures.pinned,
            essentialBytes: figures.essential,
            evictableBytes: figures.evictable,
            stagingBytes: stagingBytes,
            orphanBytes: orphans,
            sourceCopyBytes: 0,
            budgetBytes: space?.budgetBytes ?? 0,
            freeBytesImportant: space?.volumeImportant ?? 0,
            freeBytesOpportunistic: space?.volumeOpportunistic ?? 0,
            unverifiedCount: figures.unverified,
            lastCleanupAt: self.state.cleanup.lastCleanupAt
        )
    }

    /// The bytes of every file directly under `staging/` (one listing unit); 0 when it cannot be listed.
    func measureStagingBytes() async -> Int64 {
        guard let layout = self.state.core.layout else {
            return 0
        }
        let fileSystem = self.environment.fileSystem
        let directory = layout.stagingDirectory
        // REENTRANCY: c-2 (proposed) — nothing: the sum is a snapshot of the directory.
        let listing = await self.runUnit(on: self.environment.metadataExecutor) {
            CleanupUnits.list(directory, fileSystem: fileSystem)
        }
        guard case .success(let items) = listing else {
            return 0
        }
        return items.filter { $0.kind == .file }.reduce(Int64(0)) { $0.addingSaturating($1.byteSize) }
    }
}

/// The figures of the storage report that sum over every record (pure; computed on the bulk executor, C2).
struct StorageFigures: Sendable, Hashable {
    /// Live bytes by the blob's extension.
    var bytesByKind: [String: Int64] = [:]
    /// Live bytes a current record still wants.
    var present: Int64 = 0
    /// Live bytes only stale records hold.
    var stale: Int64 = 0
    /// Live bytes a pinned record holds.
    var pinned: Int64 = 0
    /// Live bytes an essential record holds.
    var essential: Int64 = 0
    /// What quota eviction could take (`EvictionOrder.candidates`).
    var evictable: Int64 = 0
    /// Present records not verified against a checksum.
    var unverified = 0

    /// Sums `records` over the live blobs of `blobTable` (ADR draft C-11).
    init(records: [AssetID: AssetRecord], blobTable: [BlobKey: BlobState], publishing: Set<BlobKey>, leases: [BlobKey: [UInt64: AssetID]], rules: EvictionOrder.Rules) {
        self.evictable = EvictionOrder.candidates(records: records, blobTable: blobTable, publishing: publishing, leases: leases, rules: rules)
            .reduce(Int64(0)) { $0.addingSaturating($1.bytes) }
        var byKey: [BlobKey: [AssetRecord]] = [:]
        for record in records.values {
            if case .present(_, _, .unverified) = record.residency {
                self.unverified += 1
            }
            if let key = record.referencedBlob {
                byKey[key, default: []].append(record)
            }
        }
        for (key, holders) in byKey {
            guard case .live? = blobTable[key] else {
                continue
            }
            let bytes = holders.first.map(EvictionOrder.recordedSize) ?? 0
            self.bytesByKind[key.ext.rawValue, default: 0] = self.bytesByKind[key.ext.rawValue, default: 0].addingSaturating(bytes)
            if holders.contains(where: { !$0.isStale }) {
                self.present = self.present.addingSaturating(bytes)
            } else {
                self.stale = self.stale.addingSaturating(bytes)
            }
            if holders.contains(where: \.pinned) {
                self.pinned = self.pinned.addingSaturating(bytes)
            }
            if holders.contains(where: { $0.entry.policy == .essential }) {
                self.essential = self.essential.addingSaturating(bytes)
            }
        }
    }
}
