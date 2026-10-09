import Foundation
import ZTronAssetModel

/// The blocking units of WP-C's collections (ADR-003): one listing, or a bounded batch of removals.
enum CleanupUnits {
    /// The time a removal batch may take before it yields, on the injected monotonic clock: the reaper's bound
    /// (P-13, ADR draft B-10), so a collection never holds a metadata unit longer than a deletion unit does.
    static let removalBudget: TimeInterval = 0.001

    /// What a removal batch did: the leading items it attempted and the ones that failed.
    struct Removal: Sendable {
        /// The number of leading items attempted.
        var attempted: Int
        /// Indices (into the batch) whose removal failed.
        var failed: Set<Int>
    }

    /// Lists one directory without following links; `[]` for a missing directory.
    static func list(_ url: URL, fileSystem: any FileSystem) -> Result<[FileItemInfo], FileSystemError> {
        do throws(FileSystemError) {
            return .success(try fileSystem.contentsOfDirectory(at: url))
        } catch .notFound {
            return .success([])
        } catch {
            return .failure(error)
        }
    }

    /// Removes `urls` in order: at least one, then each next one only while the time spent plus the slowest removal
    /// seen would stay within `budget` (the last one predicted, as the reaper's unit does). Absent items count as
    /// removed (`removeItem` treats absence as success).
    static func remove(_ urls: [URL], fileSystem: any FileSystem, time: any TimeSource, budget: TimeInterval) -> Removal {
        let start = time.monotonicNow()
        var last = start
        var slowest: TimeInterval = 0
        var removal = Removal(attempted: 0, failed: [])
        for (index, url) in urls.enumerated() {
            if removal.attempted > 0, last.seconds(since: start) + slowest > budget {
                break
            }
            removal.attempted += 1
            do throws(FileSystemError) {
                try fileSystem.removeItem(at: url)
            } catch {
                removal.failed.insert(index)
            }
            let now = time.monotonicNow()
            slowest = max(slowest, now.seconds(since: last))
            last = now
        }
        return removal
    }
}

extension AssetStore {
    /// Removes `items` (URL and size) in metadata units of at most `deletionBatchSize` and `CleanupUnits.removalBudget`,
    /// checking the caller's cancellation and `deadline` between units. `recheck`, when given, filters the indices of
    /// each unit in the very turn that submits it (orphan GC's marks, REENTRANCY R10); an item it drops is skipped, not
    /// removed. A failed removal is reported (not in `removed`) and the next unit goes on. Returns what was removed and
    /// whether the caller's cancellation stopped it: what was removed stays removed (R-CLN-12), so the caller accounts
    /// for it (the cleanup stamp, C-4) before it throws `.cancelled`. Throws `.closed` once closing.
    func removeInUnits(
        _ items: [(url: URL, bytes: Int64)],
        until deadline: MonotonicInstant? = nil,
        recheck: (([Int]) -> [Int])? = nil
    ) async throws(StoreError) -> (removed: [Int], result: CleanupResult, cancelled: Bool) {
        let fileSystem = self.environment.fileSystem
        let time = self.environment.time
        let batchSize = max(1, self.configuration.deletionBatchSize)
        var result = CleanupResult()
        var removed: [Int] = []
        var next = 0
        while next < items.count {
            if Task.isCancelled {
                return (removed, result, true)
            }
            if let deadline, time.monotonicNow() >= deadline {
                break
            }
            let range = Array(next..<min(next + batchSize, items.count))
            let indices = recheck.map { $0(range) } ?? range
            guard !indices.isEmpty else {
                next = range[range.count - 1] + 1
                continue
            }
            let urls = indices.map { items[$0].url }
            // REENTRANCY: c-1 (proposed) — the phase: the files are the collection's own decision (garbage nobody else
            // writes under these names, or orphans the caller's `recheck` kept in this very turn); the next unit starts
            // after the cancellation and deadline checks, and is re-checked again.
            let removal = await self.runUnit(on: self.environment.metadataExecutor) {
                CleanupUnits.remove(urls, fileSystem: fileSystem, time: time, budget: CleanupUnits.removalBudget)
            }
            try self.checkLive()
            for offset in 0..<removal.attempted where !removal.failed.contains(offset) {
                let index = indices[offset]
                removed.append(index)
                result.bytesFreed = result.bytesFreed.addingSaturating(items[index].bytes)
                result.filesRemoved += 1
            }
            // Items the time budget left unattempted come first in the next unit (and are re-checked with it).
            next = indices[max(1, removal.attempted) - 1] + 1
        }
        return (removed, result, false)
    }

    /// `removeInUnits` for a caller with no bookkeeping (legacy phase 4): a cancellation is thrown at once.
    func removeAllInUnits(_ items: [(url: URL, bytes: Int64)]) async throws(StoreError) {
        // REENTRANCY: c-1 (proposed) — see `removeInUnits`.
        if try await self.removeInUnits(items).cancelled {
            throw .cancelled
        }
    }
}
