import Foundation
import ZTronAssetModel

/// Quota eviction over the store's state (R-CLN-4, R-SYN-11; store.md §6.4): the candidates, the maintenance run and
/// `apply`'s re-validation of a plan. Eviction dooms through `setResidency(.absent(.evicted), of:dooming: .unreferenced)`
/// only; the reaper deletes after acknowledgement, grace, commit and leases (ARCHITECTURE §4.4).
extension AssetStore {
    /// Candidates are marked in chunks of this many blobs, yielding the actor in between (C2, REENTRANCY R8).
    static let evictionChunk = 1_000

    /// The evictable blobs of the current state, in eviction order, computed on the actor: only for the synchronous
    /// dry run (`evictionPlan`, a contract signature); the async callers use `evictionCandidatesOffActor()`.
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

    /// The evictable blobs, in eviction order, computed in a bulk unit from a value snapshot of the state (C2: at
    /// `ManifestLimits.maxEntries` the grouping and the sort are far over 10 ms). The result describes the state when
    /// the unit was submitted; callers re-validate every candidate before acting on it (REENTRANCY R8).
    func evictionCandidatesOffActor() async -> [EvictionCandidate] {
        let rules = EvictionOrder.Rules(
            policy: self.configuration.policy,
            scope: self.state.eviction.retentionScope,
            protecting: [],
            now: self.environment.time.now()
        )
        let records = self.state.core.records
        let blobTable = self.state.core.blobTable
        let publishing = self.state.core.publishing
        let leases = self.state.cleanup.leases
        // REENTRANCY: R8 — nothing here: a pure computation over the snapshot; the callers re-validate each candidate.
        return await self.runUnit(on: self.environment.bulkExecutor) {
            EvictionOrder.candidates(records: records, blobTable: blobTable, publishing: publishing, leases: leases, rules: rules)
        }
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
        // REENTRANCY: R8 — the phase and writability below, then per candidate (in `evict`): still present at the same
        // blob, unleased, not accessed since selection, still evictable, against its holders as they are then.
        let candidates = await self.evictionCandidatesOffActor()
        try self.checkLive()
        try self.checkWritable()
        let chunk = max(1, self.state.eviction.chunk)
        var visited = 0
        var evictedAny = false
        for candidate in candidates where result.bytesFreed < needed {
            if visited > 0, visited % chunk == 0 {
                // The actor is released between chunks by a no-op metadata unit (C2): every other caller runs
                // meanwhile, and a test can hold eviction at this very point.
                // REENTRANCY: R8 — the phase, then per candidate (in `evict`): still present at the same blob, unleased,
                // not accessed since selection, still evictable; its holders are read again.
                await self.runUnit(on: self.environment.metadataExecutor) {}
                try self.checkLive()
                try self.checkWritable()
            }
            visited += 1
            switch self.evict(candidate.victims) {
            case .doomed(let bytes)?:
                result.bytesFreed = result.bytesFreed.addingSaturating(bytes)
                result.filesRemoved += 1
                evictedAny = true
            case .stillReferenced?:
                // The records changed, but nothing was released to the reaper (C-3).
                evictedAny = true
            case nil:
                break
            }
        }
        guard evictedAny else {
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
        var evicted: Set<AssetID> = []
        for key in order {
            if self.evict(groups[key] ?? []) != nil {
                evicted.formUnion(groups[key]?.map(\.id) ?? [])
            }
        }
        if !evicted.isEmpty {
            self.stampCleanup()
        }
        return plan.victims.map(\.id).filter { evicted.contains($0) }
    }

    /// The present records referencing `key` now: `known` (the ids a snapshot saw referencing it) re-read, in
    /// O(`known`), when they account for every reference the blob table counts for it (each present record holds one,
    /// ADR-018); otherwise, when a publication of the same bytes holds a provisional reference or a record was bound
    /// after the snapshot, one scan of the records. Replaces the full reference index each chunk, quarantine and slice
    /// rebuilt on the actor (C2, review round 3: 2.6 ms at 10,000 records, 45 ms at `maxEntries`).
    func holders(of key: BlobKey, known: [AssetID]) -> [AssetID] {
        guard case .live(let references)? = self.state.core.blobTable[key] else {
            return []
        }
        let still = IntegrityBookkeeping.unique(known).filter { self.state.core.records[$0]?.referencedBlob == key }
        if still.count == references {
            return still
        }
        return self.state.core.records.compactMap { $0.value.referencedBlob == key ? $0.key : nil }
    }

    /// What evicting one blob's records did.
    enum BlobEviction: Sendable, Hashable {
        /// The records were evicted and the blob is doomed: `bytes` go to the reaper.
        case doomed(bytes: Int64)
        /// The records were evicted, but another reference keeps the blob live (an in-flight publication of the same
        /// bytes under another id holds a provisional one, `acquireReference`'s `.reused`): nothing was freed.
        case stillReferenced
    }

    /// Evicts one blob's records when the blob is still live, unleased and not being placed, its present records
    /// (`holders(of:known:)`, read now) are exactly `victims`, and each of them is still evictable and was not accessed
    /// since the selection. Returns what happened to the blob, or `nil` when nothing was evicted.
    func evict(_ victims: [EvictionVictim]) -> BlobEviction? {
        guard let key = victims.first?.blob, case .live? = self.state.core.blobTable[key], !self.state.core.publishing.contains(key),
            self.state.cleanup.leases[key]?.isEmpty ?? true
        else {
            return nil
        }
        let holders = self.holders(of: key, known: victims.map(\.id))
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
            return .stillReferenced
        }
        self.state.core.metrics.evictedBytes = self.state.core.metrics.evictedBytes.addingSaturating(bytes)
        return .doomed(bytes: bytes)
    }

    /// Stamps `lastCleanupAt` for a GC, eviction or purge that changed something (persisted with the next commit).
    func stampCleanup() {
        self.state.cleanup.lastCleanupAt = self.environment.time.now()
        self.markDirty(.lazy)
    }
}
