import Foundation
import ZTronAssetModel

/// One blob that eviction could free: every present record that references it, evicted together, because evicting
/// only some of them frees nothing (store.md §6.4).
struct EvictionCandidate: Sendable, Hashable {
    /// The blob.
    let key: BlobKey
    /// Its size on disk.
    let bytes: Int64
    /// The most recent access over its records (the LRU key).
    let lastAccess: Date
    /// Every record referencing it is outside the retention scope (ADR-027): such blobs go first.
    let outsideScope: Bool
    /// One victim per record, in identifier order.
    let victims: [EvictionVictim]
}

/// The eviction order and the space arithmetic of quota eviction (R-CLN-4, R-CLN-5, R-SYN-11, store.md §6.4). Pure
/// functions over values, so the dry run, the maintenance run and `apply`'s re-validation agree by construction.
enum EvictionOrder {
    /// What makes a record evictable now, besides its blob being live, unleased and not being placed.
    struct Rules: Sendable {
        /// The retention scope (`state.eviction.retentionScope`).
        var scope: AssetScope
        /// Ids the caller protects (the dry run's `protecting`).
        var protecting: Set<AssetID>
        /// The wall clock now.
        var now: Date
        /// `max(minimumResidency, deletionGrace)`: anything accessed more recently stays (R-CLN-4, R-CLN-5).
        var residency: TimeInterval

        /// The rules of `policy` at `now`.
        init(policy: StoragePolicy, scope: AssetScope, protecting: Set<AssetID>, now: Date) {
            self.scope = scope
            self.protecting = protecting
            self.now = now
            let residency = max(policy.minimumResidency, policy.deletionGrace)
            self.residency = residency.isFinite ? residency : .greatestFiniteMagnitude
        }

        /// Whether `record` may be evicted now: never essential, pinned or protected, and not accessed within the
        /// residency window (an access stamped in the future counts as recent).
        func allows(_ record: AssetRecord) -> Bool {
            guard record.entry.policy != .essential, !record.pinned, !self.protecting.contains(record.entry.identifier) else {
                return false
            }
            return self.now.timeIntervalSince(record.lastAccess) >= self.residency
        }
    }

    /// Every evictable blob, in eviction order: outside the retention scope first, then least recently used, larger
    /// first on ties, then by key (a total order, so equal inputs give equal plans, R-SYN-1). Apple-adopted assets
    /// cannot be told apart in the store (records carry no tier), so ADR-027's "after ordinary ones" is not applied
    /// here (ADR draft C-6).
    static func candidates(
        records: [AssetID: AssetRecord],
        blobTable: [BlobKey: BlobState],
        publishing: Set<BlobKey>,
        leases: [BlobKey: [UInt64: AssetID]],
        rules: Rules
    ) -> [EvictionCandidate] {
        var byKey: [BlobKey: [AssetRecord]] = [:]
        for record in records.values {
            if let key = record.referencedBlob {
                byKey[key, default: []].append(record)
            }
        }
        var candidates: [EvictionCandidate] = []
        candidates.reserveCapacity(byKey.count)
        for (key, holders) in byKey {
            guard case .live? = blobTable[key], !publishing.contains(key), leases[key]?.isEmpty ?? true,
                holders.allSatisfy(rules.allows)
            else {
                continue
            }
            let sorted = holders.sorted { $0.entry.identifier.rawValue < $1.entry.identifier.rawValue }
            let bytes = EvictionOrder.recordedSize(sorted[0])
            let victims = sorted.map { EvictionVictim(id: $0.entry.identifier, blob: key, byteSize: bytes, lastAccess: $0.lastAccess) }
            candidates.append(
                EvictionCandidate(
                    key: key,
                    bytes: bytes,
                    lastAccess: sorted.map(\.lastAccess).max() ?? rules.now,
                    outsideScope: sorted.allSatisfy { !rules.scope.contains($0.entry) },
                    victims: victims
                )
            )
        }
        return candidates.sorted(by: EvictionOrder.precedes)
    }

    /// The eviction order (see `candidates`).
    static func precedes(_ lhs: EvictionCandidate, _ rhs: EvictionCandidate) -> Bool {
        if lhs.outsideScope != rhs.outsideScope {
            return lhs.outsideScope
        }
        if lhs.lastAccess != rhs.lastAccess {
            return lhs.lastAccess < rhs.lastAccess
        }
        if lhs.bytes != rhs.bytes {
            return lhs.bytes > rhs.bytes
        }
        return lhs.key < rhs.key
    }

    /// The shortest prefix of `candidates` that frees at least `bytes`, as a plan; an empty plan for `bytes <= 0`, `nil`
    /// when even every candidate is not enough. `EvictionPlan.bytes` counts each blob once; every victim carries its
    /// blob's size.
    static func plan(_ candidates: [EvictionCandidate], toFree bytes: Int64) -> EvictionPlan? {
        var victims: [EvictionVictim] = []
        var freed: Int64 = 0
        for candidate in candidates where freed < bytes {
            victims.append(contentsOf: candidate.victims)
            freed = freed.addingSaturating(candidate.bytes)
        }
        guard freed >= bytes else {
            return nil
        }
        return EvictionPlan(victims: victims, bytes: freed)
    }

    /// How many bytes quota eviction must free (store.md §6.4, store-2 S2-06): the budget is resolved over usage plus
    /// free space **plus the pending reclaim** (doomed bytes the reaper frees after grace), eviction triggers when usage
    /// passes the budget or free space plus pending reclaim falls short of the reserve, and it then evicts down to
    /// `min(hysteresis × budget, used − reserve shortfall)`. Zero when nothing is due.
    static func bytesToFree(usedBytes used: Int64, availableBytes available: Int64, pendingReclaim pending: Int64, policy: StoragePolicy) -> Int64 {
        let used = max(0, used)
        let effective = max(0, available).addingSaturating(max(0, pending))
        let budget = policy.budget.resolve(usedBytes: used, availableBytes: effective)
        let shortfall = max(0, max(0, policy.reserveFreeBytes) - effective)
        guard used > budget || shortfall > 0 else {
            return 0
        }
        let hysteresis = policy.hysteresisTarget.isNaN ? 1 : min(max(policy.hysteresisTarget, 0), 1)
        let scaled = Double(budget) * hysteresis
        let hysteresisBudget = scaled >= Double(Int64.max) ? Int64.max : Int64(scaled)
        let target = max(0, min(hysteresisBudget, used - min(used, shortfall)))
        return used - target
    }

    /// A present record's recorded size: the size of the blob it references (every record of one blob records the
    /// blob's size, I-2); 0 for a record without a blob.
    static func recordedSize(_ record: AssetRecord) -> Int64 {
        if case .present(_, let byteSize, _) = record.residency {
            return byteSize
        }
        return 0
    }
}

extension Int64 {
    /// `self + other`, saturating at the bounds instead of trapping.
    func addingSaturating(_ other: Int64) -> Int64 {
        let (sum, overflow) = self.addingReportingOverflow(other)
        guard overflow else {
            return sum
        }
        return other > 0 ? .max : .min
    }
}
