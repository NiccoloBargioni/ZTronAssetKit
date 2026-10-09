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
            let outcome: (digest: ContentHash, byteCount: Int64)?
            do throws(StoreError) {
                // REENTRANCY: R16 — below: the blob is still live and referenced, and the store not degraded; otherwise
                // the result is discarded and the pass moves on; the deadline and the budget are re-read by the loop.
                outcome = try await self.hashFile(at: layout.blobURL(key))
            } catch .fileSystem {
                // A blob that cannot be read is as unusable as a corrupt one (R-CLN-8).
                outcome = nil
            }
            try self.checkLive()
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
            let size = self.state.core.blobBytes[key] ?? records.first.map(EvictionOrder.recordedSize) ?? 0
            due.append((key, oldest, size))
        }
        due.sort { ($0.verifiedAt, $0.key) < ($1.verifiedAt, $1.key) }
        return due.map { ($0.key, $0.size) }
    }
}
