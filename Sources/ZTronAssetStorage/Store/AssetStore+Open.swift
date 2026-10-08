import Foundation
import ZTronAssetModel

/// `open()` (ARCHITECTURE §4.5, store.md §2.6 as amended by ADR-028/029; WP-B): resolve and create the root →
/// lock → attributes, `blobs/`, `staging/` → load (§4.2) → list blobs → reconcile → OS-purge detection → legacy
/// phase 1 (WP-C's hook, opt-in) → root barrier → commit → first snapshot → delete foreign names. Staging is not
/// listed here (the engine's launch reconciliation does it, ADR-028).
extension AssetStore {
    /// Opens once; a second call returns the first report; a failed open releases the lock and can be retried.
    func performOpen() async throws(StoreError) -> OpenReport {
        switch self.state.core.phase {
        case .open:
            if let report = self.state.core.openReport {
                return report
            }
        case .opening:
            // REENTRANCY: R1 — the report is read after the running open finished.
            try await self.awaitOpen()
            if let report = self.state.core.openReport {
                return report
            }
            throw .notOpen
        case .closing, .closed:
            throw .closed
        case .created:
            break
        }
        self.state.core.phase = .opening
        do throws(StoreError) {
            // REENTRANCY: R1 — every step re-checks the phase (`opening`); other APIs await `open()` meanwhile.
            let report = try await self.openSteps()
            self.state.core.openReport = report
            self.state.core.phase = .open
            self.resumeOpenWaiters()
            return report
        } catch {
            if let lock = self.state.core.lock {
                let fileSystem = self.environment.fileSystem
                // REENTRANCY: R1 — nothing: the open failed and the state is reset below.
                await self.runUnit(on: self.environment.metadataExecutor) {
                    fileSystem.releaseLock(lock)
                }
            }
            // Waiters are resumed before the reset; they run after this turn and find the store `created` again.
            self.resumeOpenWaiters()
            self.state = StoreState()
            throw error
        }
    }

    private func openSteps() async throws(StoreError) -> OpenReport {
        let fileSystem = self.environment.fileSystem
        let location = self.configuration.location
        // REENTRANCY: R1 — phase `opening`.
        let prepared = try await self.runUnit(on: self.environment.metadataExecutor) {
            OpenUnits.prepare(fileSystem: fileSystem, location: location)
        }.get()
        self.state.core.layout = prepared.layout
        self.state.core.lock = prepared.lock
        try self.checkLive()
        let layout = prepared.layout
        // REENTRANCY: R1 — phase `opening`.
        let reads = try await self.readIndexFiles(layout)
        // REENTRANCY: R1 — phase `opening`; decoding runs off the actor.
        let outcome = await self.runUnit(on: self.environment.bulkExecutor) {
            IndexLoadRule.choose(reads)
        }
        // REENTRANCY: R1 — phase `opening`.
        let listing = try await self.listBlobs(layout)
        try self.checkLive()
        let reconciled = self.installLoadedState(outcome, listing: listing, blobsRecreated: prepared.blobsRecreated)
        var legacyPending = false
        if self.configuration.legacy.enabled {
            // REENTRANCY: R1, R11 — phase `opening`; WP-C's phase 1 re-validates its own steps.
            legacyPending = try await self.runLegacyPhaseOne()
            try self.checkLive()
        }
        // ADR-015: the root's listing is ordered before any launch deletion, even if the commit below fails.
        // REENTRANCY: R1 — phase `opening`; a failed barrier is retried by the commit's own root sync.
        _ = await self.runUnit(on: self.environment.metadataExecutor) { () -> Bool in
            (try? fileSystem.synchronizeDirectory(at: layout.root, level: .barrier)) != nil
        }
        try self.checkLive()
        do throws(StoreError) {
            // REENTRANCY: R5 — phase `opening`; a failure leaves the state dirty and the store serves it read-only
            // until a later commit succeeds (store-1 S1-07).
            try await self.commitNow(.ordered)
        } catch {
            self.environment.log.log(.store, .error, "launch commit failed; serving the loaded state")
        }
        try self.checkLive()
        // REENTRANCY: R6 — phase `opening`; the acknowledgement is folded in by `installSnapshot`.
        await self.installSnapshot()
        try self.checkLive()
        // REENTRANCY: R1 — phase `opening`; foreign names were never handed out, so they need no grace.
        await self.deleteForeign(listing.foreign)
        try self.checkLive()
        if reconciled.osPurgeDetected {
            self.environment.log.log(.store, .info, "OS purge detected: \(reconciled.missingBlobs) blobs missing; sync due")
        }
        return OpenReport(
            launchEpoch: self.state.core.launchEpoch,
            generation: self.state.core.committedGeneration,
            degraded: self.state.core.degraded,
            missingBlobs: reconciled.missingBlobs,
            legacyMigrationPending: legacyPending,
            stamp: self.state.core.stamp,
            syncDue: self.state.core.syncDue
        )
    }

