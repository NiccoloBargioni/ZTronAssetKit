import ZTronAssetModel

/// WP-C's integrity state (ADR-046). The persisted R-INT-3 bookkeeping lives in each record
/// (`AssetRecord.integrity`, `verifiedAt`), so only the in-memory cursor of deep verification is here; WP-C adds
/// further fields as it needs them.
struct IntegrityState: Sendable {
    /// The last asset deep verification checked in the current pass, in `(verifiedAt, id)` order; `nil` starts a
    /// new pass (R-INT-4, R-SYN-16: maintenance resumes where it stopped).
    var cursor: AssetID?
    /// The blobs verified in the current pass (in memory: after a relaunch the pass restarts from the oldest
    /// `verifiedAt`, which is persisted, so it resumes about where it stopped). Ordering by `verifiedAt` alone would
    /// loop forever when the wall clock is set back; this set makes every pass finite.
    var verifiedInPass: Set<BlobKey> = []
}
