import Foundation
import ZTronAssetModel

/// Why an asset has no blob.
package enum AbsenceReason: Sendable, Hashable {
    /// Never fetched (added by a manifest).
    case neverFetched
    /// Quota eviction (R-CLN-4): adoptable again by hash.
    case evicted
    /// A user purge (R-CLN-6): **never** re-adopted from a resurrected blob (store-1 S1-03).
    case purged
    /// Re-download after `needsHeal` or quarantine.
    case healing
}

/// Why a blob is doomed. Persisted with the key (DOOMED section), so launch adoption can refuse the unsafe ones
/// (ADR-018, store-1 S1-03, S1-06).
package enum DoomReason: Sendable, Hashable {
    /// No record references it any more: adoptable by a record that expects it, rescuable by a publish.
    case unreferenced
    /// Purged by the user: never re-adopted, never rescued.
    case purged
    /// Wrong bytes under the name (size mismatch, quarantine): never re-adopted or rescued; a verified publish
    /// replaces it with `rename(.replacing)`.
    case corrupt
}

/// Where an asset stands in the index (R-SYN-2's `absent`/`present` live here; in-flight states live in the
/// engine).
package enum Residency: Sendable, Hashable {
    /// No blob.
    case absent(AbsenceReason)
    /// A blob is referenced. `isStale` is derived: the blob's hash differs from the record's expected content.
    case present(blob: BlobKey, byteSize: Int64, integrity: AssetIntegrity)
    /// The blob vanished (OS purge, external deletion, I-2); re-fetched by the next run or a resolve.
    case needsHeal(lastBlob: BlobKey)
    /// Integrity backoff (R-INT-3, R-CLN-8): not fetched before `until`.
    case quarantined(until: Date)
    /// Failed until the manifest entry changes (R-INT-3).
    case failed(FailureReason)
}

/// R-INT-3 bookkeeping, persisted in the index so a relaunch cannot restart the loop (D-16, sync-2 S2-04).
package struct IntegrityHistory: Sendable, Hashable {
    /// Failures for `failedIdentity` so far.
    package var attempts: UInt8
    /// The content identity the failures were for; a different identity resets the count.
    package var failedIdentity: ContentIdentity?
    /// Not fetched before this wall-clock time.
    package var nextEligibleAt: Date?

    /// Creates bookkeeping.
    package init(attempts: UInt8 = 0, failedIdentity: ContentIdentity? = nil, nextEligibleAt: Date? = nil) {
        self.attempts = attempts
        self.failedIdentity = failedIdentity
        self.nextEligibleAt = nextEligibleAt
    }

    /// No failure recorded.
    package static let clean = IntegrityHistory()
}

/// One asset of the applied manifest, as the index persists it (store.md §2.3, §4.1).
package struct AssetRecord: Sendable, Hashable {
    /// The validated entry (all seven legacy fields plus tags and policy).
    package var entry: ManifestEntry
    /// Where the asset stands.
    package var residency: Residency
    /// The adoption key: the manifest checksum, or the planned hash of a legacy checksum-less file (store.md §7).
    package var expectedBlob: ContentHash?
    /// Last access, wall clock (LRU, R-CLN-4).
    package var lastAccess: Date
    /// When the current blob was published.
    package var storedAt: Date?
    /// When deep verification last re-hashed it (R-INT-4).
    package var verifiedAt: Date?
    /// Never evicted while pinned.
    package var pinned: Bool
    /// R-INT-3 bookkeeping.
    package var integrity: IntegrityHistory
    /// Bumped on every entry change; publications re-validate against it after each await (store-2 S2-15).
    package var revision: UInt64

    /// Creates a record.
    package init(
        entry: ManifestEntry,
        residency: Residency,
        expectedBlob: ContentHash?,
        lastAccess: Date,
        storedAt: Date? = nil,
        verifiedAt: Date? = nil,
        pinned: Bool = false,
        integrity: IntegrityHistory = .clean,
        revision: UInt64 = 0
    ) {
        self.entry = entry
        self.residency = residency
        self.expectedBlob = expectedBlob
        self.lastAccess = lastAccess
        self.storedAt = storedAt
        self.verifiedAt = verifiedAt
        self.pinned = pinned
        self.integrity = integrity
        self.revision = revision
    }
}

/// A lease (R-CAR-8, R-CLN-5): while held, eviction, prune and purge never delete the blob. Leases die with the
/// process and end at `close()`.
package struct AssetLease: Sendable, Hashable {
    /// The asset.
    package let id: AssetID
    /// The blob it pins.
    package let blob: BlobKey
    /// Unique per acquisition; releasing twice is a no-op.
    package let token: UInt64
    /// The blob's URL.
    package let url: URL

    /// Creates a lease (the store only).
    package init(id: AssetID, blob: BlobKey, token: UInt64, url: URL) {
        self.id = id
        self.blob = blob
        self.token = token
        self.url = url
    }
}
