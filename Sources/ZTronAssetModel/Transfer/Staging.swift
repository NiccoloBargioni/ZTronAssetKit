import Foundation

/// Why a staging write failed. Mapped by the transport into `TransferError` (ENOSPC → `insufficientSpace`).
public enum StagingError: Error, Sendable, Hashable {
    /// ENOSPC.
    case insufficientSpace
    /// Any other POSIX failure.
    case io(posixCode: Int32)
    /// More bytes than the cap.
    case tooLarge(limit: Int64)
    /// A `ChunkSource` (Apple pack reader) failed.
    case source(SourceFailure)
    /// The name is already taken (an exclusive rename found the destination): a uniqueness bug, never data loss.
    case nameInUse
    /// The store is closed; nothing may be written (R-SYN-15).
    case closed
}

/// Why a `ChunkSource` failed.
public enum SourceFailure: Sendable, Hashable {
    /// The file is not in the source.
    case notFound
    /// The source (pack) is not installed.
    case notInstalled
    /// A read failed.
    case readFailed
    /// An undocumented system error (Apple tier, APPLE-API-VERIFICATION §1.8).
    case system(domain: String, code: Int)
}

/// A blocking pull of at most `maxBytes`. Called only inside a `BlockingExecutor` unit (ADR-003); `nil` at EOF.
public protocol ChunkSource: Sendable {
    /// The next chunk, or `nil` at the end.
    func nextChunk(maxBytes: Int) throws(StagingError) -> Data?
}

/// The transport's only window onto `staging/` (implemented by `ZTronAssetStorage` over the `FileSystem` seam,
/// R-STO-6): the transport never touches `FileManager` (R-STO-1, ADR-019).
///
/// The synchronous members run on URLSession's serial delegate queue, which is neither the main thread nor the
/// cooperative pool (C2); each is one bounded unit. Every member fails with `.closed` once the store is closed.
public protocol StagingSink: Sendable {
    /// Creates (or truncates) the partial file of a fresh attempt.
    func createPartial(_ name: StagingFileName) throws(StagingError)
    /// Appends a received chunk; returns the partial's new size. Data tasks call it from `didReceive data`.
    func appendPartial(_ data: Data, to name: StagingFileName) throws(StagingError) -> Int64
    /// Moves an earlier attempt's partial to this attempt's name with an exclusive rename and returns its size,
    /// so a resumed attempt continues it without two producers ever sharing a name (transport-2 T2-02).
    func continuePartial(from previous: StagingFileName, as next: StagingFileName) throws(StagingError) -> Int64
    /// Background download tasks only: moves the OS temp file into `staging/<name>` before the delegate returns
    /// (R-STO-1). Exclusive: never replaces.
    func adoptDownload(at location: URL, as name: StagingFileName) throws(StagingError) -> Int64
    /// Best effort, atomic (`.resumetmp` then rename): records how to continue a partial (R-NET-8).
    func writeSidecar(_ sidecar: ResumeSidecar)
    /// Reads a partial's sidecar off the pool; `nil` when absent or undecodable.
    func readSidecar(for name: StagingFileName) async -> ResumeSidecar?
    /// Manifest path: reads a staged file (≤ `maxBytes`) off the pool.
    func readStaged(_ name: StagingFileName, maxBytes: Int64) async throws(StagingError) -> Data
    /// Removes a staging file and its sidecar; idempotent.
    func discard(_ name: StagingFileName) async
    /// Apple tier: pulls `source` in ≤ 1 MiB units on the bulk executor into `staging/<name>`; returns the size.
    func writeStaged(_ name: StagingFileName, from source: any ChunkSource, maxBytes: Int64) async throws(StagingError) -> Int64
}
