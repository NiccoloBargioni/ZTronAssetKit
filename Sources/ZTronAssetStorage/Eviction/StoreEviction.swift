import Foundation
import ZTronAssetModel

/// Quota eviction, the retention scope and pins (R-CLN-4, R-SYN-11, R-CAR-5; WP-C, ADR-046).
extension AssetStore {
    /// The eviction dry run (X-2): what evicting `bytes` would remove, never touching `protecting`; `nil` when the
    /// target is unreachable. Pure over current state; no mutation. Victims outside the retention scope come first
    /// (`setRetentionScope(_:)`, ADR-027), then the R-CLN-4 order. The engine asks only when
    /// `StoragePolicy.evictionPermitted` (ADR-048).
    ///
    /// `nil` outside the open phase. Leased blobs, blobs being placed, and records that are essential, pinned or
    /// accessed within `max(minimumResidency, deletionGrace)` are never victims; a blob shared by several records is
    /// planned with all of them (`EvictionPlan.bytes` counts it once).
    package func evictionPlan(toFree bytes: Int64, protecting: Set<AssetID>) -> EvictionPlan? {
        guard self.state.core.phase == .open else {
            return nil
        }
        return EvictionOrder.plan(self.evictionCandidates(protecting: protecting), toFree: bytes)
    }

    /// The client's retention scope (R-CAR-5, ADR-027): what the app wants kept, e.g. the entries its paywall
    /// unlocks. Entries outside it are evicted before any entry inside it and are reported in
    /// `AdoptionReport.excludedRemotePaths`, so they never block an Apple pack release (transport-2 T2-13).
    /// In-memory (`state.eviction`) and valid in any phase (it starts as `.all`); the engine sets it after `open()`
    /// and whenever the app changes it. Setting it deletes nothing and fetches nothing by itself.
    package func setRetentionScope(_ scope: AssetScope) {
        self.state.eviction.retentionScope = scope
    }

    /// Persists pins (R-CLN-4: never evicted while pinned; `purge` still removes them).
    /// Ids without a record are ignored; returns once the pins are in an ordered committed generation (nothing to
    /// commit when none changed).
    package func setPinned(_ ids: Set<AssetID>, pinned: Bool) async throws(StoreError) {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        var changed = false
        for id in ids.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard var record = self.state.core.records[id], record.pinned != pinned else {
                continue
            }
            record.pinned = pinned
            self.state.core.records[id] = record
            changed = true
        }
        guard changed else {
            return
        }
        self.markDirty(.soon)
        // REENTRANCY: R17 — nothing but the phase: the pins were written synchronously above; a later call's pins are
        // newer state and win.
        try await self.requireCommitted(.ordered)
    }

    /// Quota eviction down to the hysteresis target, counting pending reclaim (store-2 S2-06); entries outside the
    /// retention scope first (ADR-027). Runs in maintenance whatever `StoragePolicy.evictionPermitted` says.
    ///
    /// The result counts what this run evicted: `bytesFreed` and `filesRemoved` are the bytes and blobs it released to
    /// the reaper (they leave `FreeSpace.usedBytes` at once and are unlinked after acknowledgement and grace, so a
    /// second run within the grace window evicts nothing more, store-2 S2-06); leased blobs are never selected, so
    /// `bytesDeferred` is 0. Throws when the committing generation fails (the evictions stay in memory, dirty, R5).
    package func evictIfNeeded() async throws(StoreError) -> CleanupResult {
        // REENTRANCY: R1, R13, R8, R17 — `performEvictIfNeeded` re-validates every candidate after each await.
        try await self.performEvictIfNeeded()
    }

    /// **Hook called by WP-B's `apply`** when it receives a plan: re-validates each victim (still present, unleased,
    /// not accessed since the plan, still evictable; REENTRANCY R8), evicts the valid ones through
    /// `setResidency(.absent(.evicted), of:dooming: .unreferenced)` and returns them in plan order. Synchronous: it
    /// runs inside `apply`'s mutation, before its commit.
    func applyEviction(_ plan: EvictionPlan) -> [AssetID] {
        self.performApplyEviction(plan)
    }
}
