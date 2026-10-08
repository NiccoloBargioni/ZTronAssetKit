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
    /// The verified file was renamed into place; `createdFanOut` when its `blobs/<aa>/` had to be created.
    case placed(createdFanOut: Bool)
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
            let created = try fileSystem.itemInfo(at: fanOut) == nil
            try fileSystem.createDirectory(at: fanOut)
            if reuseExisting || replaceExisting {
                try fileSystem.rename(from: source, to: destination, mode: .replacing)
                return .success(.placed(createdFanOut: created))
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
            return .success(.placed(createdFanOut: created))
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
/// The unit also stops once `budget` seconds of the injected monotonic clock have passed (after at least one
/// unlink), so a slow volume shortens the batch instead of lengthening the time between suspension points; the keys
/// it did not attempt go to the next unit (ADR draft B-10). On `ManualTimeSource` time never passes inside a unit.
enum BlobDeletionUnit {
    /// What the unit did: the failed unlinks, and how many keys (a prefix of the input) it attempted.
    struct Outcome: Sendable {
        /// Keys whose unlink failed, with the error.
        var failures: [BlobKey: FileSystemError]
        /// The number of leading keys attempted.
        var attempted: Int
    }

    /// The time a deletion unit may take before it yields: P-13's 5 ms batch budget less the overshoot of the last
    /// unlink and the scheduling noise of a busy device.
    static let budget: TimeInterval = 0.003

    /// Removes each key's blob until the budget is spent; absent files count as removed (idempotent sweeps,
    /// R-CLN-12).
    static func run(fileSystem: any FileSystem, layout: StoreLayout, keys: [BlobKey], time: any TimeSource, budget: TimeInterval) -> Outcome {
        let deadline = time.monotonicNow().adding(seconds: budget)
        var outcome = Outcome(failures: [:], attempted: 0)
        for key in keys {
            if outcome.attempted > 0, time.monotonicNow() >= deadline {
                break
            }
            outcome.attempted += 1
            do throws(FileSystemError) {
                try fileSystem.removeItem(at: layout.blobURL(key))
            } catch {
                outcome.failures[key] = error
            }
        }
        return outcome
    }
}
