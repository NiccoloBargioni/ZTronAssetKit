import Foundation
import Synchronization
import ZTronAssetModel

/// A pack file read through a `FileHandle` that is opened on the first read (transport.md §11.1).
///
/// The store's sink pulls a `PackFileReader` inside its bulk executor, so a lazy open keeps the blocking
/// `descriptor(for:searchingInAssetPackWithID:)` call off the cooperative pool and the main thread (C2) too. Reading
/// goes through `FileHandle.read(upToCount:)`, so no mutable pointer is needed (C1). The opener is supplied by
/// `LiveAssetPackBackend`, which keeps that device-only file free of decisions: opening failures map to the sink's
/// `SourceFailure` here (an absent pack or file makes the source ask for the pack), and a failed read is `readFailed`.
@available(iOS 26.0, macOS 26.0, *)
final class FileHandleChunkReader: PackFileReader {
    private let open: @Sendable () -> Result<FileHandle, PackError>
    private let handle: Mutex<FileHandle?>

    /// A reader that calls `open` on its first `nextChunk`, never before.
    init(open: @escaping @Sendable () -> Result<FileHandle, PackError>) {
        self.open = open
        self.handle = Mutex(nil)
    }

    /// At most `maxBytes` bytes, or `nil` at the end of the file.
    func nextChunk(maxBytes: Int) throws(StagingError) -> Data? {
        try self.handle.withLock { (handle: inout FileHandle?) throws(StagingError) -> Data? in
            if handle == nil {
                switch self.open() {
                case .success(let opened):
                    handle = opened
                case .failure(let error):
                    throw .source(PackErrorMapping.sourceFailure(error))
                }
            }
            let chunk: Data?
            do {
                chunk = try handle?.read(upToCount: maxBytes)
            } catch {
                throw .source(.readFailed)
            }
            guard let chunk, !chunk.isEmpty else {
                return nil
            }
            return chunk
        }
    }
}

extension PackUpdateCheck {
    /// Validates the identifiers `checkForUpdates()` returned; an id that is not a valid `PackID` cannot name any
    /// pack of ours, so it is dropped.
    init(updatingIDs: Set<String>, removedIDs: Set<String>) {
        self.init(
            updating: Set(updatingIDs.compactMap(PackID.init(rawValue:))),
            removed: Set(removedIDs.compactMap(PackID.init(rawValue:)))
        )
    }
}
