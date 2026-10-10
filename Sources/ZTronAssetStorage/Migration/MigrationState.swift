import Foundation
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

    // MARK: WP-C bookkeeping, in memory (rebuilt by phase 1 at every launch)

    /// The legacy root this lifetime resolved; `nil` until phase 1 ran (migration disabled, or a read-only lifetime).
    var root: URL?
    /// Files still to adopt, in **reverse** path order: the next one is the last, so a batch takes it and a call that
    /// did not finish puts it back in O(1) (C2: a migration of `maxEntries` files stays linear).
    var queue: [LegacyFile] = []
    /// Files a batch or an adopt-on-demand took from `queue` and is processing (REENTRANCY R11, R18).
    var claimed: [LegacyFile] = []
    /// Every entry of the legacy manifest, in manifest order: phase 3 migrates the stamp only when each one is present
    /// at its current content.
    var legacyIDs: [AssetID] = []
    /// The digest of the legacy manifest phase 1 decoded in this lifetime (`nil`: none was found or decoded, and then
    /// nothing counts as fully adopted). Phase 3 migrates the stamp only while the applied manifest is still this one: a
    /// newer manifest applied during migration was never synced, whatever is present (review round 3, ZProbe-stamp).
    var manifestDigest: ContentHash?
    /// Deferrals of each legacy file in this lifetime, by its path below the root (`AssetStore.deferLegacyFile`).
    var deferrals: [[String]: Int] = [:]
    /// Legacy files kept where they are after `AssetStore.legacyAttempts` deferrals in this lifetime: phase 4 of this
    /// lifetime never removes them, since nothing ever read them (review of the L3 close-out, ZProbe-hash).
    var kept: Set<[String]> = []
    /// Phase 1's writes are in a committed generation: no legacy file moves before that (a crash could otherwise leave
    /// moved files that no committed record expects).
    var planCommitted = false
    /// Legacy entries phase 3's check reads between two releases of the actor (`AssetStore.legacyEntriesPresent`):
    /// `AssetStore.legacyCheckChunk`; a test lowers it so a handful of entries reaches the release and its re-validation
    /// (G4: the seam that release needs).
    var checkChunk: Int = 5_000
}
