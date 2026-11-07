import ZTronAssetModel

/// WP-C's eviction state (ADR-046): in memory only, rebuilt at every launch by the engine's push.
///
/// Contract field: `retentionScope`, read by WP-B's `adoptionReport()` for `AdoptionReport.excludedRemotePaths`.
/// WP-C adds eviction bookkeeping (for example the last selection, for REENTRANCY R8) as further fields here.
struct EvictionState: Sendable {
    /// What the app wants kept (R-CAR-5, ADR-027); `.all` until the engine pushes the configured scope after
    /// `open()`.
    var retentionScope: AssetScope = .all
    /// Records quota eviction marks between two yields of the actor, in whole blobs, except a blob of more records than
    /// this, which is taken this many of its records per turn (C2, REENTRANCY R8 and s3c-1; Stage 3 ruling S3C-2), and
    /// the records of each chunk `apply` passes to the hook, in whole blobs (`ApplyEvictionChunks`, proposed row c-8;
    /// ruling R6 at the L3 close-out cycle 7): `AssetStore.evictionChunk`; a test lowers it so a handful of blobs
    /// reaches the yield and its re-validation (G4: the seam that yield needs).
    var chunk: Int = AssetStore.evictionChunk
    /// The scans of every record that `holders(of:known:scan:)` made in this lifetime, because the ids a snapshot saw
    /// did not account for a blob's references (diagnostics, in memory only): a test reads it to show how many scans one
    /// actor turn makes (C2, review of the L3 close-out cycle 4).
    var holderScans = 0
    /// The bytes quota eviction (maintenance and `apply`'s plan), purge, quarantine and recorded failures released to the
    /// reaper in this lifetime, and `apply`'s and `admit`'s own releases (prune, a replaced detached record's or an
    /// adopted record's previous blob), counted by WP-B (S3B-9), each counted in the turn its blob was doomed. Lowered
    /// when a doom that `apply` or `admit` counted is rescued (its bytes are back in `usedBytes`), so readers take
    /// differences against the value read at their measurement. A maintenance run reads it
    /// in the turn its space figures were measured and counts every byte released since toward its need, its own and
    /// those of an eviction, an `apply`, a purge or a quarantine that ran while it awaited (store.md §6.4; review of the
    /// L3 close-out cycle 5: two overlapping runs each chased the need they measured alone and evicted the whole store;
    /// cycle 6: a quarantine meanwhile made a run evict one asset too many, ruling R7 at cycle 7).
    var releasedBytes: Int64 = 0
}
