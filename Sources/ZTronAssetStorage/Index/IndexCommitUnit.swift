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
    /// The newest committed generation, which `index.bin` holds after every successful commit: the ENOSPC fallback
    /// drops `index.prev` only when `index.bin` provably holds it (ADR draft B-28). `0` keeps `index.prev` always.
    var committedGeneration: UInt64 = 0
    /// The generation of a loaded `index.tmp` that must become `index.bin` before `index.tmp` is written again
    /// (ADR draft B-28): the launch chose it, so it is the newest valid generation and may be the only one.
    var promotion: UInt64?

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

/// What one commit unit did.
struct IndexCommitOutcome: Sendable {
    /// The encoded size on success (diagnostics), or the failure.
    var result: Result<Int, StoreError>
    /// The loaded `index.tmp` was renamed to `index.bin`, or had vanished (the promotion is no longer pending, whatever
    /// followed).
    var promotedName = false
    /// The promoted file's data was synced before that rename, and the rename was ordered by the root's sync: the
    /// promoted generation is committed.
    var promotedDurably = false
}

/// The index commit protocol, one metadata unit (ARCHITECTURE §4.1, ADR-015, as amended by ADR draft B-28):
/// 0. when the launch loaded `index.tmp`, promote it first: sync `index.tmp` (a killed process may have written it
///    without step 3), `index.bin → index.prev` (under the condition of step 4), `index.tmp → index.bin`, sync the root
///    (it is valid, so this completes the interrupted commit instead of truncating its generation); a vanished
///    `index.tmp` completes the promotion without a commit;
/// 1. barrier-sync dirty fan-outs, then `blobs/`;
/// 2. `write(index.tmp, .truncate)` — on ENOSPC remove `index.tmp`, and `index.prev` only when `index.bin` holds the
///    committed generation, then retry once;
/// 3. sync `index.tmp` (barrier or full);
/// 4. `rename(index.bin → index.prev)`, only when `index.prev` is absent or `index.bin` holds the committed generation
///    (otherwise step 5 renames straight over the invalid or uncommitted `index.bin`, keeping `index.prev`);
/// 5. `rename(index.tmp → index.bin)` — on failure step 4 is rolled back, so `index.bin` is never missing after a
///    failed commit;
/// 6. sync the root (barrier), or full-sync root, `ZTronAssetKit` and `<base>` (durable).
///
/// A failure before the first rename removes `index.tmp` and leaves `index.bin`/`index.prev` untouched; the actor
/// keeps its in-memory state authoritative and restores the dirty directories (REENTRANCY R5).
enum IndexCommitUnit {
    /// Runs the protocol.
    static func run(_ input: IndexCommitInput, fileSystem: any FileSystem) -> IndexCommitOutcome {
        let layout = input.layout
        if let lock = input.lock, case .failure(let error) = StoreLock.verifyRoot(fileSystem: fileSystem, layout: layout, token: lock) {
            return IndexCommitOutcome(result: .failure(error))
        }
        let level: SyncLevel = input.durability == .durable ? .full : .barrier
        var outcome = IndexCommitOutcome(result: .failure(.storageUnavailable(.ioFailure)))
        var committed = input.committedGeneration
        if let promotion = input.promotion {
            do throws(FileSystemError) {
                if try IndexCommitUnit.promote(committed: committed, level: level, layout: layout, fileSystem: fileSystem, outcome: &outcome) {
                    committed = promotion
                }
            } catch {
                outcome.result = .failure(.fileSystem(error))
                return outcome
            }
        }
        guard let data = IndexCodec.encode(input.completeContent) else {
            return outcome
        }
        let temporary = layout.indexURL(.temporary)
        do throws(FileSystemError) {
            for fanOut in input.dirtyFanOuts {
                try IndexCommitUnit.barrier(layout.blobsDirectory.appendingPathComponent(fanOut, isDirectory: true), fileSystem)
            }
            if input.blobsDirectoryDirty {
                try IndexCommitUnit.barrier(layout.blobsDirectory, fileSystem)
            }
        } catch {
            outcome.result = .failure(.fileSystem(error))
            return outcome
        }
        do throws(FileSystemError) {
            try IndexCommitUnit.writeTemporary(data, layout: layout, committed: committed, fileSystem: fileSystem)
            try fileSystem.synchronizeFile(at: temporary, level: level)
        } catch {
            try? fileSystem.removeItem(at: temporary)
            outcome.result = .failure(.fileSystem(error))
            return outcome
        }
        do throws(FileSystemError) {
            try IndexCommitUnit.replaceCurrent(with: temporary, committed: committed, layout: layout, fileSystem: fileSystem)
            try fileSystem.synchronizeDirectory(at: layout.root, level: level)
            if input.durability == .durable {
                try fileSystem.synchronizeDirectory(at: layout.container, level: .full)
                try fileSystem.synchronizeDirectory(at: layout.container.deletingLastPathComponent(), level: .full)
            }
        } catch {
            outcome.result = .failure(.fileSystem(error))
            return outcome
        }
        outcome.result = .success(data.count)
        return outcome
    }

