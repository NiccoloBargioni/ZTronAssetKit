import Foundation
import ZTronAssetModel

/// Leases (R-CAR-8, R-CLN-5; WP-C, ADR-046): while one is held, eviction, prune, purge and GC never delete the blob.
extension AssetStore {
    /// Pins an asset's blob for the lease's lifetime (R-CAR-8); no await, so no window. Recorded in
    /// `state.cleanup.leases`, which WP-B's reaper reads.
    package func acquireLease(_ id: AssetID) throws(StoreError) -> AssetLease {
        fatalError("WP-C: AssetStore.acquireLease not implemented")
    }

    /// Releases a lease; idempotent per token. Returns the store's new deadline (`nextDeadline()`) so the engine can
    /// re-arm (a lease was the reaper's only blocker, store-2 S2-03).
    package func releaseLease(_ lease: AssetLease) -> MonotonicInstant? {
        fatalError("WP-C: AssetStore.releaseLease not implemented")
    }
}
