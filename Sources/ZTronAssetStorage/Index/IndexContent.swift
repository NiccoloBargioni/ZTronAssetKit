import Foundation
import ZTronAssetModel

/// The 16 bytes that name one store root's index lineage (store.md §2.3): a `prev` or `tmp` written by another
/// store is ignored at load.
struct StoreIdentifier: Hashable, Sendable {
    /// Bytes 0…7 of the identifier.
    var high: UInt64
    /// Bytes 8…15 of the identifier.
    var low: UInt64

    /// The identifier of a store that has none yet.
    static let zero = StoreIdentifier(high: 0, low: 0)

    /// Derives the identifier of a new store from the environment's seed (ADR-024: keyed, never drawn by order), so
    /// tests are deterministic and the live seed makes it random.
    static func derived(fromSeed seed: UInt64) -> StoreIdentifier {
        let key = StableHash.fnv1a64("ZTronAssetKit.storeID")
        let high = KeyedRandom.next64(seed: seed, key: key, counter: 0)
        let low = KeyedRandom.next64(seed: seed, key: key, counter: 1)
        return StoreIdentifier(high: high, low: low == 0 && high == 0 ? 1 : low)
    }
}

/// Everything one index generation persists (R-STO-2: the store's whole description lives inside the root).
///
/// The applied manifest is stored as the records' entries in manifest order plus its metadata (digest, wire shape,
/// quarantine count); per-entry quarantine **diagnostics** are not persisted (they matter only while a fetch is
/// reported), so a reloaded manifest has `quarantined == []` and the same `quarantinedCount` (ADR draft B-4).
struct IndexContent: Sendable, Equatable {
    /// The store lineage.
    var storeID: StoreIdentifier
    /// The generation (strictly increasing per commit attempt, I-5).
    var generation: UInt64
    /// The launch epoch of the instance that wrote it (ADR-012, ADR-013).
    var launchEpoch: UInt64
    /// Wall-clock milliseconds at encode time (diagnostics only).
    var writtenAtMillis: Int64
    /// Degraded mode outlives a crash (store.md §2.5).
    var degraded: Bool
    /// The applied manifest.
    var appliedManifest: ValidatedManifest
    /// The applied manifest's entity tag.
    var etag: ETag?
    /// Records by id.
    var records: [AssetID: AssetRecord]
    /// The sync stamp.
    var stamp: SyncStamp?
    /// The persisted "sync due" flag.
    var syncDue: Bool
    /// WP-C's cleanup stamp (`StorageReport.lastCleanupAt`).
    var lastCleanupAt: Date?
    /// WP-C's legacy migration phase.
    var legacyPhase: LegacyMigrationPhase
    /// WP-C's legacy stamp.
    var legacyStamp: String?
    /// The DOOMED section, derived from the blob table at capture (ADR-018).
    var doomed: [BlobKey: DoomReason]

    /// An empty generation of a new store.
    static func empty(storeID: StoreIdentifier) -> IndexContent {
        IndexContent(
            storeID: storeID,
            generation: 0,
            launchEpoch: 0,
            writtenAtMillis: 0,
            degraded: false,
            appliedManifest: .empty(),
            etag: nil,
            records: [:],
            stamp: nil,
            syncDue: false,
            lastCleanupAt: nil,
            legacyPhase: .notStarted,
            legacyStamp: nil,
            doomed: [:]
        )
    }
}

/// Why an index file is not a valid generation (store.md §2.3). The load rule never traps on any input
/// (store-1 S1-04).
enum IndexDecodeError: Error, Sendable, Hashable {
    /// The size is not exactly `64 + bodyLength + 32`, or the file is shorter than its header.
    case torn
    /// The first eight bytes are not `ZTAKIDX\0`.
    case badMagic
    /// Written by a newer schema: never decoded, and the load becomes degraded (a downgrade never deletes).
    case newerSchema(UInt16)
    /// The SHA-256 trailer does not match.
    case trailerMismatch
    /// A length or count exceeds what the file can hold.
    case limitExceeded
    /// Structurally invalid content.
    case malformed
}
