import Foundation
import ZTronAssetModel

/// Quota eviction over the store's state (R-CLN-4, R-SYN-11; store.md §6.4): the candidates, the maintenance run and
/// `apply`'s re-validation of a plan. Eviction dooms through `setResidency(.absent(.evicted), of:dooming: .unreferenced)`
/// only; the reaper deletes after acknowledgement, grace, commit and leases (ARCHITECTURE §4.4).
extension AssetStore {
    /// Candidates are marked in chunks of this many blobs, yielding the actor in between (C2, REENTRANCY R8).
    static let evictionChunk = 1_000

    /// The evictable blobs of the current state, in eviction order.
    func evictionCandidates(protecting: Set<AssetID>) -> [EvictionCandidate] {
        let rules = EvictionOrder.Rules(
            policy: self.configuration.policy,
            scope: self.state.eviction.retentionScope,
            protecting: protecting,
            now: self.environment.time.now()
        )
        return EvictionOrder.candidates(
            records: self.state.core.records,
            blobTable: self.state.core.blobTable,
            publishing: self.state.core.publishing,
            leases: self.state.cleanup.leases,
            rules: rules
        )
    }

    /// `evictIfNeeded()`: measures, evicts down to the hysteresis target in chunks, publishes the snapshot without the
    /// victims and commits.
    func performEvictIfNeeded() async throws(StoreError) -> CleanupResult {
        // REENTRANCY: R1 — nothing was read before it; `awaitOpen` re-reads the phase itself.
        try await self.awaitOpen()
        try self.checkWritable()
        let interval = self.environment.log.interval(.eviction, category: .store)
        defer {
            interval.end()
        }
        // REENTRANCY: R13 — the figures are a snapshot taken at the unit; the candidates are computed afterwards from
        // the state as it is then, and every one is re-validated before it is marked.
        let space = try await self.freeSpace()
        try self.checkWritable()
        let needed = EvictionOrder.bytesToFree(
            usedBytes: space.usedBytes,
            availableBytes: space.volumeImportant,
            pendingReclaim: space.pendingReclaim,
            policy: self.configuration.policy
        )
        var result = CleanupResult()
        guard needed > 0 else {
            return result
        }
        let candidates = self.evictionCandidates(protecting: [])
        var holders = self.referenceIndex()
        var visited = 0
        for candidate in candidates where result.bytesFreed < needed {
            if visited > 0, visited % AssetStore.evictionChunk == 0 {
                // REENTRANCY: R8 — the phase, then per candidate (in `evict`): still present at the same blob, unleased,
                // not accessed since selection, still evictable.
                await Task.yield()
                try self.checkLive()
                try self.checkWritable()
                holders = self.referenceIndex()
            }
            visited += 1
            if let freed = self.evict(candidate.victims, holders: holders[candidate.key] ?? []) {
                result.bytesFreed = result.bytesFreed.addingSaturating(freed)
                result.filesRemoved += 1
            }
        }
        guard result.filesRemoved > 0 else {
            self.environment.log.log(.store, .info, "quota eviction found nothing evictable: \(needed) bytes over target remain")
            return result
        }
        self.stampCleanup()
        if result.bytesFreed < needed {
            self.environment.log.log(.store, .info, "quota eviction shortfall: \(needed - result.bytesFreed) bytes are protected")
        }
        // REENTRANCY: R17 — nothing but the phase: the evictions were made synchronously above; the result describes
        // them.
        await self.publishSnapshot(urgency: .userInitiated)
        // REENTRANCY: R17 — as above; a failed commit leaves the evictions dirty (R5) and throws.
        try await self.requireCommitted(.ordered)
        return result
    }

    /// `applyEviction(_:)`, run synchronously inside `apply`'s write fence: evicts each blob of the plan whose records are
    /// all still evictable exactly as planned (REENTRANCY R8's re-validation), and returns the evicted ids in plan order.
    func performApplyEviction(_ plan: EvictionPlan) -> [AssetID] {
        var order: [BlobKey] = []
        var groups: [BlobKey: [EvictionVictim]] = [:]
        for victim in plan.victims {
            if groups[victim.blob] == nil {
                order.append(victim.blob)
            }
            groups[victim.blob, default: []].append(victim)
        }
        let holders = self.referenceIndex()
        var evicted: Set<AssetID> = []
        for key in order {
            if self.evict(groups[key] ?? [], holders: holders[key] ?? []) != nil {
                evicted.formUnion(groups[key]?.map(\.id) ?? [])
            }
        }
        if !evicted.isEmpty {
            self.stampCleanup()
        }
        return plan.victims.map(\.id).filter { evicted.contains($0) }
    }

    /// The ids of the present records referencing each blob (one pass over the records).
    func referenceIndex() -> [BlobKey: [AssetID]] {
        var index: [BlobKey: [AssetID]] = [:]
        for (id, record) in self.state.core.records {
            if let key = record.referencedBlob {
                index[key, default: []].append(id)
            }
        }
        return index
    }

    /// Evicts one blob's records when the blob is still live, unleased and not being placed, its present records
    /// (`holders`, from a `referenceIndex()` of the current state) are exactly `victims`, and each of them is still
    /// evictable and was not accessed since the selection. Returns the bytes released to the reaper (0 when the blob
    /// stays referenced), or `nil` when nothing was evicted.
    func evict(_ victims: [EvictionVictim], holders: [AssetID]) -> Int64? {
        guard let key = victims.first?.blob, case .live? = self.state.core.blobTable[key], !self.state.core.publishing.contains(key),
            self.state.cleanup.leases[key]?.isEmpty ?? true
        else {
            return nil
        }
        let rules = EvictionOrder.Rules(
            policy: self.configuration.policy,
            scope: self.state.eviction.retentionScope,
            protecting: [],
            now: self.environment.time.now()
        )
        let planned = Dictionary(victims.map { ($0.id, $0.lastAccess) }, uniquingKeysWith: { first, _ in first })
        guard holders.count == planned.count,
            holders.allSatisfy({ id in
                guard let lastAccess = planned[id], let record = self.state.core.records[id], record.referencedBlob == key else {
                    return false
                }
                return rules.allows(record) && record.lastAccess <= lastAccess
            })
        else {
            return nil
        }
        let bytes = holders.first.flatMap { self.state.core.records[$0] }.map(EvictionOrder.recordedSize) ?? 0
        for victim in victims {
            self.setResidency(.absent(.evicted), of: victim.id, dooming: .unreferenced)
        }
        self.state.core.metrics.evictions += victims.count
        guard case .doomed? = self.state.core.blobTable[key] else {
            return 0
        }
        self.state.core.metrics.evictedBytes = self.state.core.metrics.evictedBytes.addingSaturating(bytes)
        return bytes
    }

    /// Stamps `lastCleanupAt` for a GC, eviction or purge that changed something (persisted with the next commit).
    func stampCleanup() {
        self.state.cleanup.lastCleanupAt = self.environment.time.now()
        self.markDirty(.lazy)
    }
}
