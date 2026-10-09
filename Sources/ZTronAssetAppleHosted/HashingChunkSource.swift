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
    private struct State {
        var hasher = SHA256()
        var stopped = false
    }

    /// The domain of the failure a stopped copy reports to the sink (the copier recognises the stop by `stopped`).
    static let stopDomain = "ZTronAssetAppleHosted.copyStopped"

    private let base: any ChunkSource
    private let shouldStop: @Sendable () -> Bool
    private let state: Mutex<State>

    /// Wraps `base`; reads nothing yet. `shouldStop` is asked before every chunk: once it says yes, the copy ends at
    /// that chunk boundary without reading the pack file further, so a paused or cancelled transfer, or an
    /// invalidating source, waits for at most one more ≤ 1 MiB unit instead of a whole pack file.
    init(_ base: any ChunkSource, shouldStop: @escaping @Sendable () -> Bool) {
        self.base = base
        self.shouldStop = shouldStop
        self.state = Mutex(State())
    }

    /// The base reader's next chunk, hashed on the way through; a source failure once the copy should stop.
    func nextChunk(maxBytes: Int) throws(StagingError) -> Data? {
        guard !self.shouldStop() else {
            self.state.withLock { $0.stopped = true }
            throw .source(.system(domain: Self.stopDomain, code: Int(ECANCELED)))
        }
        guard let chunk = try self.base.nextChunk(maxBytes: maxBytes) else {
            return nil
        }
        self.state.withLock { $0.hasher.update(data: chunk) }
        return chunk
    }

    /// Whether the copy was stopped (the sink then failed with the stop's source failure).
    var stopped: Bool {
        self.state.withLock { $0.stopped }
    }

    /// The SHA-256 of every byte forwarded so far.
    var digest: ContentHash {
        self.state.withLock { ContentHash(digest: $0.hasher.finalize()) }
    }
}
