import Foundation
import ZTronAssetModel

/// `open()` (ARCHITECTURE §4.5, store.md §2.6 as amended by ADR-028/029; WP-B): resolve and create the root →
/// lock → attributes, `blobs/`, `staging/` → load (§4.2) → list blobs → reconcile → OS-purge detection → legacy
/// phase 1 (WP-C's hook, opt-in) → root barrier → commit → first snapshot → delete foreign names. Staging is not
/// listed here (the engine's launch reconciliation does it, ADR-028).
extension AssetStore {
    /// Opens once; a second call returns the first report; a failed open releases the lock and can be retried.
    ///
    /// A call made while an open runs returns that open's report once it succeeded, even when a `close()` began before
    /// the call resumed (the call overlapped the open, so it may return like a call made just before the close), and
    /// throws `.notOpen` when that open failed. Its outcome is handed over by the running open rather than read from the
    /// phase afterwards, so it never depends on the order in which the scheduler resumes the waiters (ADR draft B-35).
    func performOpen() async throws(StoreError) -> OpenReport {
        switch self.state.core.phase {
        case .open:
            if let report = self.state.core.openReport {
                return report
            }
        case .opening:
            // REENTRANCY: R1 — nothing is re-read: the running open hands this call its own outcome (`resumeOpenWaiters`),
            // so whatever ran on the store between that open's end and this resumption cannot change it.
            let report = await withCheckedContinuation { (continuation: CheckedContinuation<OpenReport?, Never>) in
                self.state.core.openReportWaiters.append(continuation)
            }
            guard let report else {
                throw .notOpen
            }
            return report
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
        // REENTRANCY: R1 — phase `opening`; reading and decoding run off the actor (`IndexLoader`, shared with P-2).
        let outcome = await IndexLoader.load(
            layout: layout,
            fileSystem: fileSystem,
            metadata: self.environment.metadataExecutor,
            bulk: self.environment.bulkExecutor
        )
        try self.checkLive()
        // REENTRANCY: R1 — phase `opening`.
        let listing = try await self.listBlobs(layout)
        try self.checkLive()
        let onDisk = listing.onDisk
        let blobsRecreated = prepared.blobsRecreated
        let seed = self.environment.random.seed
        let now = self.environment.time.now()
        // REENTRANCY: R1 — phase `opening`; reconciliation and the snapshot table are pure and built off the actor (C2).
        let loaded = await self.runUnit(on: self.environment.bulkExecutor) {
            LaunchState.build(outcome: outcome, onDisk: onDisk, blobsRecreated: blobsRecreated, seed: seed, now: now, layout: layout)
        }
        try self.checkLive()
        let reconciled = self.installLoadedState(loaded)
        var legacyPending = false
        if self.configuration.legacy.enabled {
            // REENTRANCY: R1, R11 — phase `opening`; WP-C's phase 1 re-validates its own steps.
            legacyPending = try await self.runLegacyPhaseOne()
            try self.checkLive()
        }
        // ADR-015: the root's listing is ordered before any launch deletion, even if the commit below fails.
        // REENTRANCY: R1 — phase `opening`; a failed barrier is retried by the commit's own root sync, and until one
        // succeeds the store counts nothing committed (below).
        let rootOrdered = await self.runUnit(on: self.environment.metadataExecutor) { () -> Bool in
            (try? fileSystem.synchronizeDirectory(at: layout.root, level: .barrier)) != nil
        }
        try self.checkLive()
        // ADR draft B-36: the loaded generation counts as committed only once the root's names are ordered (never lowered:
        // a commit made before the barrier, by legacy phase 1, was ordered by its own root sync).
        self.state.core.committedGeneration = max(self.state.core.committedGeneration, loaded.committedGeneration(rootOrdered: rootOrdered))
        if let reason = self.state.core.unavailable {
            // ADR draft B-34: the load could not read an index file, so no commit may write over it in this lifetime.
            self.environment.log.log(.store, .error, "an index file could not be read (\(String(describing: reason))); serving the loaded state read-only")
        } else {
            do throws(StoreError) {
                // REENTRANCY: R5 — phase `opening`; a failure leaves the state dirty and the store serves it read-only
                // until a later commit succeeds (store-1 S1-07).
                try await self.commitNow(.ordered)
            } catch {
                self.environment.log.log(.store, .error, "launch commit failed; serving the loaded state")
            }
            try self.checkLive()
        }
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

    /// Installs the loaded and reconciled generation (built off the actor) as the store's state: assignments only.
    private func installLoadedState(_ loaded: LaunchState) -> LaunchReconciliation.Result {
        let content = loaded.content
        let reconciled = loaded.reconciled
        self.state.core.storeID = loaded.storeID
        self.state.core.nextGeneration = loaded.nextGeneration
        // Nothing counts as committed before `open()`'s root barrier ordered the names the load read (ADR draft B-36).
        self.state.core.committedGeneration = 0
        self.state.core.commits.pendingPromotion = loaded.promotion
        // The launch epoch is the generation the launch commit carries: persisted and strictly increasing (ADR-013).
        self.state.core.launchEpoch = loaded.nextGeneration
        self.state.core.records = reconciled.records
        self.state.core.blobTable = reconciled.blobTable
        self.state.core.blobBytes = reconciled.blobBytes
        self.state.core.orphans = reconciled.orphans
        self.state.core.appliedManifest = content.appliedManifest
        self.state.core.etag = content.etag
        self.state.core.stamp = reconciled.osPurgeDetected ? nil : content.stamp
        self.state.core.syncDue = reconciled.osPurgeDetected || content.syncDue
        self.state.core.degraded = loaded.degraded
        self.state.core.unavailable = loaded.unavailable
        self.state.migration.phase = content.legacyPhase
        self.state.migration.legacyStamp = content.legacyStamp
        self.state.cleanup.lastCleanupAt = content.lastCleanupAt
        self.state.core.metrics.doomedRepairs += reconciled.doomedRepairs
        self.state.core.presentTable = loaded.presentTable
        self.state.core.commits.dirtyFanOuts = reconciled.adoptedFanOuts
        self.state.core.commits.blobsDirectoryDirty = true
        self.markDirtyInternal(.soon)
        return reconciled
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
