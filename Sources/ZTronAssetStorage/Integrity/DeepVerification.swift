import Foundation
import ZTronAssetModel

/// Deep verification of resident blobs (R-INT-4, R-SYN-16; store.md §5.6, REENTRANCY R16).
extension AssetStore {
    /// `verifyIntegrity(byteBudget:until:)`.
    func performVerifyIntegrity(byteBudget: Int64, until deadline: MonotonicInstant) async throws(StoreError) -> VerificationReport {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        var report = VerificationReport(bytesVerified: 0, corrupt: [], completedPass: false)
        guard byteBudget > 0, !self.state.core.degraded, let layout = self.state.core.layout else {
            return report
        }
        let index = self.referenceIndex()
        var queue = self.blobsToVerify(index)[...]
        while self.environment.time.monotonicNow() < deadline, !self.state.core.degraded {
            guard let (key, size) = queue.first else {
                report.completedPass = true
                self.state.integrity.verifiedInPass = []
                self.state.integrity.cursor = nil
                break
            }
            if report.bytesVerified > 0, report.bytesVerified.addingSaturating(size) > byteBudget {
                break
            }
            queue.removeFirst()
            guard case .live? = self.state.core.blobTable[key], !self.state.core.publishing.contains(key) else {
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
            guard case .live? = self.state.core.blobTable[key], !self.state.core.degraded,
                case let holders = (index[key] ?? []).filter({ self.state.core.records[$0]?.referencedBlob == key }),
                let first = holders.min(by: { $0.rawValue < $1.rawValue })
            else {
                continue
            }
            self.state.integrity.cursor = first
            report.bytesVerified = report.bytesVerified.addingSaturating(outcome?.byteCount ?? size)
            if let outcome, outcome.digest == key.hash, outcome.byteCount == size {
                let now = self.environment.time.now()
                for id in holders {
                    self.state.core.records[id]?.verifiedAt = now
                }
                self.markDirty(.lazy)
            } else {
                report.corrupt.append(contentsOf: self.quarantine(blob: key))
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

    /// The blobs of the current pass still to verify, in order: live, referenced, not being placed, not verified in this
    /// pass; oldest `verifiedAt` over their records first (never verified first), then by key; with their sizes.
    func blobsToVerify(_ index: [BlobKey: [AssetID]]) -> [(BlobKey, Int64)] {
        let done = self.state.integrity.verifiedInPass
        var due: [(key: BlobKey, verifiedAt: Date, size: Int64)] = []
        for (key, ids) in index where !done.contains(key) {
            guard case .live? = self.state.core.blobTable[key], !self.state.core.publishing.contains(key) else {
                continue
            }
            let records = ids.compactMap { self.state.core.records[$0] }
            let oldest = records.map { $0.verifiedAt ?? .distantPast }.min() ?? .distantPast
            let size = records.first.map(EvictionOrder.recordedSize) ?? 0
            due.append((key, oldest, size))
        }
        due.sort { ($0.verifiedAt, $0.key) < ($1.verifiedAt, $1.key) }
        return due.map { ($0.key, $0.size) }
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
