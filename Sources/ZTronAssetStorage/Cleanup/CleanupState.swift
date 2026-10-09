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
    /// When the last orphan GC, staging GC, quota eviction or purge finished (`StorageReport.lastCleanupAt`,
    /// R-CLN-9); persisted. Written only by WP-C's own operations: the reaper's deletions of pruned blobs (WP-B's
    /// `runDueWork()`) are not a cleanup run and do not stamp it.
    var lastCleanupAt: Date?
    /// The unreferenced blobs the last orphan GC listing found and left (younger than the grace, or adoptable), with
    /// their sizes: `StorageReport.orphanBytes`. `nil` until the first listing of this lifetime, when the report uses
    /// the orphans the launch listed.
    var orphans: [BlobKey: Int64]?
}