    /// Step 0, the promotion of the loaded `index.tmp` (ADR draft B-28); returns whether its generation is committed now.
    ///
    /// The load rule accepts any complete `index.tmp`, also one a killed process wrote at step 2 and never synced (step
    /// 3): its data is synced at the commit's level before it becomes `index.bin` and counts as committed, or the ENOSPC
    /// fallback could drop `index.prev` for a file a power loss empties (probe VP7). A vanished `index.tmp` (an outside
    /// deletion inside the private root, or a rename that took effect but reported failure) completes the promotion
    /// without a commit (probe VPC2-K): nothing is left to promote, and whatever reached `index.bin` was never ordered by
    /// a root sync, so it does not count as committed; the commit goes on with steps 1–6 and supersedes it. Before, the
    /// sync threw `notFound` on every attempt and the promotion blocked every later commit, `close()`'s included.
    private static func promote(
        committed: UInt64,
        level: SyncLevel,
        layout: StoreLayout,
        fileSystem: any FileSystem,
        outcome: inout IndexCommitOutcome
    ) throws(FileSystemError) -> Bool {
        let temporary = layout.indexURL(.temporary)
        do throws(FileSystemError) {
            guard try fileSystem.itemInfo(at: temporary) != nil else {
                throw .notFound
            }
            try fileSystem.synchronizeFile(at: temporary, level: level)
        } catch .notFound {
            outcome.promotedName = true
            return false
        }
        try IndexCommitUnit.replaceCurrent(with: temporary, committed: committed, layout: layout, fileSystem: fileSystem)
        outcome.promotedName = true
        try fileSystem.synchronizeDirectory(at: layout.root, level: level)
        outcome.promotedDurably = true
        return true
    }

    /// Steps 4 and 5: `index.bin → index.prev`, then `source → index.bin`. Step 4 runs only when `index.bin` exists and
    /// either `index.prev` does not or `index.bin` holds the committed generation (`committed`, ADR draft B-28 as
    /// amended in close-out cycle 3): otherwise `index.bin` is rotten, foreign or an uncommitted attempt, `index.prev`
    /// may hold the only valid generation, and `source` is renamed straight over `index.bin` instead (probe VPC2-D: a
    /// rotten `index.bin` moved over the only valid `index.prev`). When the second rename fails the first is undone
    /// (`index.prev → index.bin`, exclusive, so nothing that did reach `index.bin` is overwritten): a failed commit never
    /// leaves the newest committed generation only in `index.prev`, where the next commit's ENOSPC fallback or a later
    /// `index.bin → index.prev` would drop it (review round 3, probe 1). A failed undo leaves `index.prev` in place,
    /// which the ENOSPC fallback then keeps.
    private static func replaceCurrent(with source: URL, committed: UInt64, layout: StoreLayout, fileSystem: any FileSystem) throws(FileSystemError) {
        let current = layout.indexURL(.current)
        let previous = layout.indexURL(.previous)
        let currentExists = try fileSystem.itemInfo(at: current) != nil
        let previousExists = currentExists ? try fileSystem.itemInfo(at: previous) != nil : false
        let moved = currentExists && (!previousExists || IndexCommitUnit.currentHolds(committed, layout: layout, fileSystem: fileSystem))
        if moved {
            try fileSystem.rename(from: current, to: previous, mode: .replacing)
        }
        do throws(FileSystemError) {
            try fileSystem.rename(from: source, to: current, mode: .replacing)
        } catch {
            if moved {
                try? fileSystem.rename(from: previous, to: current, mode: .exclusive)
            }
            throw error
        }
    }

    /// Step 2 with the ENOSPC fallback of ADR-015 as amended by ADR draft B-28: `index.tmp` is dropped to make room,
    /// and `index.prev` only when `index.bin` holds the committed generation, so the newest valid generation is never
    /// the one removed; then the write is retried once.
    private static func writeTemporary(_ data: Data, layout: StoreLayout, committed: UInt64, fileSystem: any FileSystem) throws(FileSystemError) {
        let temporary = layout.indexURL(.temporary)
        do throws(FileSystemError) {
            try fileSystem.write(data, to: temporary, mode: .truncate)
        } catch .noSpace {
            try fileSystem.removeItem(at: temporary)
            if IndexCommitUnit.currentHolds(committed, layout: layout, fileSystem: fileSystem) {
                try fileSystem.removeItem(at: layout.indexURL(.previous))
            }
            try fileSystem.write(data, to: temporary, mode: .truncate)
        }
    }

    /// Whether `index.bin` is the complete file of generation `generation` (> 0): its header parses, names that
    /// generation, and its size is exactly `64 + bodyLength + 32`. `index.bin` only ever arrives by renaming a synced,
    /// complete `index.tmp`, and every attempt has a generation of its own (I-5), so a header naming the committed
    /// generation is the file that was committed (or loaded); a rotten or foreign `index.bin` names another one.
    static func currentHolds(_ generation: UInt64, layout: StoreLayout, fileSystem: any FileSystem) -> Bool {
        let current = layout.indexURL(.current)
        guard generation > 0,
            let info = try? fileSystem.itemInfo(at: current), info.kind == .file,
            let bytes = try? fileSystem.read(from: current, offset: 0, maxLength: IndexHeader.length),
            let header = IndexHeader.parse([UInt8](bytes)), header.generation == generation,
            header.bodyLength <= IndexHeader.maxBodyLength
        else {
            return false
        }
        return info.byteSize == Int64(IndexHeader.length) + Int64(header.bodyLength) + Int64(IndexHeader.trailerLength)
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
