import Foundation
import ZTronAssetModel

/// Quota eviction, the retention scope and pins (R-CLN-4, R-SYN-11, R-CAR-5; WP-C, ADR-046).
extension AssetStore {
    /// The eviction dry run (X-2): what evicting `bytes` would remove, never touching `protecting`; `nil` when the
    /// target is unreachable. Pure over current state; no mutation. Victims outside the retention scope come first
    /// (`setRetentionScope(_:)`, ADR-027), then the R-CLN-4 order. The engine asks only when
    /// `StoragePolicy.evictionPermitted` (ADR-048).
    package func evictionPlan(toFree bytes: Int64, protecting: Set<AssetID>) -> EvictionPlan? {
        fatalError("WP-C: AssetStore.evictionPlan not implemented")
    }

    /// The client's retention scope (R-CAR-5, ADR-027): what the app wants kept, e.g. the entries its paywall
    /// unlocks. Entries outside it are evicted before any entry inside it and are reported in
    /// `AdoptionReport.excludedRemotePaths`, so they never block an Apple pack release (transport-2 T2-13).
    /// In-memory (`state.eviction`) and valid in any phase (it starts as `.all`); the engine sets it after `open()`
    /// and whenever the app changes it. Setting it deletes nothing and fetches nothing by itself.
    package func setRetentionScope(_ scope: AssetScope) {
        fatalError("WP-C: AssetStore.setRetentionScope not implemented")
    }

    /// Persists pins (R-CLN-4: never evicted while pinned; `purge` still removes them).
    package func setPinned(_ ids: Set<AssetID>, pinned: Bool) async throws(StoreError) {
        fatalError("WP-C: AssetStore.setPinned not implemented")
    }

    /// Quota eviction down to the hysteresis target, counting pending reclaim (store-2 S2-06); entries outside the
    /// retention scope first (ADR-027). Runs in maintenance whatever `StoragePolicy.evictionPermitted` says.
    package func evictIfNeeded() async throws(StoreError) -> CleanupResult {
        fatalError("WP-C: AssetStore.evictIfNeeded not implemented")
    }

    /// **Hook called by WP-B's `apply`** when it receives a plan: re-validates each victim (still present, unleased,
    /// not accessed since the plan, still evictable; REENTRANCY R8), evicts the valid ones through
    /// `setResidency(.absent(.evicted), of:dooming: .unreferenced)` and returns them in plan order. Synchronous: it
    /// runs inside `apply`'s mutation, before its commit.
    func applyEviction(_ plan: EvictionPlan) -> [AssetID] {
        fatalError("WP-C: AssetStore.applyEviction not implemented")
    }
}
