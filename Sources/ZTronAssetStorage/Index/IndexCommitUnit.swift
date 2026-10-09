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
    /// The newest committed generation, which `index.bin` holds after every successful commit (ADR draft B-28). `0`
    /// counts nothing committed.
    var committedGeneration: UInt64 = 0
    /// The index name that holds `committedGeneration`, as the store knows it (`CommitBookkeeping.committedFile`): the
    /// file the load validated in full (trailer included), or where the units' own renames put it; `nil` when nothing
    /// is committed. Step 4 and the ENOSPC fallback trust it and never a header (ADR draft B-28 as amended in close-out
    /// cycle 5): a bit flip in the generation field of a rotten file makes its header, which has no checksum of its
    /// own, name the committed generation, with the right size.
    var committedFile: IndexFile?
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
    /// The index name that holds the generation the store counts committed after this unit (`index.bin` after a
    /// success; the input's file followed through the unit's renames otherwise; see `IndexCommitInput.committedFile`).
    var committedFile: IndexFile?
}

/// What the store knows about its index files between two commit units (ADR draft B-28): the newest committed
/// generation, the index name that holds it, and the loaded `index.tmp` still to promote. `AssetStore.commitNow` folds
/// every unit's outcome through `recording(_:of:)`, and so does the state-space test of the protocol, so the two cannot
/// drift apart.
struct IndexCommitLedger: Sendable, Equatable {
    /// The newest committed generation (`StoreCoreState.committedGeneration`).
    var committedGeneration: UInt64
    /// The index name that holds it (`CommitBookkeeping.committedFile`); `nil` when nothing is committed.
    var committedFile: IndexFile?
    /// The generation of the loaded `index.tmp` still to promote (`CommitBookkeeping.pendingPromotion`).
    var pendingPromotion: UInt64?

    /// The ledger after a unit that ran on `input` returned `outcome`: a promotion that renamed its file, or found it
    /// gone, is no longer pending; a durable promotion and a successful commit raise the committed generation (never
    /// lower it), and nothing else does; the committed generation is where the unit's renames left it.
    func recording(_ outcome: IndexCommitOutcome, of input: IndexCommitInput) -> IndexCommitLedger {
        var ledger = self
        if outcome.promotedName {
            ledger.pendingPromotion = nil
        }
        var counted = input.committedGeneration
        if outcome.promotedDurably, let promoted = input.promotion {
            counted = max(counted, promoted)
        }
        if case .success = outcome.result {
            counted = max(counted, input.content.generation)
        }
        // The unit followed the file of the generation it counts; a ledger already past it (never, while one commit
        // runs at a time) cannot know where its own generation went.
        ledger.committedFile = counted > 0 && counted >= ledger.committedGeneration ? outcome.committedFile : nil
        ledger.committedGeneration = max(ledger.committedGeneration, counted)
        return ledger
    }
}

