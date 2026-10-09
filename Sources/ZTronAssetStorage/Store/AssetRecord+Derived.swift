import Foundation
import ZTronAssetModel

extension AssetRecord {
    /// The blob the record holds a reference to: only `present` records reference a blob (a `needsHeal` record names
    /// its vanished blob but holds no reference).
    package var referencedBlob: BlobKey? {
        if case .present(let blob, _, _) = self.residency {
            return blob
        }
        return nil
    }

    /// The blob key the record's current content would have, when it is known: the expected hash (manifest
    /// checksum, a legacy planned hash, or the digest a checksum-less publish recorded) with the entry's validated
    /// extension.
    package var expectedKey: BlobKey? {
        guard let hash = self.expectedBlob, let ext = AssetFileExtension(self.entry.fileExtension) else {
            return nil
        }
        return BlobKey(hash: hash, ext: ext)
    }

    /// Present at superseded content: the referenced blob is not the current content (a checksum change, a
    /// checksum-less `remotePath` change, which clears the expectation, or an extension change). Stale assets are
    /// still served until the new bytes commit (store.md §6.1).
    package var isStale: Bool {
        guard let blob = self.referencedBlob else {
            return false
        }
        return blob != self.expectedKey
    }

    /// Whether a blob found on disk may be bound to this record without downloading (ADR-018): never fetched,
    /// evicted, healing, `needsHeal` or stale; never `purged`, `failed` or `quarantined`.
    var acceptsAdoption: Bool {
        switch self.residency {
        case .absent(let reason):
            return reason != .purged
        case .needsHeal:
            return true
        case .present:
            return self.isStale
        case .quarantined, .failed:
            return false
        }
    }
}
