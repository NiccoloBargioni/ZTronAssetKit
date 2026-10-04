import Foundation
import ZTronAssetModel

/// Staging GC, orphan GC, purge and the storage report (R-CLN-2, R-CLN-3, R-CLN-6, R-CLN-9, R-CLN-12; WP-C,
/// ADR-046). Every operation is idempotent and cancellation-safe (store.md §6.9).
extension AssetStore {
    /// Removes every staging file whose transfer is not in `claimed`, older than `stagingClaimGrace`
    /// (ADR-028, R-CLN-3).
    package func collectStaging(keeping claimed: Set<TransferID>) async throws(StoreError) -> CleanupResult {
        fatalError("WP-C: AssetStore.collectStaging not implemented")
    }

    /// Orphan mark and sweep in bounded units until `deadline` (R-CLN-2, P-13); suspended while
    /// `state.core.degraded` (S1-11).
    package func collectGarbage(until deadline: MonotonicInstant) async throws(StoreError) -> CleanupResult {
        fatalError("WP-C: AssetStore.collectGarbage not implemented")
    }

    /// A user purge (R-CLN-6). Clears the stamp in the same commit; bumps `state.core.purgeEpoch` before any await.
    /// Returns after the selection is reaped (`reapDeletable(maxKeys:)`), rescued or deferred by a lease; the grace
    /// wait runs in the caller's (engine-owned) task.
    package func purge(_ request: PurgeRequest) async throws(StoreError) -> PurgeResult {
        fatalError("WP-C: AssetStore.purge not implemented")
    }

    /// `storageReport()` (R-CLN-9).
    package func storageReport() async -> StorageReport {
        fatalError("WP-C: AssetStore.storageReport not implemented")
    }
}