/// The index commit protocol, one metadata unit (ARCHITECTURE §4.1, ADR-015, as amended by ADR draft B-28):
/// 0. when the launch loaded `index.tmp`, promote it first: sync `index.tmp` (a killed process may have written it
///    without step 3), `index.bin → index.prev` (under the condition of step 4), `index.tmp → index.bin`, sync the root
///    (it is valid, so this completes the interrupted commit instead of truncating its generation); a vanished
///    `index.tmp` completes the promotion without a commit;
/// 1. barrier-sync dirty fan-outs, then `blobs/`;
/// 2. `write(index.tmp, .truncate)` — on ENOSPC remove `index.tmp`, and `index.prev` only when `index.bin` is the file
///    that holds the committed generation, then retry once;
/// 3. sync `index.tmp` (barrier or full);
/// 4. `rename(index.bin → index.prev)`, only when `index.prev` is absent or `index.bin` is the file that holds the
///    committed generation (otherwise step 5 renames straight over the invalid or uncommitted `index.bin`, keeping
///    `index.prev`);
/// 5. `rename(index.tmp → index.bin)` — on failure step 4 is rolled back, so `index.bin` is never missing after a
///    failed commit;
/// 6. sync the root (barrier), or full-sync root, `ZTronAssetKit` and `<base>` (durable).
///
/// A failure before the first rename removes `index.tmp` and leaves `index.bin`/`index.prev` untouched; the actor
/// keeps its in-memory state authoritative and restores the dirty directories (REENTRANCY R5).
///
/// Which file holds the committed generation is carried (`IndexCommitInput.committedFile`), never read from a header:
/// the load validated that file in full and the units' renames move it (close-out cycle 5). A header names a generation
/// only as long as nothing rotted, and its generation field is not covered by any check of its own, so a rotten
/// `index.bin` can name the committed generation with the right size; taking that for proof moved it over the only
/// valid `index.prev`.
enum IndexCommitUnit {
    /// Runs the protocol.
    static func run(_ input: IndexCommitInput, fileSystem: any FileSystem) -> IndexCommitOutcome {
        let layout = input.layout
        var outcome = IndexCommitOutcome(
            result: .failure(.storageUnavailable(.ioFailure)),
            committedFile: input.committedGeneration > 0 ? input.committedFile : nil
        )
        if let lock = input.lock, case .failure(let error) = StoreLock.verifyRoot(fileSystem: fileSystem, layout: layout, token: lock) {
            outcome.result = .failure(error)
            return outcome
        }
        let level: SyncLevel = input.durability == .durable ? .full : .barrier
        if input.promotion != nil {
            do throws(FileSystemError) {
                try IndexCommitUnit.promote(level: level, layout: layout, fileSystem: fileSystem, outcome: &outcome)
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
            try IndexCommitUnit.writeTemporary(data, layout: layout, committedFile: outcome.committedFile, fileSystem: fileSystem)
            try fileSystem.synchronizeFile(at: temporary, level: level)
        } catch {
            try? fileSystem.removeItem(at: temporary)
            outcome.result = .failure(.fileSystem(error))
            return outcome
        }
        do throws(FileSystemError) {
            try IndexCommitUnit.replaceCurrent(with: .temporary, layout: layout, fileSystem: fileSystem, committedFile: &outcome.committedFile)
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
        outcome.committedFile = .current
        return outcome
    }

    /// Step 0, the promotion of the loaded `index.tmp` (ADR draft B-28): once it succeeded, its generation is committed
    /// and `index.bin` holds it.
    ///
    /// The load rule accepts any complete `index.tmp`, also one a killed process wrote at step 2 and never synced (step
    /// 3): its data is synced at the commit's level before it becomes `index.bin` and counts as committed, or the ENOSPC
    /// fallback could drop `index.prev` for a file a power loss empties (probe VP7). A vanished `index.tmp` (an outside
    /// deletion inside the private root, or a rename that took effect but reported failure) completes the promotion
    /// without a commit (probe VPC2-K): nothing is left to promote, and whatever reached `index.bin` was never ordered by
    /// a root sync, so it does not count as committed; the commit goes on with steps 1–6 and supersedes it. Before, the
    /// sync threw `notFound` on every attempt and the promotion blocked every later commit, `close()`'s included.
    /// Only the stat decides that the file vanished: a `notFound` from the sync of a file the stat just found fails the
    /// attempt like any other error, so the promotion stays pending and `index.tmp`, which may hold the newest loaded
    /// generation, is not rewritten by this attempt's step 2; the next attempt's stat decides (close-out cycle 4).
    private static func promote(
        level: SyncLevel,
        layout: StoreLayout,
        fileSystem: any FileSystem,
        outcome: inout IndexCommitOutcome
    ) throws(FileSystemError) {
        let temporary = layout.indexURL(.temporary)
        guard try fileSystem.itemInfo(at: temporary) != nil else {
            outcome.promotedName = true
            return
        }
        try fileSystem.synchronizeFile(at: temporary, level: level)
        try IndexCommitUnit.replaceCurrent(with: .temporary, layout: layout, fileSystem: fileSystem, committedFile: &outcome.committedFile)
        outcome.promotedName = true
        try fileSystem.synchronizeDirectory(at: layout.root, level: level)
        outcome.promotedDurably = true
        outcome.committedFile = .current
    }

    /// Steps 4 and 5: `index.bin → index.prev`, then `source → index.bin`, following the committed generation's file
    /// through both (`committedFile`). Step 4 runs only when `index.bin` exists and either `index.prev` does not or
    /// `index.bin` is the file that holds the committed generation (ADR draft B-28 as amended in close-out cycles 3 and
    /// 5): otherwise `index.bin` is rotten, foreign or an uncommitted attempt, `index.prev` may hold the only valid
    /// generation, and `source` is renamed straight over `index.bin` instead (probe VPC2-D: a rotten `index.bin` moved
    /// over the only valid `index.prev`; cycle 5: the same, through a rotten header that named the committed generation).
    /// When the second rename fails the first is undone (`undoStepFour`): a failed commit never leaves the newest
    /// committed generation only in `index.prev`, where the next commit's ENOSPC fallback or a later
    /// `index.bin → index.prev` would drop it (review round 3, probe 1). A failed undo leaves `index.prev` in place, which
    /// the ENOSPC fallback then keeps.
    private static func replaceCurrent(
        with source: IndexFile,
        layout: StoreLayout,
        fileSystem: any FileSystem,
        committedFile: inout IndexFile?
    ) throws(FileSystemError) {
        let current = layout.indexURL(.current)
        let previous = layout.indexURL(.previous)
        let currentExists = try fileSystem.itemInfo(at: current) != nil
        if !currentExists, committedFile == .current {
            // The committed file is gone (an outside deletion inside the private root): nothing at index.bin holds it.
            committedFile = nil
        }
        let previousExists = currentExists ? try fileSystem.itemInfo(at: previous) != nil : false
        let moved = currentExists && (!previousExists || committedFile == .current)
        if moved {
            do throws(FileSystemError) {
                try fileSystem.rename(from: current, to: previous, mode: .replacing)
            } catch {
                // A rename can take effect and still report a failure (its result lost): when index.bin is gone, step 4
                // happened, so it is undone as after a failed step 5, and a failed commit never leaves index.bin
                // missing (close-out cycle 3, found by the state-space enumeration).
                if IndexCommitUnit.isAbsent(current, fileSystem) {
                    IndexCommitUnit.follow(&committedFile, from: .current, to: .previous)
                    IndexCommitUnit.undoStepFour(layout: layout, fileSystem: fileSystem, committedFile: &committedFile)
                }
                throw error
            }
            IndexCommitUnit.follow(&committedFile, from: .current, to: .previous)
        }
        do throws(FileSystemError) {
            try fileSystem.rename(from: layout.indexURL(source), to: current, mode: .replacing)
        } catch {
            // Whether or not this rename took effect, the committed file is not `source` (it never holds a committed
            // generation) and not index.bin (step 4 moved it, or it was not the committed file).
            if moved {
                IndexCommitUnit.undoStepFour(layout: layout, fileSystem: fileSystem, committedFile: &committedFile)
            }
            throw error
        }
        IndexCommitUnit.follow(&committedFile, from: source, to: .current)
    }

    /// Undoes a step 4 that took effect: `index.prev → index.bin`, exclusive, so nothing that did reach `index.bin` is
    /// overwritten. A rename that reports a failure may still have taken effect: `index.prev` is then gone, and the
    /// committed generation's file is followed all the same.
    private static func undoStepFour(layout: StoreLayout, fileSystem: any FileSystem, committedFile: inout IndexFile?) {
        let previous = layout.indexURL(.previous)
        do throws(FileSystemError) {
            try fileSystem.rename(from: previous, to: layout.indexURL(.current), mode: .exclusive)
        } catch {
            guard IndexCommitUnit.isAbsent(previous, fileSystem) else {
                return
            }
        }
        IndexCommitUnit.follow(&committedFile, from: .previous, to: .current)
    }

    /// Follows the committed generation's file through a rename that took effect: it moves with its file, and a file
    /// renamed over it replaces it.
    private static func follow(_ committedFile: inout IndexFile?, from source: IndexFile, to destination: IndexFile) {
        if committedFile == source {
            committedFile = destination
        } else if committedFile == destination {
            committedFile = nil
        }
    }

    /// Step 2 with the ENOSPC fallback of ADR-015 as amended by ADR draft B-28: `index.tmp` is dropped to make room,
    /// and `index.prev` only when `index.bin` is the file that holds the committed generation (and is still there), so
    /// the newest valid generation is never the one removed; then the write is retried once.
    private static func writeTemporary(_ data: Data, layout: StoreLayout, committedFile: IndexFile?, fileSystem: any FileSystem) throws(FileSystemError) {
        let temporary = layout.indexURL(.temporary)
        do throws(FileSystemError) {
            try fileSystem.write(data, to: temporary, mode: .truncate)
        } catch .noSpace {
            try fileSystem.removeItem(at: temporary)
            if committedFile == .current, IndexCommitUnit.isFile(layout.indexURL(.current), fileSystem) {
                try fileSystem.removeItem(at: layout.indexURL(.previous))
            }
            try fileSystem.write(data, to: temporary, mode: .truncate)
        }
    }

    /// Whether a regular file is at `url`; `false` when the stat fails, so an unknown state never drops `index.prev`.
    private static func isFile(_ url: URL, _ fileSystem: any FileSystem) -> Bool {
        do throws(FileSystemError) {
            return try fileSystem.itemInfo(at: url)?.kind == .file
        } catch {
            return false
        }
    }

    /// Whether nothing is at `url`; `false` when the stat fails, so an unknown state is never taken for absence.
    private static func isAbsent(_ url: URL, _ fileSystem: any FileSystem) -> Bool {
        do throws(FileSystemError) {
            return try fileSystem.itemInfo(at: url) == nil
        } catch {
            return false
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
