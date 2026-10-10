import Foundation
import ZTronAssetModel

/// WP-C's cleanup state (ADR-046).
///
/// Contract fields: `leases` (read by WP-B's reaper: a leased blob is never deleted, R-CLN-5), and the cleanup
/// stamp `lastCleanupAt`, which WP-B's index codec persists in STAMPS. WP-C adds GC bookkeeping (sweep candidates,
/// REENTRANCY R10) as further fields here. (Round 4 removed `lastMaintenanceAt`: nothing read it and no API set it;
/// STAMPS has no such field, ARCHITECTURE §3.)
struct CleanupState: Sendable {
    /// Live leases by blob, then by token (R-CAR-8, R-CLN-5); in memory only: leases die with the process.
    var leases: [BlobKey: [UInt64: AssetID]] = [:]
    /// The last lease token handed out; tokens are never reused, so a second release is a no-op.
    var lastLeaseToken: UInt64 = 0
    /// The size of each leased blob, recorded at acquisition (the record's size then), so a leased blob that is doomed
    /// meanwhile still counts in `StorageReport.bytesByState.pendingDeletion`; dropped with the blob's last lease.
    var leasedBytes: [BlobKey: Int64] = [:]
    /// When the last orphan GC, staging GC, quota eviction or purge that removed, doomed, evicted or purged something
    /// finished (`StorageReport.lastCleanupAt`, R-CLN-9; a run that changed nothing does not stamp it, ADR draft C-4;
    /// a purge stamps once committed and again after its wait); persisted. Written only by WP-C's own operations: the
    /// reaper's deletions of pruned blobs (WP-B's `runDueWork()`) are not a cleanup run and do not stamp it.
    var lastCleanupAt: Date?
    /// The unreferenced blobs the last orphan GC listing found and left (younger than the grace, or adoptable), with
    /// their sizes: `StorageReport.orphanBytes`. `nil` until the first orphan GC of this lifetime: the report then counts
    /// no orphan bytes (ADR draft C-11; the orphans the launch listed are WP-B's bookkeeping, which WP-C does not read).
    var orphans: [BlobKey: Int64]?
    /// An orphan GC run is in flight: a concurrent call returns at once with an empty result, so no run sweeps a key whose
    /// file another run's doom let the reaper remove after this run's listing saw it (review of the L3 close-out,
    /// ZProbe-phantom). In memory only.
    var collectingOrphans = false
    /// Records a purge changes, and orphans a GC sweep dooms, between two releases of the actor (C2, review round 3 and
    /// the L3 close-out; proposed REENTRANCY rows c-5 and the R10 amendment): `AssetStore.cleanupChunk`; a test lowers it
    /// so a handful of items reaches the release and its re-validation (G4: the seam that release needs).
    var chunk: Int = AssetStore.cleanupChunk
}