    /// Installs the loaded and reconciled generation as the store's state, synchronously.
    private func installLoadedState(_ outcome: IndexLoadOutcome, listing: BlobListing, blobsRecreated: Bool) -> LaunchReconciliation.Result {
        let content = outcome.content ?? IndexContent.empty(storeID: StoreIdentifier.derived(fromSeed: self.environment.random.seed))
        self.state.core.storeID = content.storeID == .zero ? StoreIdentifier.derived(fromSeed: self.environment.random.seed) : content.storeID
        self.state.core.nextGeneration = max(outcome.nextGeneration, 1)
        self.state.core.committedGeneration = content.generation
        // The launch epoch is the generation the launch commit carries: persisted and strictly increasing (ADR-013).
        self.state.core.launchEpoch = self.state.core.nextGeneration
        let reconciled = LaunchReconciliation.reconcile(
            content: content,
            onDisk: listing.onDisk,
            blobsRecreated: blobsRecreated,
            openGeneration: self.state.core.launchEpoch,
            now: self.environment.time.now()
        )
        self.state.core.records = reconciled.records
        self.state.core.blobTable = reconciled.blobTable
        self.state.core.blobBytes = reconciled.blobBytes
        self.state.core.orphans = reconciled.orphans
        self.state.core.appliedManifest = content.appliedManifest
        self.state.core.etag = content.etag
        self.state.core.stamp = reconciled.osPurgeDetected ? nil : content.stamp
        self.state.core.syncDue = reconciled.osPurgeDetected || content.syncDue
        // No valid index although blobs exist (or an index existed but failed): degraded until the next `apply`
        // plus adoption (R-STO-4, store-1 S1-11).
        self.state.core.degraded = outcome.degraded || (outcome.content == nil && !listing.onDisk.isEmpty)
        self.state.migration.phase = content.legacyPhase
        self.state.migration.legacyStamp = content.legacyStamp
        self.state.cleanup.lastCleanupAt = content.lastCleanupAt
        self.state.core.metrics.doomedRepairs += reconciled.doomedRepairs
        if let layout = self.state.core.layout {
            self.state.core.presentTable = SnapshotTable.build(records: reconciled.records, layout: layout)
        }
        self.state.core.commits.dirtyFanOuts = reconciled.adoptedFanOuts
        self.state.core.commits.blobsDirectoryDirty = true
        self.markDirtyInternal(.soon)
        return reconciled
    }

