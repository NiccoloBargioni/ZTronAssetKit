import Foundation
import ZTronAssetModel

/// Orphan mark and sweep over `blobs/` (R-CLN-2, store.md §6.2, REENTRANCY R10).
extension AssetStore {
    /// `collectGarbage(until:)`: one listing, one decision off the actor, then the sweep dooms the orphans in one turn
    /// (`doomOrphans`, CCR-1; orchestrator ruling R2 at the L3 close-out), so the reaper unlinks them under the I-3
    /// protocol and a publication or adoption of the same key meanwhile rescues them instead of losing the file.
    ///
    /// A doom must have its file (I-2: a rescuable doom is bound without I/O), so a key is swept only when the listing's
    /// view of it cannot be stale (review of the L3 close-out, ZProbe-phantom): it was unknown to the blob table and to
    /// `publishing` before the first listing unit and still is in the turn that dooms it (only the reaper takes a key
    /// out of the blob table, and only a key it holds); no key the store learnt after that start can have been reaped
    /// since (`OrphanCollection.Start.reapWindowClosed`); and no other run is in flight (a concurrent call returns at
    /// once with an empty result), so no run sweeps what another one's doom let the reaper remove.
    func performCollectGarbage(until deadline: MonotonicInstant) async throws(StoreError) -> CleanupResult {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        guard let layout = self.state.core.layout, self.collectsOrphans, !self.state.cleanup.collectingOrphans else {
            return CleanupResult()
        }
        self.state.cleanup.collectingOrphans = true
        defer {
            self.state.cleanup.collectingOrphans = false
        }
        let interval = self.environment.log.interval(.gc, category: .store, "orphans")
        defer {
            interval.end()
        }
        // Before the first listing unit: what the store knows, and when.
        let start = OrphanCollection.Start(
            known: OrphanCollection.Known(blobTable: self.state.core.blobTable, publishing: self.state.core.publishing),
            uptime: self.environment.time.uptimeNow(),
            acknowledgedInstalls: self.state.core.metrics.acknowledgedInstalls
        )
        // REENTRANCY: R10 — `listBlobFiles` re-checks the phase after each listing unit; nothing is decided before the
        // listing is complete.
        guard let listed = try await self.listBlobFiles(layout, until: deadline), self.collectsOrphans else {
            return CleanupResult()
        }
        let now = self.environment.time.now()
        let grace = self.configuration.policy.orphanGrace
        let records = self.state.core.records
        let known = [start.known, OrphanCollection.Known(blobTable: self.state.core.blobTable, publishing: self.state.core.publishing)]
        // C2: the adoption keys of every record and the comparison with the listing run off the actor.
        // REENTRANCY: R10 — the phase, the caller's cancellation, the suspension rules (degraded, unavailable) and the
        // reap window below; the decision describes the state when the unit was submitted, so every key is checked again
        // against the blob table and `publishing` in the turn that dooms it (`doomOrphans`); a key a record started
        // expecting meanwhile is doomed, but stays rescuable by that record's adoption or publication until the reaper's
        // grace ends.
        var decision = await self.runUnit(on: self.environment.bulkExecutor) {
            OrphanCollection.decide(listed: listed, records: records, known: known, now: now, grace: grace)
        }
        try self.checkLive()
        if Task.isCancelled {
            throw .cancelled
        }
        guard self.collectsOrphans else {
            return CleanupResult()
        }
        guard self.reapWindowClosed(since: start) else {
            // A run that outlasted the deletion grace while an install was acknowledged dooms nothing: a key the store learnt
            // after the start may have been doomed and reaped since. The next run collects.
            self.environment.log.log(.store, .info, "an orphan sweep outlasted the deletion grace; the next run collects")
            self.state.cleanup.orphans = decision.unknown
            return CleanupResult()
        }
        // One turn from here: each key is O(1) against the live tables (`doomOrphans`).
        let doomed = self.doomOrphans(decision.sweep)
        var result = CleanupResult()
        for key in doomed {
            result.bytesFreed = result.bytesFreed.addingSaturating(decision.unknown.removeValue(forKey: key) ?? 0)
            result.filesRemoved += 1
        }
        // The report's orphans: what is left (it skips at read time a key the store learnt since).
        self.state.cleanup.orphans = decision.unknown
        if result.filesRemoved > 0 {
            self.state.core.metrics.gcBytes = self.state.core.metrics.gcBytes.addingSaturating(result.bytesFreed)
            self.stampCleanup()
        }
        return result
    }

    /// Whether no key the store learnt after `start` can have been reaped since (ARCHITECTURE §4.4; ZProbe-phantom): such
    /// a key was doomed after the start, so its grace ends no earlier than `start + deletionGrace` on the awake clock,
    /// and the reaper also needs an acknowledgement after the doom (the one that starts the grace, or the fresh one after
    /// it). So either the grace cannot have passed yet, or no install was acknowledged since the start. O(1).
    func reapWindowClosed(since start: OrphanCollection.Start) -> Bool {
        self.state.core.metrics.acknowledgedInstalls == start.acknowledgedInstalls
            || self.environment.time.uptimeNow() < start.uptime.adding(seconds: self.configuration.policy.deletionGrace)
    }

