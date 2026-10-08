import Foundation
import ZTronAssetModel

/// Everything one commit unit needs, captured synchronously on the actor (ARCHITECTURE §4.1): the generation is
/// already allocated and the blob table copied (copy-on-write) at capture, so the unit derives DOOMED from that
/// capture and runs off the actor on an immutable value.
struct IndexCommitInput: Sendable {
    /// The layout of the open store.
    var layout: StoreLayout
    /// The generation to write.
    var content: IndexContent
    /// Fan-outs that received or adopted a blob since the last commit, sorted.
    var dirtyFanOuts: [String]
    /// Whether `blobs/` itself must be barrier-synced (after every open, and when a fan-out was created).
    var blobsDirectoryDirty: Bool
    /// Ordered (`F_BARRIERFSYNC`) or durable (`F_FULLFSYNC`, plus `ZTronAssetKit` and `<base>`).
    var durability: CommitDurability
    /// The held lock, whose file identity is re-checked first (store-1 S1-08).
    var lock: FileLockToken?
    /// The blob table captured with the content: the unit derives DOOMED from it (ADR-018, store-2 S2-04), off the
    /// actor (C2: deriving it for 10,000 doomed keys took milliseconds on the actor). Empty when `content.doomed`
    /// is already complete.
    var blobTable: [BlobKey: BlobState] = [:]
    /// The doom bookkeeping of the keys whose deletion unit is in flight when the state was captured.
    var deletingDooms: [BlobKey: DoomInfo] = [:]
    /// The doom of each key whose replacement placement was in flight when the state was captured: `live` in the
    /// table, but the bytes under its name are still the doomed ones (ADR draft B-24).
    var replacingDooms: [BlobKey: DoomInfo] = [:]

    /// The content to encode: `content` with DOOMED completed from the captured blob table.
    var completeContent: IndexContent {
        guard !self.blobTable.isEmpty else {
            return self.content
        }
        var content = self.content
        for (key, blobState) in self.blobTable {
            switch blobState {
            case .doomed(let info):
                content.doomed[key] = info.reason
            case .deleting:
                content.doomed[key] = self.deletingDooms[key]?.reason ?? .unreferenced
            case .live:
                if let replacing = self.replacingDooms[key] {
                    content.doomed[key] = replacing.reason
                }
            }
        }
        return content
    }
}

/// The index commit protocol, one metadata unit (ARCHITECTURE §4.1, ADR-015):
/// 1. barrier-sync dirty fan-outs, then `blobs/`;
/// 2. `write(index.tmp, .truncate)` — on ENOSPC remove `index.tmp` and `index.prev` and retry once;
/// 3. sync `index.tmp` (barrier or full);
/// 4. `rename(index.bin → index.prev)`;
/// 5. `rename(index.tmp → index.bin)`;
/// 6. sync the root (barrier), or full-sync root, `ZTronAssetKit` and `<base>` (durable).
///
/// A failure before the first rename removes `index.tmp` and leaves `index.bin`/`index.prev` untouched; the actor
/// keeps its in-memory state authoritative and restores the dirty directories (REENTRANCY R5).
enum IndexCommitUnit {
    /// Runs the protocol; the encoded size is returned for diagnostics.
    static func run(_ input: IndexCommitInput, fileSystem: any FileSystem) -> Result<Int, StoreError> {
        let layout = input.layout
        if let lock = input.lock, case .failure(let error) = StoreLock.verifyRoot(fileSystem: fileSystem, layout: layout, token: lock) {
            return .failure(error)
        }
        guard let data = IndexCodec.encode(input.completeContent) else {
            return .failure(.storageUnavailable(.ioFailure))
        }
        let temporary = layout.indexURL(.temporary)
        let current = layout.indexURL(.current)
        let level: SyncLevel = input.durability == .durable ? .full : .barrier
        do throws(FileSystemError) {
            for fanOut in input.dirtyFanOuts {
                try IndexCommitUnit.barrier(layout.blobsDirectory.appendingPathComponent(fanOut, isDirectory: true), fileSystem)
            }
            if input.blobsDirectoryDirty {
                try IndexCommitUnit.barrier(layout.blobsDirectory, fileSystem)
            }
        } catch {
            return .failure(.fileSystem(error))
        }
        do throws(FileSystemError) {
            try IndexCommitUnit.writeTemporary(data, layout: layout, fileSystem: fileSystem)
            try fileSystem.synchronizeFile(at: temporary, level: level)
        } catch {
            try? fileSystem.removeItem(at: temporary)
            return .failure(.fileSystem(error))
        }
        do throws(FileSystemError) {
            if try fileSystem.itemInfo(at: current) != nil {
                try fileSystem.rename(from: current, to: layout.indexURL(.previous), mode: .replacing)
            }
            try fileSystem.rename(from: temporary, to: current, mode: .replacing)
            try fileSystem.synchronizeDirectory(at: layout.root, level: level)
            if input.durability == .durable {
                try fileSystem.synchronizeDirectory(at: layout.container, level: .full)
                try fileSystem.synchronizeDirectory(at: layout.container.deletingLastPathComponent(), level: .full)
            }
        } catch {
            return .failure(.fileSystem(error))
        }
        return .success(data.count)
    }

    /// Step 2 with the ENOSPC fallback of ADR-015: the older generations are dropped to make room, once.
    private static func writeTemporary(_ data: Data, layout: StoreLayout, fileSystem: any FileSystem) throws(FileSystemError) {
        let temporary = layout.indexURL(.temporary)
        do throws(FileSystemError) {
            try fileSystem.write(data, to: temporary, mode: .truncate)
        } catch .noSpace {
            try fileSystem.removeItem(at: temporary)
            try fileSystem.removeItem(at: layout.indexURL(.previous))
            try fileSystem.write(data, to: temporary, mode: .truncate)
        }
    }

    /// A barrier sync that tolerates a directory that vanished (nothing in it can be referenced then).
    private static func barrier(_ directory: URL, _ fileSystem: any FileSystem) throws(FileSystemError) {
        do throws(FileSystemError) {
            try fileSystem.synchronizeDirectory(at: directory, level: .barrier)
        } catch .notFound {
            return
        }
    }
}