    /// Reads `index.bin`, `index.tmp` and `index.prev` in ≤ 1 MiB units (only the header of a file too large to be
    /// valid). A read failure leaves what was read, which the load rule then sees as torn.
    private func readIndexFiles(_ layout: StoreLayout) async throws(StoreError) -> [IndexFile: IndexFileRead] {
        let fileSystem = self.environment.fileSystem
        // REENTRANCY: R1 — phase `opening`.
        let sizes = await self.runUnit(on: self.environment.metadataExecutor) { () -> [IndexFile: Int64] in
            var sizes: [IndexFile: Int64] = [:]
            for file in IndexFile.allCases {
                if let info = try? fileSystem.itemInfo(at: layout.indexURL(file)), info.kind == .file {
                    sizes[file] = info.byteSize
                }
            }
            return sizes
        }
        try self.checkLive()
        var reads: [IndexFile: IndexFileRead] = [:]
        for file in IndexFile.allCases {
            guard let size = sizes[file] else {
                continue
            }
            let url = layout.indexURL(file)
            let wanted = size <= IndexHeader.maxFileLength ? size : Int64(IndexHeader.length)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(Int(wanted))
            reading: while Int64(bytes.count) < wanted {
                let offset = Int64(bytes.count)
                let length = Int(min(Int64(1 << 20), wanted - offset))
                // REENTRANCY: R1 — phase `opening`.
                let chunk = await self.runUnit(on: self.environment.metadataExecutor) {
                    try? fileSystem.read(from: url, offset: offset, maxLength: length)
                }
                try self.checkLive()
                guard let chunk, !chunk.isEmpty else {
                    break reading
                }
                bytes.append(contentsOf: chunk)
            }
            reads[file] = IndexFileRead(size: size, bytes: bytes)
        }
        return reads
    }

    /// Lists `blobs/` and every fan-out (one unit each); everything that is not a well-named blob in its fan-out is
    /// foreign.
    private func listBlobs(_ layout: StoreLayout) async throws(StoreError) -> BlobListing {
        let fileSystem = self.environment.fileSystem
        // REENTRANCY: R1 — phase `opening`.
        let top = try await self.runUnit(on: self.environment.metadataExecutor) { () -> Result<[FileItemInfo], StoreError> in
            do throws(FileSystemError) {
                return .success(try fileSystem.contentsOfDirectory(at: layout.blobsDirectory))
            } catch {
                return .failure(.fileSystem(error))
            }
        }.get()
        try self.checkLive()
        var listing = BlobListing(onDisk: [:], foreign: [])
        var fanOuts: [String] = []
        for item in top.sorted(by: { $0.name < $1.name }) {
            if item.kind == .directory, OpenUnits.isFanOutName(item.name) {
                fanOuts.append(item.name)
            } else {
                listing.foreign.append(layout.blobsDirectory.appendingPathComponent(item.name, isDirectory: item.kind == .directory))
            }
        }
        for fanOut in fanOuts {
            let directory = layout.blobsDirectory.appendingPathComponent(fanOut, isDirectory: true)
            // REENTRANCY: R1 — phase `opening`.
            let items = try await self.runUnit(on: self.environment.metadataExecutor) { () -> Result<[FileItemInfo], StoreError> in
                do throws(FileSystemError) {
                    return .success(try fileSystem.contentsOfDirectory(at: directory))
                } catch {
                    return .failure(.fileSystem(error))
                }
            }.get()
            try self.checkLive()
            OpenUnits.classify(fanOut: fanOut, items: items, layout: layout, into: &listing)
        }
        listing.foreign.sort { $0.path < $1.path }
        return listing
    }

    /// Removes foreign names under `blobs/` in units of `deletionBatchSize`; a non-empty foreign directory stays.
    private func deleteForeign(_ urls: [URL]) async {
        guard !urls.isEmpty else {
            return
        }
        let fileSystem = self.environment.fileSystem
        let batchSize = max(1, self.configuration.deletionBatchSize)
        var start = 0
        while start < urls.count {
            let batch = Array(urls[start..<min(start + batchSize, urls.count)])
            start += batchSize
            // REENTRANCY: R1 — nothing: foreign names are not in any table.
            await self.runUnit(on: self.environment.metadataExecutor) {
                for url in batch {
                    try? fileSystem.removeItem(at: url)
                }
            }
        }
    }
}
