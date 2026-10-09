import Foundation
import ZTronAssetModel

/// Leases (R-CAR-8, R-CLN-5; WP-C, ADR-046): while one is held, eviction, prune, purge and GC never delete the blob.
extension AssetStore {
    /// Pins an asset's blob for the lease's lifetime (R-CAR-8); no await, so no window. Recorded in
    /// `state.cleanup.leases`, which WP-B's reaper reads.
    ///
    /// Throws `.notOpen`/`.closed` outside the open phase, `.unknownAsset` for an id without a record and `.notPresent`
    /// for a record that holds no blob. Acquiring counts as an access (the LRU input, R-CLN-4), through WP-B's
    /// `recordAccesses(_:)`. A stale record's blob is leased like any other: lookups still serve it (store.md §6.1).
    package func acquireLease(_ id: AssetID) throws(StoreError) -> AssetLease {
        try self.ensureOpen()
        guard let record = self.state.core.records[id] else {
            throw .unknownAsset(id)
        }
        guard let blob = record.referencedBlob, let layout = self.state.core.layout else {
            throw .notPresent(id)
        }
        self.state.cleanup.lastLeaseToken += 1
        let token = self.state.cleanup.lastLeaseToken
        self.state.cleanup.leases[blob, default: [:]][token] = id
        self.state.cleanup.leasedBytes[blob] = EvictionOrder.recordedSize(record)
        self.recordAccesses([id: self.environment.time.now()])
        return AssetLease(id: id, blob: blob, token: token, url: layout.blobURL(blob))
    }

    /// Releases a lease; idempotent per token. Returns the store's new deadline (`nextDeadline()`) so the engine can
    /// re-arm (a lease was the reaper's only blocker, store-2 S2-03).
    /// Valid in every phase: a lease released after `close()` changes nothing that matters (leases end with the store).
    package func releaseLease(_ lease: AssetLease) -> MonotonicInstant? {
        if var holders = self.state.cleanup.leases[lease.blob], holders.removeValue(forKey: lease.token) != nil {
            self.state.cleanup.leases[lease.blob] = holders.isEmpty ? nil : holders
            if holders.isEmpty {
                self.state.cleanup.leasedBytes[lease.blob] = nil
            }
        }
        return self.nextDeadline()
    }
}
