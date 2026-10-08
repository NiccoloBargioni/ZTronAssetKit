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
        let handle = try self.openedHandle()
        let chunk: Data?
        do {
            chunk = try handle.read(upToCount: maxBytes)
        } catch {
            throw .source(.readFailed)
        }
        guard let chunk, !chunk.isEmpty else {
            return nil
        }
        return chunk
    }

    /// The handle, opened on the first pull. The lock only publishes the handle between pulls: neither the open nor
    /// a read runs inside it (orchestrator ruling, L2 close-out: no I/O in a `Mutex`'s critical section). The sink
    /// pulls one chunk at a time, so the open runs once; should two first pulls ever overlap, the handle stored first
    /// wins and the other is closed when it is released (the live opener creates handles with `closeOnDealloc`).
    private func openedHandle() throws(StagingError) -> FileHandle {
        if let handle = self.handle.withLock({ $0 }) {
            return handle
        }
        let opened: FileHandle
        switch self.open() {
        case .success(let handle):
            opened = handle
        case .failure(let error):
            throw .source(PackErrorMapping.sourceFailure(error))
        }
        return self.handle.withLock { stored in
            if let stored {
                return stored
            }
            stored = opened
            return opened
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
