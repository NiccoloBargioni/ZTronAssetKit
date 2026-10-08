import CryptoKit
import Foundation
import ZTronAssetModel

/// One unit of the streaming SHA-256 (R-INT-1, store.md §5.1): one bounded read plus one hash update.
///
/// The running `SHA256` value is `Sendable` and travels between units, so no buffer, pointer or shared flag is
/// needed; cancellation is checked by the caller between units.
enum StreamingHashUnit {
    /// Reads at most `chunk` bytes at `offset` and returns the updated hasher and the number of bytes read.
    static func run(
        fileSystem: any FileSystem,
        url: URL,
        offset: Int64,
        chunk: Int,
        hasher: SHA256
    ) -> Result<(hasher: SHA256, count: Int), FileSystemError> {
        do throws(FileSystemError) {
            let data = try fileSystem.read(from: url, offset: offset, maxLength: chunk)
            var next = hasher
            next.update(data: data)
            return .success((next, data.count))
        } catch {
            return .failure(error)
        }
    }
}

/// How a verified file reached its blob name (ARCHITECTURE §4.3 step 8).
enum BlobPlacementOutcome: Sendable, Hashable {
    /// A complete file of the right size already had the name: the verified file was removed (dedupe).
    case keptExisting
    /// The verified file was renamed into place.
    case placed
}

/// What one placement unit did: its outcome, and whether it created `blobs/<aa>/`. The creation is reported on
/// failure too: the fan-out is created before the rename, so a rename that fails afterwards leaves a fan-out whose
/// entry in `blobs/` must still be barrier-synced before any commit references a blob in it (ARCHITECTURE §3, §4.1
/// step 1; review round 3, probe 4). A later placement into it finds it already there and cannot tell.
struct BlobPlacementResult: Sendable {
    /// The placement's outcome.
    var outcome: Result<BlobPlacementOutcome, FileSystemError>
    /// The unit found no fan-out and went on to create it (conservatively `true` when `createDirectory` itself failed
    /// after the check: it may have created the directory before failing).
    var createdFanOut: Bool
}

/// The placement unit: removes the transfer's sidecar, barrier-syncs the verified file, creates the fan-out and
/// renames the file into `blobs/<aa>/<hex>.<ext>` (R-STO-3: nothing reaches its final path before size check, hash
/// and barrier). One metadata unit, so a crash leaves either the staged file or the blob, never a partial blob.
enum BlobPlacementUnit {
    /// Places `source` under `key`.
    ///
    /// - `reuseExisting`: a live or rescued key whose file should already be there; a complete file of
    ///   `byteCount` bytes is kept and `source` removed (dedupe), a missing or wrong-sized one is replaced.
    /// - `replaceExisting`: a `purged` or `corrupt` name, replaced by the verified bytes (ADR-018).
    /// - otherwise an exclusive rename; EEXIST compares sizes (store-1 S1-06): the same size keeps the existing
    ///   file, another size is a torn or foreign file and is replaced.
    static func run(
        fileSystem: any FileSystem,
        layout: StoreLayout,
        source: URL,
        sidecar: URL?,
        key: BlobKey,
        byteCount: Int64,
        reuseExisting: Bool,
        replaceExisting: Bool
    ) -> BlobPlacementResult {
        var createdFanOut = false
        let outcome = BlobPlacementUnit.place(
            fileSystem: fileSystem,
            layout: layout,
            source: source,
            sidecar: sidecar,
            key: key,
            byteCount: byteCount,
            reuseExisting: reuseExisting,
            replaceExisting: replaceExisting,
            createdFanOut: &createdFanOut
        )
        return BlobPlacementResult(outcome: outcome, createdFanOut: createdFanOut)
    }

