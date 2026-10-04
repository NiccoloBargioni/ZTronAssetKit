import ZTronAssetModel

/// Where legacy migration stands (ADR-029). Persisted by WP-B's index codec as STAMPS `legacyState`
/// (0 not started, 1 in progress, 2 done; store.md §2.3).
enum LegacyMigrationPhase: UInt8, Sendable, Hashable {
    /// No legacy layout was planned yet (or none exists).
    case notStarted = 0
    /// Phase 1 planned the files; phase 2 adopts them in batches.
    case inProgress = 1
    /// Phases 3 and 4 ran: the legacy tree and the `UserDefaults` key are gone.
    case done = 2
}

/// WP-C's migration state (ADR-046).
///
/// Contract fields: `phase` and `legacyStamp`, persisted by WP-B's codec (STAMPS `legacyState`, `legacyStamp`), and
/// `progress`, which `migrateLegacy(maxFiles:)` reports. WP-C adds the phase-1 plan (the legacy files still to
/// adopt) as further fields here.
struct MigrationState: Sendable {
    /// Persisted phase.
    var phase: LegacyMigrationPhase = .notStarted
    /// The prior art's `UserDefaults` stamp, read in phase 1 and migrated to the index stamp only when every legacy
    /// entry was adopted (ADR-029); persisted.
    var legacyStamp: String?
    /// Phase-2 progress so far.
    var progress = LegacyMigrationProgress(adopted: 0, remaining: 0, dropped: 0, finished: false)
}
