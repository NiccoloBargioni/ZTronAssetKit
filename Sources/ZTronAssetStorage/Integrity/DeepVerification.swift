import Foundation
import ZTronAssetModel

/// Deep verification of resident blobs (R-INT-4, R-SYN-16; store.md §5.6, REENTRANCY R16).
extension AssetStore {
    /// `verifyIntegrity(byteBudget:until:)`. The due list is built and sorted off the actor from a value snapshot (C2:
    /// 13.5 ms at 10,000 records and 200 ms at `maxEntries` on the actor, review round 3; orchestrator ruling R4 at the
    /// L3 close-out); each blob is re-validated before and after its hash (REENTRANCY R16).
    func performVerifyIntegrity(byteBudget: Int64, until deadline: MonotonicInstant) async throws(StoreError) -> VerificationReport {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        var report = VerificationReport(bytesVerified: 0, corrupt: [], completedPass: false)
        guard byteBudget > 0, !self.state.core.degraded, let layout = self.state.core.layout else {
            return report
        }
        let records = self.state.core.records
        let blobTable = self.state.core.blobTable
        let publishing = self.state.core.publishing
        let done = self.state.integrity.verifiedInPass
        // REENTRANCY: c-6 (proposed) — the phase and writability below; the due list describes the state when the unit
        // was submitted, so each blob is checked again before its hash (live, not being placed, not verified in this
        // pass meanwhile) and after it (R16), and its holders are read again (`holders(of:known:scan:)`).
        let due = await self.runUnit(on: self.environment.bulkExecutor) {
            DeepVerification.due(records: records, blobTable: blobTable, publishing: publishing, done: done)
        }
        try self.checkLive()
        try self.checkWritable()
        var queue = due[...]
        while self.environment.time.monotonicNow() < deadline, !self.state.core.degraded {
            guard let item = queue.first else {
                report.completedPass = true
                self.state.integrity.verifiedInPass = []
                self.state.integrity.cursor = nil
                break
            }
            if report.bytesVerified > 0, report.bytesVerified.addingSaturating(item.size) > byteBudget {
                break
            }
            queue.removeFirst()
            let key = item.key
            guard case .live? = self.state.core.blobTable[key], !self.state.core.publishing.contains(key),
                !self.state.integrity.verifiedInPass.contains(key)
            else {
                continue
            }
            let url = layout.blobURL(key)
            // REENTRANCY: R16 — the phase; the incarnation is compared with the one after the hash, below.
            let before = await self.blobIncarnation(url)
            try self.checkLive()
            let outcome: (digest: ContentHash, byteCount: Int64)?
            do throws(StoreError) {
                // REENTRANCY: R16 — below: the same incarnation is under the name and no placement of the key is in
                // flight, the blob is still live and referenced, and the store not degraded; otherwise the result is
                // discarded; the deadline and the budget are re-read by the loop.
                outcome = try await self.hashFile(at: url)
            } catch .fileSystem {
                // A blob that cannot be read is as unusable as a corrupt one (R-CLN-8).
                outcome = nil
            }
            try self.checkLive()
            // REENTRANCY: R16 — as above.
            let after = await self.blobIncarnation(url)
            try self.checkLive()
            guard before == after, !self.state.core.publishing.contains(key) else {
                // The name was replaced while it was hashed (a quarantine or an eviction, then a re-download or a reap
                // and a new placement, ADR draft B-24) or is being placed now: the digest mixes two files and proves
                // nothing about either. Neither quarantined nor verified, and not marked done, so the pass checks it again.
                continue
            }
            self.state.integrity.verifiedInPass.insert(key)
            // This turn reads the blob's holders at most once from the records, for the check and the quarantine (C2).
            var scan = HolderScan(blobs: [key])
            guard case .live? = self.state.core.blobTable[key], !self.state.core.degraded,
                case let holders = self.holders(of: key, known: item.holders, scan: &scan),
                let first = holders.min(by: { $0.rawValue < $1.rawValue })
            else {
                continue
            }
            self.state.integrity.cursor = first
            report.bytesVerified = report.bytesVerified.addingSaturating(outcome?.byteCount ?? item.size)
            if let outcome, outcome.digest == key.hash, outcome.byteCount == item.size {
                let now = self.environment.time.now()
                for id in holders {
                    self.state.core.records[id]?.verifiedAt = now
                }
                self.markDirty(.lazy)
            } else {
                report.corrupt.append(contentsOf: self.quarantine(blob: key, known: holders, scan: &scan))
                self.environment.log.log(.store, .error, "deep verification found a corrupt blob; it is quarantined")
            }
        }
        if !report.corrupt.isEmpty {
            // REENTRANCY: c-3 (proposed) — nothing but the phase (as R17): the quarantines were made synchronously
            // above and the report describes them; the commit follows within the coalescing window.
            await self.publishSnapshot(urgency: .userInitiated)
        }
        return report
    }