    /// The steps of `run`; `createdFanOut` is set before `createDirectory` runs, so it survives any later failure.
    private static func place(
        fileSystem: any FileSystem,
        layout: StoreLayout,
        source: URL,
        sidecar: URL?,
        key: BlobKey,
        byteCount: Int64,
        reuseExisting: Bool,
        replaceExisting: Bool,
        createdFanOut: inout Bool
    ) -> Result<BlobPlacementOutcome, FileSystemError> {
        let destination = layout.blobURL(key)
        do throws(FileSystemError) {
            if let sidecar {
                try fileSystem.removeItem(at: sidecar)
            }
            if reuseExisting, BlobPlacementUnit.holds(try fileSystem.itemInfo(at: destination), byteCount) {
                try fileSystem.removeItem(at: source)
                return .success(.keptExisting)
            }
            try fileSystem.synchronizeFile(at: source, level: .barrier)
            let fanOut = layout.fanOutDirectory(for: key.hash)
            createdFanOut = try fileSystem.itemInfo(at: fanOut) == nil
            try fileSystem.createDirectory(at: fanOut)
            if reuseExisting || replaceExisting {
                try fileSystem.rename(from: source, to: destination, mode: .replacing)
                return .success(.placed)
            }
            do throws(FileSystemError) {
                try fileSystem.rename(from: source, to: destination, mode: .exclusive)
            } catch .alreadyExists {
                if BlobPlacementUnit.holds(try fileSystem.itemInfo(at: destination), byteCount) {
                    try fileSystem.removeItem(at: source)
                    return .success(.keptExisting)
                }
                try fileSystem.rename(from: source, to: destination, mode: .replacing)
            }
            return .success(.placed)
        } catch {
            return .failure(error)
        }
    }

    /// Whether `info` is a regular file of exactly `byteCount` bytes.
    private static func holds(_ info: FileItemInfo?, _ byteCount: Int64) -> Bool {
        guard let info else {
            return false
        }
        return info.kind == .file && info.byteSize == byteCount
    }
}

/// One deletion unit of the reaper (P-13): up to `deletionBatchSize` unlinks in sorted order, each result kept, so
/// a failure keeps only its own key doomed (ARCHITECTURE §4.4).
///
/// The unit is also bounded by time on the injected monotonic clock (ADR draft B-10, tightened in review round 2):
/// before each unlink after the first it stops when the time spent so far **plus the slowest unlink it has seen**
/// would pass `budget`, so the last unlink is predicted instead of overshooting; the keys it did not attempt go to
/// the next unit. A slow volume therefore shortens the batch instead of lengthening the time between suspension
/// points. On `ManualTimeSource` time never passes inside a unit, so deterministic tests see count-bounded units.
enum BlobDeletionUnit {
    /// What the unit did: the failed unlinks, and how many keys (a prefix of the input) it attempted.
    struct Outcome: Sendable {
        /// Keys whose unlink failed, with the error.
        var failures: [BlobKey: FileSystemError]
        /// The number of leading keys attempted.
        var attempted: Int
    }

    /// The time a deletion unit may take before it yields. P-13 allows 5 ms between suspension points; 3 ms left
    /// about 2 ms for preemption and a slow last unlink, and a loaded machine used it up (unit p95 5.26–5.27 ms in
    /// review round 2), so 3 ms of margin are kept.
    static let budget: TimeInterval = 0.002

    /// Removes each key's blob until the budget would be spent; absent files count as removed (idempotent sweeps,
    /// R-CLN-12).
    static func run(fileSystem: any FileSystem, layout: StoreLayout, keys: [BlobKey], time: any TimeSource, budget: TimeInterval) -> Outcome {
        let start = time.monotonicNow()
        var last = start
        var slowest: TimeInterval = 0
        var outcome = Outcome(failures: [:], attempted: 0)
        for key in keys {
            if outcome.attempted > 0, last.seconds(since: start) + slowest > budget {
                break
            }
            outcome.attempted += 1
            do throws(FileSystemError) {
                try fileSystem.removeItem(at: layout.blobURL(key))
            } catch {
                outcome.failures[key] = error
            }
            let now = time.monotonicNow()
            slowest = max(slowest, now.seconds(since: last))
            last = now
        }
        return outcome
    }
}
