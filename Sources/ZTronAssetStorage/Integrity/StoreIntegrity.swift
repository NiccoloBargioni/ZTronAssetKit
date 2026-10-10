import Foundation
import ZTronAssetModel

/// Quarantine, deep verification and persisted failure bookkeeping (R-CLN-8, R-INT-3, R-INT-4, R-NET-6; WP-C,
/// ADR-046, ADR-032).
extension AssetStore {
    /// Quarantines the entry and dooms its blob as `.corrupt` (R-CLN-8, ADR-018).
    ///
    /// Every record referencing the same blob is quarantined through the R-INT-3 bookkeeping (backoff, then
    /// `failed(.unreadable)`), so `IntegrityHistory.nextEligibleAt` schedules the re-download; the blob is deleted after
    /// acknowledgement, grace and leases. A record without a blob (already quarantined, absent) is left alone, so a
    /// second report is a no-op. Throws `.unknownAsset` for an id without a record.
    package func reportUnreadable(_ id: AssetID) async throws(StoreError) {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        guard let record = self.state.core.records[id] else {
            throw .unknownAsset(id)
        }
        guard let key = record.referencedBlob else {
            return
        }
        var scan = HolderScan(blobs: [key])
        self.quarantine(blob: key, known: [id], scan: &scan)
        self.environment.log.log(.store, .info, "an unreadable blob was quarantined")
        // REENTRANCY: R17 — nothing but the phase: the quarantine was made synchronously above.
        await self.publishSnapshot(urgency: .userInitiated)
        // REENTRANCY: R17 — as above.
        try await self.requireCommitted(.ordered)
    }

    /// Deep verification from the oldest `verifiedAt`, within a byte budget and a deadline (R-INT-4); resumes at
    /// `state.integrity.cursor`.
    ///
    /// Blobs are taken oldest `verifiedAt` first (never verified first), each once per pass; a slice stops before a
    /// blob that would take it past `byteBudget` (the first blob of a slice always runs, so a blob larger than the
    /// budget is still verified) and at `deadline`. A mismatch (digest, size, or a blob that cannot be read)
    /// quarantines every record of the blob as `reportUnreadable` does. Nothing runs while the store is degraded.
    package func verifyIntegrity(byteBudget: Int64, until deadline: MonotonicInstant) async throws(StoreError)
        -> VerificationReport
    {
        // REENTRANCY: R1, c-6 (proposed), R16, c-3 (proposed) — `performVerifyIntegrity` re-validates each blob before and
        // after its hash.
        try await self.performVerifyIntegrity(byteBudget: byteBudget, until: deadline)
    }

    /// Records an integrity failure for content that failed verification (R-INT-3), persisted: a quarantine with
    /// backoff, then `failed(.integrity)` after `maxIntegrityAttempts`. The engine calls it for transport and store
    /// integrity failures alike (ADR-032).
    ///
    /// Records whose identity changed, failed records and unknown ids are left alone. A record without a blob becomes
    /// `quarantined(until:)`; a record still serving stale bytes keeps serving them during the backoff (store.md §6.1)
    /// and loses them only when it becomes `failed(.integrity)`.
    package func recordIntegrityFailure(_ ids: [AssetID], identity: ContentIdentity) async throws(StoreError) {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        let now = self.environment.time.now()
        var changed = false
        var dropped = false
        for id in IntegrityBookkeeping.unique(ids) {
            guard var record = self.state.core.records[id], record.entry.contentIdentity == identity else {
                continue
            }
            if case .failed = record.residency {
                continue
            }
            let step = IntegrityBookkeeping.failure(after: record.integrity, of: identity, at: now, policy: self.configuration.policy)
            record.integrity = step.history
            self.state.core.records[id] = record
            changed = true
            if let until = step.quarantinedUntil {
                if record.referencedBlob == nil {
                    self.setResidency(.quarantined(until: until), of: id, dooming: .unreferenced)
                }
            } else {
                dropped = dropped || record.referencedBlob != nil
                self.setResidency(.failed(.integrity), of: id, dooming: .unreferenced)
            }
        }
        // REENTRANCY: R17 — nothing but the phase: the bookkeeping was written synchronously above.
        try await self.persistBookkeeping(changed: changed, droppedBlobs: dropped)
    }

    /// Marks every id in `ids` whose record still has content identity `identity` as `failed(reason)`, persisted
    /// (`markDirty(.soon)`), so neither a later run nor a relaunch fetches it until the manifest entry's identity
    /// changes; WP-B's `apply` clears it then (ARCHITECTURE §7.6, ADR-032). Records whose identity already changed
    /// are left alone (the failure is about content that is no longer wanted). `reason` is `.notFound` for a
    /// 404/410 (R-NET-6) or `.unreadable`; integrity failures go through `recordIntegrityFailure(_:identity:)`,
    /// which backs off first.
    package func recordFailure(_ ids: [AssetID], identity: ContentIdentity, reason: FailureReason) async throws(StoreError) {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        var changed = false
        var dropped = false
        for id in IntegrityBookkeeping.unique(ids) {
            guard let record = self.state.core.records[id], record.entry.contentIdentity == identity,
                record.residency != .failed(reason)
            else {
                continue
            }
            dropped = dropped || record.referencedBlob != nil
            self.setResidency(.failed(reason), of: id, dooming: .unreferenced)
            changed = true
        }
        // REENTRANCY: R17 — nothing but the phase: the failures were written synchronously above.
        try await self.persistBookkeeping(changed: changed, droppedBlobs: dropped)
    }
}
