import Foundation
import ZTronAssetModel

/// Orphan mark and sweep over `blobs/` (R-CLN-2, store.md §6.2, REENTRANCY R10).
extension AssetStore {
    /// `collectGarbage(until:)`.
    func performCollectGarbage(until deadline: MonotonicInstant) async throws(StoreError) -> CleanupResult {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        guard let layout = self.state.core.layout, self.collectsOrphans else {
            return CleanupResult()
        }
        let interval = self.environment.log.interval(.gc, category: .store, "orphans")
        defer {
            interval.end()
        }
        // REENTRANCY: R10 — `listBlobFiles` re-checks the phase after each listing unit; nothing is decided before the
        // listing is complete.
        guard let listed = try await self.listBlobFiles(layout, until: deadline), self.collectsOrphans else {
            return CleanupResult()
        }
        let now = self.environment.time.now()
        let grace = self.configuration.policy.orphanGrace
        var unknown: [BlobKey: Int64] = [:]
        var candidates: [BlobKey] = []
        let marked = self.orphanMarks()
        let expected = self.expectedKeys()
        for (key, item) in listed.sorted(by: { $0.key < $1.key }) where !marked.contains(key) {
            unknown[key] = item.byteSize
            guard !expected.contains(key), let modified = item.modifiedAt, now.timeIntervalSince(modified) > grace else {
                continue
            }
            candidates.append(key)
        }
        // The sweep set is re-checked against the marks right before each removal unit is submitted, in the same turn
        // (R10): a key a publication or adoption claimed meanwhile is left alone. A file whose removal fails stays an
        // orphan for the next run and does not stop the others; only the deadline and the caller's cancellation do.
        // REENTRANCY: c-1 (proposed) — see `removeInUnits`; the re-check above runs in the turn of each submission.
        let removal = try await self.removeInUnits(candidates.map { (url: layout.blobURL($0), bytes: unknown[$0] ?? 0) }, until: deadline) { [candidates] indices in
            guard self.collectsOrphans else {
                return []
            }
            let marks = self.orphanMarks().union(self.expectedKeys())
            return indices.filter { !marks.contains(candidates[$0]) }
        }
        for index in removal.removed {
            unknown[candidates[index]] = nil
        }
        let result = removal.result
        let cancelled = removal.cancelled
        // A cancelled run still accounts for what it removed (R-CLN-12, C-4) before it reports the cancellation.
        self.state.cleanup.orphans = unknown
        if result.filesRemoved > 0 {
            self.state.core.metrics.gcBytes = self.state.core.metrics.gcBytes.addingSaturating(result.bytesFreed)
            self.stampCleanup()
        }
        if cancelled {
            throw .cancelled
        }
        return result
    }

    /// Orphans are collected only while the store is neither degraded (the doom set and the records are untrusted
    /// until the next `apply`, store-1 S1-11) nor unavailable (the path may belong to another store, B-15).
    var collectsOrphans: Bool {
        !self.state.core.degraded && (try? self.checkWritable()) != nil
    }

    /// The keys the store knows: every key of the blob table and every key being placed (REENTRANCY R10).
    func orphanMarks() -> Set<BlobKey> {
        Set(self.state.core.blobTable.keys).union(self.state.core.publishing)
    }

    /// The adoption key of every record: such a blob is adopted by the next `apply` or launch, never collected.
    func expectedKeys() -> Set<BlobKey> {
        Set(self.state.core.records.values.compactMap(\.expectedKey))
    }

    /// Lists every well-named blob in its fan-out, one unit per directory; `nil` when `deadline` passes first (a partial
    /// listing decides nothing).
    func listBlobFiles(_ layout: StoreLayout, until deadline: MonotonicInstant) async throws(StoreError) -> [BlobKey: FileItemInfo]? {
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
        var listed: [BlobKey: FileItemInfo] = [:]
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
                for file in files where file.kind == .file {
                    if let key = StoreLayout.parseBlobName(file.name), key.hash.fanOut == fanOut {
                        listed[key] = file
                    }
                }
            case .failure(let error):
                throw .fileSystem(error)
            }
        }
        return listed
    }
}

/// Pure helpers of orphan GC.
enum OrphanCollection {
    /// Whether `name` is a fan-out directory name: two lowercase hex digits.
    static func isFanOut(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return bytes.count == 2 && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
