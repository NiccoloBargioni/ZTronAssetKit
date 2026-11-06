import sys, re
src = sys.argv[1]
def edit(path, old, new, count=1):
    p = src + '/' + path
    s = open(p).read()
    n = s.count(old)
    assert n == count, (path, old[:60], n)
    s = s.replace(old, new)
    open(p, 'w').write(s)

ENV = 'ProcessInfo.processInfo.environment["S3MUT"]'
A = 'Sources/ZTronAssetStorage/Store/AssetStore+Apply.swift'
R = 'Sources/ZTronAssetStorage/Store/AssetStore+References.swift'
P = 'Sources/ZTronAssetStorage/Store/AssetStore+Reaper.swift'

# DETACH: the detached record's replacement releases directly (cycle-1 code).
edit(A, '''                    if let blob = previous.referencedBlob {
                        self.releaseCountingBytes(blob)
                    }''', '''                    if let blob = previous.referencedBlob {
                        if %s == "DETACH" { self.releaseReference(blob, dooming: .unreferenced) } else {
                        self.releaseCountingBytes(blob)
                        }
                    }''' % ENV)
# OI14B: adoptKnownBlob's previous blob released directly.
edit(A, '''        if let previous, previous != key {
            self.releaseCountingBytes(previous)
        }''', '''        if let previous, previous != key {
            if %s == "OI14B" { self.releaseReference(previous, dooming: .unreferenced) } else {
            self.releaseCountingBytes(previous)
            }
        }''' % ENV)
# NOTAKE: fb99142's semantics (count at the doom, never taken back); the map stays consistent.
edit(R, '''        guard let bytes = self.state.core.countedReleases.removeValue(forKey: key) else {
            return nil
        }
        self.state.eviction.releasedBytes -= bytes''', '''        guard let bytes = self.state.core.countedReleases.removeValue(forKey: key) else {
            return nil
        }
        if %s == "NOTAKE" { return nil }
        self.state.eviction.releasedBytes -= bytes''' % ENV)
# REAP / REAPSTAT: s3-base's reap(maxKeys:) (ArraySlice + insert), with the current countedReleases cleanup;
# REAPSTAT also records statistics the way the fix does.
edit(P, '''    func reap(maxKeys: Int) async -> CleanupResult {
        var result = CleanupResult()''', '''    func reap(maxKeys: Int) async -> CleanupResult {
        if let m = %s, m == "REAP" || m == "REAPSTAT" {
            return await self.reapOld(maxKeys: maxKeys, statistics: m == "REAPSTAT")
        }
        var result = CleanupResult()''' % ENV)
old = open(src + '/' + P).read()
old += '''
extension AssetStore {
    func reapOld(maxKeys: Int, statistics recording: Bool) async -> CleanupResult {
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
        if recording, statistics.keys > 0 {
            statistics.reads = reads
            self.state.core.lastReap = statistics
        }
        for key in self.state.core.blobTable.keys where self.deletionBlocker(key) == .lease {
            result.bytesDeferred += self.state.core.blobBytes[key] ?? 0
        }
        return result
    }
}
'''
open(src + '/' + P, 'w').write(old)
print("mutants applied")
