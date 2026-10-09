import Foundation
import ZTronAssetModel

/// Staging GC, orphan GC, purge and the storage report (R-CLN-2, R-CLN-3, R-CLN-6, R-CLN-9, R-CLN-12; WP-C,
/// ADR-046). Every operation is idempotent and cancellation-safe (store.md §6.9).
extension AssetStore {
    /// Removes every staging file whose transfer is not in `claimed`, older than `stagingClaimGrace`
    /// (ADR-028, R-CLN-3).
    ///
    /// A file is collected when its name does not parse (foreign), when it is older than `stagingMaxAge` (claimed or
    /// not), or when no claim names its transfer and it is older than `stagingClaimGrace`; a file whose age is unknown is
    /// kept. Epochs are never compared (ARCHITECTURE §4.5): the caller's claims and the file's age decide. The caller
    /// claims every transfer it still works on, those with a publication in flight included. Removals run in units of
    /// `deletionBatchSize`; a cancelled caller stops between units with `.cancelled` (removed files stay removed).
    package func collectStaging(keeping claimed: Set<TransferID>) async throws(StoreError) -> CleanupResult {
        // REENTRANCY: R1, R14, c-1 (proposed) — `performCollectStaging` re-checks the phase after each of its units.
        try await self.performCollectStaging(keeping: claimed)
    }

    /// Orphan mark and sweep (R-CLN-2, P-13); suspended while `state.core.degraded` (S1-11).
    ///
    /// Mark: every key of the blob table, every key being placed, and the adoption key of every record (a later `apply`
    /// or launch adopts such a blob instead of downloading it). Sweep, only after the full listing (in bounded units until
    /// `deadline`; a listing the deadline interrupts sweeps nothing): unmarked well-named blobs whose `mtime` is older
    /// than `orphanGrace` are **doomed**, not unlinked (CCR-1, L3 close-out): the reaper deletes them after the deletion
    /// grace under the I-3 protocol (`runDueWork()`), and a publication or adoption of the same key meanwhile rescues
    /// them. The result counts what this run released to the reaper (as quota eviction's, C-3). Also suspended while the
    /// root is unavailable (B-15). A caller cancelled before the sweep gets `.cancelled` and nothing is doomed.
    package func collectGarbage(until deadline: MonotonicInstant) async throws(StoreError) -> CleanupResult {
        // REENTRANCY: R1, R10 — `performCollectGarbage` decides only after its full listing and re-checks every key
        // against the blob table and `publishing` in the turn that dooms it.
        try await self.performCollectGarbage(until: deadline)
    }

    /// A user purge (R-CLN-6). Clears the stamp in the same commit; bumps `state.core.purgeEpoch` before any await.
    /// Returns after the selection is reaped (`reapDeletable(maxKeys:)`), rescued or deferred by a lease; the grace
    /// wait runs in the caller's (engine-owned) task.
    ///
    /// Every purge that removes something, and every `.all`, also clears the stamp and sets "sync due" (R-CLN-6); a purge
    /// that selects nothing changes nothing but the epoch. The selection's blobs are doomed `purged` (never re-adopted,
    /// ADR-018). `bytesFreed` counts the selection's bytes deleted before the call returned, `bytesDeferred` those still
    /// leased; bytes a sink that does not acknowledge holds back are in neither and are reaped later by `runDueWork()`.
    /// A cancelled caller gets `.cancelled` from the grace wait; the purge itself is already committed.
    package func purge(_ request: PurgeRequest) async throws(StoreError) -> PurgeResult {
        // REENTRANCY: R1, R17, R9 — `performPurge` mutates synchronously, then awaits the install, the commit and the
        // grace, recomputing the deletable state after each.
        try await self.performPurge(request)
    }

    /// `storageReport()` (R-CLN-9).
    ///
    /// `bytesByKind` and the present/stale split cover live blobs (a blob any current record still wants is present);
    /// `pendingDeletion` is doomed blobs (`FreeSpace.pendingReclaim` plus leased ones); `orphanBytes` are the
    /// unreferenced blobs the last orphan GC listing of this lifetime found and left (0 before the first one);
    /// `stagingBytes` and the free space are read in one unit each. `sourceCopyBytes` is 0 here: the engine adds the
    /// remote source's copies (ADR-027). Before `open()` (or after a failed read) the I/O figures are 0.
    package func storageReport() async -> StorageReport {
        // REENTRANCY: R1, R13, c-2 (proposed) — the report is read from the state after its units.
        await self.performStorageReport()
    }
}
