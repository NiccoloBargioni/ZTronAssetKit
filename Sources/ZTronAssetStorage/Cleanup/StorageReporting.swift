import Foundation
import ZTronAssetModel

/// `storageReport()` (R-CLN-9).
extension AssetStore {
    /// Builds the report: one free-space unit and one staging listing (only once open) and one bulk unit for the
    /// evictable bytes, then the other figures from the state as it is after those awaits.
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
        // REENTRANCY: R13 — nothing: the evictable bytes are a snapshot computed off the actor (C2); the other figures
        // are read from the state after this await.
        let evictable = await self.evictionCandidatesOffActor().reduce(Int64(0)) { $0.addingSaturating($1.bytes) }
        let core = self.state.core
        var byKind: [String: Int64] = [:]
        var present: Int64 = 0
        var stale: Int64 = 0
        var pinned: Int64 = 0
        var essential: Int64 = 0
        for (key, ids) in self.referenceIndex() {
            guard case .live? = core.blobTable[key] else {
                continue
            }
            let records = ids.compactMap { core.records[$0] }
            let bytes = records.first.map(EvictionOrder.recordedSize) ?? 0
            byKind[key.ext.rawValue, default: 0] = byKind[key.ext.rawValue, default: 0].addingSaturating(bytes)
            if records.contains(where: { !$0.isStale }) {
                present = present.addingSaturating(bytes)
            } else {
                stale = stale.addingSaturating(bytes)
            }
            if records.contains(where: \.pinned) {
                pinned = pinned.addingSaturating(bytes)
            }
            if records.contains(where: { $0.entry.policy == .essential }) {
                essential = essential.addingSaturating(bytes)
            }
        }
        // Doomed bytes: the unleased ones from `freeSpace()`, the leased ones from the sizes recorded with the leases.
        var pending = space?.pendingReclaim ?? 0
        for (key, bytes) in self.state.cleanup.leasedBytes where !(self.state.cleanup.leases[key]?.isEmpty ?? true) {
            switch core.blobTable[key] {
            case .doomed?, .deleting?:
                pending = pending.addingSaturating(bytes)
            case .live?, nil:
                break
            }
        }
        // O(1) per orphan: one doomed or claimed since the last GC is no longer an orphan.
        let orphans = (self.state.cleanup.orphans ?? [:]).filter { core.blobTable[$0.key] == nil && !core.publishing.contains($0.key) }
            .values.reduce(Int64(0)) { $0.addingSaturating($1) }
        let unverified = core.records.values.filter { record in
            if case .present(_, _, .unverified) = record.residency {
                return true
            }
            return false
        }.count
        return StorageReport(
            bytesByKind: byKind,
            bytesByState: ResidencyBytes(present: present, stale: stale, pendingDeletion: pending),
            pinnedBytes: pinned,
            essentialBytes: essential,
            evictableBytes: evictable,
            stagingBytes: stagingBytes,
            orphanBytes: orphans,
            sourceCopyBytes: 0,
            budgetBytes: space?.budgetBytes ?? 0,
            freeBytesImportant: space?.volumeImportant ?? 0,
            freeBytesOpportunistic: space?.volumeOpportunistic ?? 0,
            unverifiedCount: unverified,
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
