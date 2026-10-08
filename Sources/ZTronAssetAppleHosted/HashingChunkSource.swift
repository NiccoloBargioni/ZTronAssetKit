import CryptoKit
import Foundation
import Synchronization
import ZTronAssetModel

/// Forwards a pack reader's chunks to the store while hashing them (transport-2 T2-12, T2-20).
///
/// `StagingSink.writeStaged` pulls chunks inside the store's bulk executor in ≤ 1 MiB units, so hashing here keeps
/// the SHA-256 of a catalog at the 32 MiB cap (10.75 ms one-shot on an M3) off the cooperative pool (C2) without a
/// contract change, and gives the source the digest of exactly the bytes the store staged: the catalog's pseudo-ETag
/// and the check that tells pack/catalog skew from a good copy. The sink calls `nextChunk` once at a time, so the
/// `Mutex` only publishes the hasher state between those calls; it exists wherever the Apple tier does (iOS 26).
@available(iOS 26.0, macOS 26.0, *)
final class HashingChunkSource: ChunkSource {
    private let base: any ChunkSource
    private let hasher: Mutex<SHA256>

    /// Wraps `base`; reads nothing yet.
    init(_ base: any ChunkSource) {
        self.base = base
        self.hasher = Mutex(SHA256())
    }

    /// The base reader's next chunk, hashed on the way through.
    func nextChunk(maxBytes: Int) throws(StagingError) -> Data? {
        guard let chunk = try self.base.nextChunk(maxBytes: maxBytes) else {
            return nil
        }
        self.hasher.withLock { $0.update(data: chunk) }
        return chunk
    }

    /// The SHA-256 of every byte forwarded so far.
    var digest: ContentHash {
        self.hasher.withLock { ContentHash(digest: $0.finalize()) }
    }
}
