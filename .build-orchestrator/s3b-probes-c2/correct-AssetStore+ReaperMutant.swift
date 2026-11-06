import Foundation
import ZTronAssetModel

/// VERIFIER SCRATCH ONLY (cycle 2, correct lens): s3-base's quadratic reaper, with and without honest statistics.
extension AssetStore {
    static var verifierMutant: String {
        ProcessInfo.processInfo.environment["S3MUT"] ?? ""
    }

    func reapS3Base(maxKeys: Int, recordStatistics: Bool) async -> CleanupResult {
        var result = CleanupResult()
        guard self.state.core.phase == .open, maxKeys > 0, let layout = self.state.core.layout else {
            return result
        }
        var queue = self.state.core.blobTable.keys.filter { self.deletionBlocker($0) == .none }.sorted()[...]
        var statistics = ReapStatistics(keys: queue.count)
        var reads = 0
        let batchSize = max(1, self.configuration.deletionBatchSize)
        let fileSystem = self.environment.fileSystem
        let time = self.environment.time
        var budget = maxKeys
        while !queue.isEmpty, budget > 0, self.state.core.phase == .open {
            var batch: [BlobKey] = []
            while let key = queue.first, batch.count < min(batchSize, budget) {
                queue.removeFirst()
                reads += 1
                guard self.deletionBlocker(key) == .none, case .doomed(let info)? = self.state.core.blobTable[key] else {
                    continue
                }
                self.state.core.deletingDooms[key] = info
                self.state.core.blobTable[key] = .deleting
                batch.append(key)
            }
            guard !batch.isEmpty else {
                break
            }
            let keys = batch
            let outcome = await self.runUnit(on: self.environment.metadataExecutor) {
                BlobDeletionUnit.run(fileSystem: fileSystem, layout: layout, keys: keys, time: time, budget: BlobDeletionUnit.budget)
            }
            let uptime = self.environment.time.uptimeNow()
            for (position, key) in batch.enumerated() {
                let info = self.state.core.deletingDooms.removeValue(forKey: key)
                if position >= outcome.attempted {
                    if let info {
                        self.state.core.blobTable[key] = .doomed(info)
                    }
                    queue.insert(key, at: queue.startIndex + (position - outcome.attempted))
                } else if outcome.failures[key] != nil, var doom = info {
                    doom.failedUnlinks += 1
                    doom.eligibleAt = uptime.adding(seconds: AssetStore.unlinkBackoff(afterFailures: doom.failedUnlinks))
                    self.state.core.blobTable[key] = .doomed(doom)
                } else {
                    self.state.core.blobTable[key] = nil
                    self.state.core.countedReleases[key] = nil
                    result.bytesFreed += self.state.core.blobBytes.removeValue(forKey: key) ?? 0
                    result.filesRemoved += 1
                }
                self.resumeKeyWaiters(key)
            }
            statistics.units += 1
            statistics.carried += batch.count - outcome.attempted
            budget -= outcome.attempted
            self.markDirtyInternal(.lazy)
        }
        if recordStatistics, statistics.keys > 0 {
            statistics.reads = reads
            self.state.core.lastReap = statistics
        }
        for key in self.state.core.blobTable.keys where self.deletionBlocker(key) == .lease {
            result.bytesDeferred += self.state.core.blobBytes[key] ?? 0
        }
        return result
    }
}
