import ZTronAssetModel

/// WP-C's eviction state (ADR-046): in memory only, rebuilt at every launch by the engine's push.
///
/// Contract field: `retentionScope`, read by WP-B's `adoptionReport()` for `AdoptionReport.excludedRemotePaths`.
/// WP-C adds eviction bookkeeping (for example the last selection, for REENTRANCY R8) as further fields here.
struct EvictionState: Sendable {
    /// What the app wants kept (R-CAR-5, ADR-027); `.all` until the engine pushes the configured scope after
    /// `open()`.
    var retentionScope: AssetScope = .all
}