    /// The file under a blob's name, in one metadata unit: its identity and size, missing, or unknown (the stat
    /// failed). Two equal values around a hash mean the hash read one file (REENTRANCY R16).
    func blobIncarnation(_ url: URL) async -> BlobIncarnation {
        let fileSystem = self.environment.fileSystem
        // REENTRANCY: R16 — nothing: a snapshot the caller compares with another one.
        return await self.runUnit(on: self.environment.metadataExecutor) { () -> BlobIncarnation in
            do throws(FileSystemError) {
                guard let info = try fileSystem.itemInfo(at: url) else {
                    return .missing
                }
                return .file(identity: info.identity, byteSize: info.byteSize)
            } catch {
                return .unknown
            }
        }
    }
}

/// The pure part of deep verification (run on the bulk executor, C2).
enum DeepVerification {
    /// One blob still to verify in the current pass.
    struct Due: Sendable, Hashable {
        /// The blob.
        let key: BlobKey
        /// Its recorded size.
        let size: Int64
        /// The records that referenced it in the snapshot.
        let holders: [AssetID]
    }

    /// The blobs of the current pass still to verify, in order: live, referenced, not being placed, not verified in this
    /// pass (`done`); oldest `verifiedAt` over their records first (never verified first), then by key.
    static func due(records: [AssetID: AssetRecord], blobTable: [BlobKey: BlobState], publishing: Set<BlobKey>, done: Set<BlobKey>) -> [Due] {
        var holders: [BlobKey: [AssetID]] = [:]
        var oldest: [BlobKey: Date] = [:]
        var sizes: [BlobKey: Int64] = [:]
        for (id, record) in records {
            guard let key = record.referencedBlob, !done.contains(key) else {
                continue
            }
            holders[key, default: []].append(id)
            oldest[key] = min(oldest[key] ?? .distantFuture, record.verifiedAt ?? .distantPast)
            if sizes[key] == nil {
                sizes[key] = EvictionOrder.recordedSize(record)
            }
        }
        var due: [(verifiedAt: Date, item: Due)] = []
        due.reserveCapacity(holders.count)
        for (key, ids) in holders {
            guard case .live? = blobTable[key], !publishing.contains(key) else {
                continue
            }
            due.append((oldest[key] ?? .distantPast, Due(key: key, size: sizes[key] ?? 0, holders: ids)))
        }
        due.sort { ($0.verifiedAt, $0.item.key) < ($1.verifiedAt, $1.item.key) }
        return due.map(\.item)
    }
}

/// What is under a blob's name at one moment (deep verification, REENTRANCY R16). A replacement renames another file
/// over the name, so its identity changes; a write in place keeps it (and is what verification exists to find).
enum BlobIncarnation: Sendable, Hashable {
    /// An item with this `(st_dev, st_ino)` (when the volume reports one) and size.
    case file(identity: FileIdentity?, byteSize: Int64)
    /// Nothing has the name.
    case missing
    /// The stat failed.
    case unknown
}
