/// All mutable state of `AssetStore`, as one value with one sub-struct per owner (ADR-046).
///
/// Declared in the contract so that `extension AssetStore` files in other directories can read and mutate it: an
/// extension can neither add stored properties nor see `private` state. Each sub-struct is declared in a file of
/// its owner, who may add fields to it (and only to it); the fields declared in Stage 1 are contract fields the
/// other package relies on, so they keep their names and meaning:
/// - `core` (`Store/StoreCoreState.swift`, **WP-B**): lifecycle, index (manifest, records, stamps), blob table,
///   publications in flight, metrics. WP-C reads it and mutates it only through `Store/StoreInternals.swift`, except
///   the documented direct writes (`purgeEpoch`, `stamp`, record `pinned`/`integrity`/`verifiedAt`, metrics, and
///   legacy migration's `appliedManifest`, record insertion, `degraded` and `syncDue`; ARCHITECTURE §1.1 rule 1).
/// - `cleanup` (`Cleanup/CleanupState.swift`, **WP-C**): leases and the cleanup stamp. WP-B reads the leases (the
///   reaper never deletes a leased blob) and persists the stamp.
/// - `eviction` (`Eviction/EvictionState.swift`, **WP-C**): the retention scope. WP-B reads it (`adoptionReport`).
/// - `integrity` (`Integrity/IntegrityState.swift`, **WP-C**): the deep-verification cursor.
/// - `migration` (`Migration/MigrationState.swift`, **WP-C**): legacy migration phase and stamp, persisted by WP-B's
///   index codec (STAMPS `legacyState`, `legacyStamp`), and in-memory progress.
///
/// A value type held by the actor: a commit captures what it needs synchronously (copy-on-write, O(1)) before its
/// unit runs off the actor (ARCHITECTURE §4.1).
struct StoreState: Sendable {
    /// WP-B: index, blob table, publications, commits, snapshots.
    var core = StoreCoreState()
    /// WP-C: leases, cleanup stamps.
    var cleanup = CleanupState()
    /// WP-C: retention scope and eviction bookkeeping.
    var eviction = EvictionState()
    /// WP-C: deep-verification cursor.
    var integrity = IntegrityState()
    /// WP-C: legacy migration.
    var migration = MigrationState()
}
