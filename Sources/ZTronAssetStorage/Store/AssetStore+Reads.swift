import Foundation
import ZTronAssetModel

/// The store's reads: values from actor state, no I/O except `freeSpace()` and `stagingInventory()`, each one unit
/// (R-SYN-1, R-SYN-10, R-SYN-11, ADR-028; WP-B).
extension AssetStore {
    /// `planningView()`: values only; the dictionaries are copy-on-write (the live-blob set is derived per call).
    func makePlanningView() throws(StoreError) -> StorePlanningView {
        try self.ensureOpenInternal()
        let core = self.state.core
        var live: Set<ContentHash> = []
        for (key, blobState) in core.blobTable {
            if case .live = blobState {
                live.insert(key.hash)
            }
        }
        return StorePlanningView(
            generation: core.committedGeneration,
            appliedManifest: core.appliedManifest,
            records: core.records,
            liveBlobs: live,
            purgeEpoch: core.purgeEpoch,
            stamp: core.stamp,
            syncDue: core.syncDue
        )
    }

    /// `location(for:extensions:recordingAccess:)`: the current state's location (never a stale snapshot copy,
    /// store-2 S2-12), matched case-insensitively against `extensions` (any when empty).
    func currentLocation(for id: AssetID, extensions: [String], recordingAccess: Bool) -> AssetLocation? {
        guard self.state.core.phase == .open, let entry = self.state.core.presentTable[id] else {
            return nil
        }
        let wanted = entry.location.fileExtension
        guard extensions.isEmpty || extensions.contains(where: { AssetFileExtension($0) == wanted }) else {
            return nil
        }
        if recordingAccess, var record = self.state.core.records[id] {
            let now = self.environment.time.now()
            if now > record.lastAccess {
                record.lastAccess = now
                self.state.core.records[id] = record
                self.markDirtyInternal(.lazy)
            }
        }
        return entry.location
    }

    /// `availability(of:)`: counts over the applied entries in `scope`; `manifestFresh` is the engine's to set.
    func currentAvailability(of scope: AssetScope) -> AvailabilityReport {
        var report = AvailabilityReport(
            scope: scope,
            total: 0,
            present: 0,
            missing: 0,
            stale: 0,
            failed: 0,
            unverified: 0,
            bytesMissing: 0,
            manifestFresh: false,
            generation: self.state.core.committedGeneration
        )
        guard self.state.core.phase == .open else {
            return report
        }
        for entry in self.state.core.appliedManifest.entries where scope.contains(entry) {
            report.total += 1
            let record = self.state.core.records[entry.identifier]
            switch record?.residency {
            case .present(_, _, let integrity)?:
                if record?.isStale == true {
                    report.stale += 1
                } else {
                    report.present += 1
                }
                if integrity == .unverified {
                    report.unverified += 1
                }
            case .absent?, .needsHeal?, nil:
                // The sizes are the manifest's, and `maxAssetBytes = Int64.max` is a supported cap, so the sum saturates
                // as every other figure built from manifest sizes does (S3-SECU-01, R-MAN-2): a hostile manifest must
                // not trap the process.
                report.missing += 1
                report.bytesMissing = report.bytesMissing.addingSaturating(max(0, entry.byteSize ?? 0))
            case .quarantined?, .failed?:
                report.failed += 1
            }
        }
        return report
    }

    /// `freeSpace()`: one unit reads both capacities; usage and pending reclaim come from the blob table
    /// (store-2 S2-06), the budget from the policy (REENTRANCY R13).
    func measureFreeSpace() async throws(StoreError) -> FreeSpace {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        guard let layout = self.state.core.layout else {
            throw .notOpen
        }
        let fileSystem = self.environment.fileSystem
        // REENTRANCY: R13 — the figures are a snapshot; the phase is re-checked; `apply` re-validates each victim.
        let capacities = await self.runUnit(on: self.environment.metadataExecutor) { () -> Result<(Int64, Int64), FileSystemError> in
            do throws(FileSystemError) {
                let important = try fileSystem.availableCapacity(at: layout.root, for: .important)
                let opportunistic = try fileSystem.availableCapacity(at: layout.root, for: .opportunistic)
                return .success((important, opportunistic))
            } catch {
                return .failure(error)
            }
        }
        try self.checkLive()
        let (important, opportunistic): (Int64, Int64)
        switch capacities {
        case .success(let values):
            (important, opportunistic) = values
        case .failure(let error):
            throw .fileSystem(error)
        }
        var used: Int64 = 0
        var pending: Int64 = 0
        for (key, blobState) in self.state.core.blobTable {
            let bytes = self.state.core.blobBytes[key] ?? 0
            switch blobState {
            case .live:
                used += bytes
            case .doomed, .deleting:
                if self.state.cleanup.leases[key]?.isEmpty ?? true {
                    pending += bytes
                }
            }
        }
        let policy = self.configuration.policy
        return FreeSpace(
            volumeImportant: important,
            volumeOpportunistic: opportunistic,
            usedBytes: used,
            pendingReclaim: pending,
            budgetBytes: policy.budget.resolve(usedBytes: used, availableBytes: important),
            reserveBytes: policy.reserveFreeBytes
        )
    }

    /// `stagingInventory()`: one listing of `staging/` (REENTRANCY R14); regular files with our names are items,
    /// everything else is foreign.
    func listStaging() async throws(StoreError) -> StagingInventory {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        guard let layout = self.state.core.layout else {
            throw .notOpen
        }
        let fileSystem = self.environment.fileSystem
        // REENTRANCY: R14 — the listing is a snapshot of `staging/`; the phase is re-checked; GC decides later against
        // the caller's claims.
        let listing = await self.runUnit(on: self.environment.metadataExecutor) { () -> Result<[FileItemInfo], FileSystemError> in
            do throws(FileSystemError) {
                return .success(try fileSystem.contentsOfDirectory(at: layout.stagingDirectory))
            } catch {
                return .failure(error)
            }
        }
        try self.checkLive()
        let items: [FileItemInfo]
        switch listing {
        case .success(let values):
            items = values
        case .failure(let error):
            throw .fileSystem(error)
        }
        var inventory = StagingInventory(items: [:], foreign: [])
        for item in items {
            if item.kind == .file, let name = StagingFileName(parsing: item.name) {
                inventory.items[name] = item
            } else {
                inventory.foreign.append(item.name)
            }
        }
        inventory.foreign.sort()
        return inventory
    }

    /// `ensureOpen()`: `.notOpen` while created or opening, `.closed` once `close()` began.
    func ensureOpenInternal() throws(StoreError) {
        switch self.state.core.phase {
        case .open:
            return
        case .created, .opening:
            throw .notOpen
        case .closing, .closed:
            throw .closed
        }
    }
}