    /// Orphans are collected only while the store is neither degraded (the doom set and the records are untrusted
    /// until the next `apply`, store-1 S1-11) nor unavailable (the path may belong to another store, B-15).
    var collectsOrphans: Bool {
        !self.state.core.degraded && (try? self.checkWritable()) != nil
    }

    /// Lists every well-named blob in its fan-out, one unit per directory, as one array per fan-out (C2: a dictionary
    /// grown across the units rehashed every blob in one turn, 5 ms at `maxEntries`); `nil` when `deadline` passes first
    /// (a partial listing decides nothing).
    func listBlobFiles(_ layout: StoreLayout, until deadline: MonotonicInstant) async throws(StoreError) -> [[OrphanCollection.Listed]]? {
        let fileSystem = self.environment.fileSystem
        let time = self.environment.time
        guard time.monotonicNow() < deadline else {
            return nil
        }
        let blobs = layout.blobsDirectory
        // REENTRANCY: R10 — the phase; the listing only accumulates, the sweep is computed after the last unit.
        let top = await self.runUnit(on: self.environment.metadataExecutor) {
            CleanupUnits.list(blobs, fileSystem: fileSystem)
        }
        try self.checkLive()
        let fanOuts: [String]
        switch top {
        case .success(let items):
            fanOuts = items.filter { $0.kind == .directory && OrphanCollection.isFanOut($0.name) }.map(\.name).sorted()
        case .failure(let error):
            throw .fileSystem(error)
        }
        var listed: [[OrphanCollection.Listed]] = []
        listed.reserveCapacity(fanOuts.count)
        for fanOut in fanOuts {
            if Task.isCancelled {
                throw .cancelled
            }
            guard time.monotonicNow() < deadline else {
                return nil
            }
            let directory = blobs.appendingPathComponent(fanOut, isDirectory: true)
            // REENTRANCY: R10 — as above.
            let items = await self.runUnit(on: self.environment.metadataExecutor) {
                CleanupUnits.list(directory, fileSystem: fileSystem)
            }
            try self.checkLive()
            switch items {
            case .success(let files):
                listed.append(files.compactMap { file in
                    guard file.kind == .file, let key = StoreLayout.parseBlobName(file.name), key.hash.fanOut == fanOut else {
                        return nil
                    }
                    return OrphanCollection.Listed(key: key, item: file)
                })
            case .failure(let error):
                throw .fileSystem(error)
            }
        }
        return listed
    }
}

/// Pure helpers of orphan GC.
enum OrphanCollection {
    /// One well-named blob the listing found.
    struct Listed: Sendable, Hashable {
        /// Its key, parsed from its name.
        let key: BlobKey
        /// What the listing reported.
        let item: FileItemInfo
    }

    /// What the store knew at one instant: its blob table and the keys being placed (REENTRANCY R10's protected set).
    struct Known: Sendable {
        /// The blob table.
        let blobTable: [BlobKey: BlobState]
        /// The keys being placed.
        let publishing: Set<BlobKey>

        /// Whether `key` is in either.
        func contains(_ key: BlobKey) -> Bool {
            self.blobTable[key] != nil || self.publishing.contains(key)
        }
    }

    /// What an orphan GC run knew when it started, before its first listing unit (ZProbe-phantom).
    struct Start: Sendable {
        /// The store's protected set then.
        let known: Known
        /// The awake clock then.
        let uptime: MonotonicInstant
        /// `StoreMetrics.acknowledgedInstalls` then.
        let acknowledgedInstalls: Int
    }

    /// What one listing decides, from snapshots of the state (C2: computed on the bulk executor).
    struct Decision: Sendable {
        /// Every listed blob no snapshot of `known` knows, with its size: those left after the sweep are the report's
        /// orphans (`StorageReport.orphanBytes`).
        var unknown: [BlobKey: Int64]
        /// The unknown blobs to sweep: no record expects them (a later `apply` or launch adopts such a blob instead of
        /// downloading it), and they are older than the orphan grace (one without a modification time is kept).
        var sweep: [BlobKey: Int64]
    }

    /// The decision over `listed` (REENTRANCY R10: only after the full listing). A blob is unknown only when every
    /// snapshot of `known` lacks it: the one taken before the listing (a key the reaper removed after the listing saw
    /// its file was known then) and the one taken after it.
    static func decide(
        listed: [[Listed]],
        records: [AssetID: AssetRecord],
        known: [Known],
        now: Date,
        grace: TimeInterval
    ) -> Decision {
        let expected = Set(records.values.compactMap(\.expectedKey))
        var decision = Decision(unknown: [:], sweep: [:])
        for blob in listed.joined() where !known.contains(where: { $0.contains(blob.key) }) {
            decision.unknown[blob.key] = blob.item.byteSize
            guard !expected.contains(blob.key), let modified = blob.item.modifiedAt, now.timeIntervalSince(modified) > grace else {
                continue
            }
            decision.sweep[blob.key] = blob.item.byteSize
        }
        return decision
    }

    /// Whether `name` is a fan-out directory name: two lowercase hex digits.
    static func isFanOut(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return bytes.count == 2 && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
