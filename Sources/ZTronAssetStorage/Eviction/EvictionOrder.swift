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
            self.allows(policy: record.entry.policy, pinned: record.pinned, lastAccess: record.lastAccess, id: record.entry.identifier)
        }

        /// `allows(_:)` over the fields it reads, so a caller can read them in place instead of copying a record whole;
        /// `id` is read only when the rules protect ids.
        func allows(policy: AssetPolicy, pinned: Bool, lastAccess: Date, id: @autoclosure () -> AssetID) -> Bool {
            guard policy != .essential, !pinned, self.protecting.isEmpty || !self.protecting.contains(id()) else {
                return false
            }
            return self.now.timeIntervalSince(lastAccess) >= self.residency
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
        let ranking = Ranking(records: records, blobTable: blobTable, publishing: publishing, leases: leases, rules: rules)
        return ranking.order.map(ranking.candidate)
    }

    /// The shortest prefix of the eviction order (`candidates`) that frees at least `bytes`, as a plan; an empty plan for
    /// `bytes <= 0`, `nil` when even every candidate is not enough. `EvictionPlan.bytes` counts each blob once; every
    /// victim carries its blob's size. The synchronous dry run's computation (C2, ADR draft C-22, cycle 6): one pass over
    /// the records and a sort of plain values, and victims built for the prefix only.
    static func plan(
        records: [AssetID: AssetRecord],
        blobTable: [BlobKey: BlobState],
        publishing: Set<BlobKey>,
        leases: [BlobKey: [UInt64: AssetID]],
        rules: Rules,
        toFree bytes: Int64
    ) -> EvictionPlan? {
        guard bytes > 0 else {
            return EvictionPlan(victims: [], bytes: 0)
        }
        let ranking = Ranking(records: records, blobTable: blobTable, publishing: publishing, leases: leases, rules: rules)
        var victims: [EvictionVictim] = []
        var freed: Int64 = 0
        for ranked in ranking.order {
            guard freed < bytes else {
                break
            }
            ranking.appendVictims(of: ranked, to: &victims)
            freed = freed.addingSaturating(ranked.bytes)
        }
        guard freed >= bytes else {
            return nil
        }
        return EvictionPlan(victims: victims, bytes: freed)
    }

    /// The evictable blobs of a state, ranked in eviction order (`candidates`), from one pass over the records.
    ///
    /// C2 (review of the L3 close-out cycle 5: the dry run held the actor 14.2–15.3 ms at 10,000 assets): each record is
    /// read in place by index (iterating the values copied every record whole), a blob held by one record keeps that
    /// record's id and access in its tally (no array per blob; only a blob several records share lists them), and the
    /// sort moves plain values, reading a key only when every other field ties.
    struct Ranking: Sendable {
        /// One holder of a blob.
        struct Holder: Sendable {
            /// The record's id.
            let id: AssetID
            /// Its last access.
            let lastAccess: Date
            /// The size it records for the blob.
            let bytes: Int64
        }

        /// What the pass learnt about one blob.
        struct Tally: Sendable {
            /// The blob.
            let key: BlobKey
            /// The first holder the pass met: the only one of a blob no other record shares.
            let first: Holder
            /// The most recent access over its holders so far, as `Date.timeIntervalSinceReferenceDate`.
            var lastAccess: TimeInterval
            /// How many present records reference it.
            var holders: Int
            /// Every holder so far may be evicted now (`Rules.allows`).
            var evictable: Bool
            /// Every holder so far is outside the retention scope.
            var outsideScope: Bool
        }

        /// One evictable blob's place in the order: plain values, so the sort moves no reference and compares no `Date`
        /// (Foundation's comparison operators are calls, not inlined: comparing `Date`s made the sort of 10,000 blobs 5.5 ms
        /// instead of 1.0, review of the L3 close-out cycle 5).
        struct Ranked: Sendable {
            /// Every holder is outside the retention scope.
            let outsideScope: Bool
            /// The most recent access over its holders, as `Date.timeIntervalSinceReferenceDate`.
            let lastAccess: TimeInterval
            /// Its size (the size its first holder by id records).
            let bytes: Int64
            /// The first word of its hash: the key's order on almost every tie (`BlobKey` orders by hash first).
            let prefix: UInt64
            /// Its tally in `tallies`.
            let slot: Int
        }

        /// One tally per blob a present record references, in the order the pass met them.
        private(set) var tallies: [Tally] = []
        /// Every holder of each blob more than one record references, while each of them is evictable.
        private var shared: [BlobKey: [Holder]] = [:]
        /// The evictable blobs, in eviction order.
        private(set) var order: [Ranked] = []

        /// Ranks the blobs of `records` that are live in `blobTable`, not in `publishing`, unleased, and whose present
        /// records `rules` all allow.
        init(
            records: [AssetID: AssetRecord],
            blobTable: [BlobKey: BlobState],
            publishing: Set<BlobKey>,
            leases: [BlobKey: [UInt64: AssetID]],
            rules: Rules
        ) {
            var slots: [BlobKey: Int] = [:]
            slots.reserveCapacity(records.count)
            self.tallies.reserveCapacity(records.count)
            let everyEntryInScope: Bool
            if case .all = rules.scope {
                everyEntryInScope = true
            } else {
                everyEntryInScope = false
            }
            var index = records.startIndex
            while index != records.endIndex {
                let current = index
                records.formIndex(after: &index)
                // Field by field, in place: passing the record on would copy it whole (every string and array of its
                // entry retained), which was most of the dry run's time.
                guard case .present(let key, let bytes, _) = records.values[current].residency else {
                    continue
                }
                let lastAccess = records.values[current].lastAccess
                let allowed = rules.allows(
                    policy: records.values[current].entry.policy,
                    pinned: records.values[current].pinned,
                    lastAccess: lastAccess,
                    id: records.values[current].entry.identifier
                )
                let tally = Ranking.claim(&slots[key, default: -1], next: self.tallies.count)
                if tally.isNew || (allowed && self.tallies[tally.slot].evictable) {
                    let outside = allowed && !everyEntryInScope && !rules.scope.contains(records.values[current].entry)
                    let holder = Holder(id: records.values[current].entry.identifier, lastAccess: lastAccess, bytes: bytes)
                    self.count(holder, of: key, at: tally, allowed: allowed, outside: outside)
                } else {
                    self.count(of: key, at: tally.slot, allowed: allowed)
                }
            }
            var order: [Ranked] = []
            order.reserveCapacity(self.tallies.count)
            for slot in self.tallies.indices where self.tallies[slot].evictable {
                let key = self.tallies[slot].key
                guard case .live? = blobTable[key], publishing.isEmpty || !publishing.contains(key), leases.isEmpty || leases[key]?.isEmpty ?? true else {
                    continue
                }
                order.append(
                    Ranked(
                        outsideScope: self.tallies[slot].outsideScope,
                        lastAccess: self.tallies[slot].lastAccess,
                        bytes: self.size(of: slot),
                        prefix: key.hash.w0,
                        slot: slot
                    )
                )
            }
            let tallies = self.tallies
            order.sort { lhs, rhs in
                if lhs.outsideScope != rhs.outsideScope {
                    return lhs.outsideScope
                }
                if lhs.lastAccess != rhs.lastAccess {
                    return lhs.lastAccess < rhs.lastAccess
                }
                if lhs.bytes != rhs.bytes {
                    return lhs.bytes > rhs.bytes
                }
                if lhs.prefix != rhs.prefix {
                    return lhs.prefix < rhs.prefix
                }
                return tallies[lhs.slot].key < tallies[rhs.slot].key
            }
            self.order = order
        }

        /// Counts a holder into its blob's tally: the first holder of a blob, or another one while every holder so far is
        /// evictable and so is this one (`allowed`).
        private mutating func count(_ holder: Holder, of key: BlobKey, at tally: (slot: Int, isNew: Bool), allowed: Bool, outside: Bool) {
            guard !tally.isNew else {
                self.tallies.append(
                    Tally(
                        key: key,
                        first: holder,
                        lastAccess: holder.lastAccess.timeIntervalSinceReferenceDate,
                        holders: 1,
                        evictable: allowed,
                        outsideScope: outside
                    )
                )
                return
            }
            let slot = tally.slot
            self.tallies[slot].holders += 1
            self.tallies[slot].lastAccess = max(self.tallies[slot].lastAccess, holder.lastAccess.timeIntervalSinceReferenceDate)
            if !outside {
                self.tallies[slot].outsideScope = false
            }
            if self.tallies[slot].holders == 2 {
                self.shared[key] = [self.tallies[slot].first, holder]
            } else {
                self.shared[key, default: []].append(holder)
            }
        }

        /// Counts a further holder of a blob that is, or now becomes, no candidate: its holders are not needed.
        private mutating func count(of key: BlobKey, at slot: Int, allowed: Bool) {
            self.tallies[slot].holders += 1
            if !allowed, self.tallies[slot].evictable {
                self.tallies[slot].evictable = false
                self.shared[key] = nil
            }
        }

        /// `slot`, claimed for a new blob when it is still the default: one hash of the key per record.
        private static func claim(_ slot: inout Int, next: Int) -> (slot: Int, isNew: Bool) {
            guard slot < 0 else {
                return (slot, false)
            }
            slot = next
            return (next, true)
        }

        /// The holders of the evictable blob at `slot` that several records share, in identifier order; `nil` for a
        /// blob one record holds (`Tally.first`).
        private func sharedHolders(of slot: Int) -> [Holder]? {
            guard self.tallies[slot].holders > 1, let holders = self.shared[self.tallies[slot].key] else {
                return nil
            }
            return holders.sorted { $0.id.rawValue < $1.id.rawValue }
        }

        /// The size of the evictable blob at `slot`: the one its first holder by identifier records (every holder of a
        /// blob records the blob's size, I-2).
        private func size(of slot: Int) -> Int64 {
            guard let holders = self.sharedHolders(of: slot) else {
                return self.tallies[slot].first.bytes
            }
            return holders[0].bytes
        }

        /// Appends one victim per holder of `ranked`'s blob, in identifier order, each carrying the blob's size.
        func appendVictims(of ranked: Ranked, to victims: inout [EvictionVictim]) {
            let key = self.tallies[ranked.slot].key
            guard let holders = self.sharedHolders(of: ranked.slot) else {
                let holder = self.tallies[ranked.slot].first
                victims.append(EvictionVictim(id: holder.id, blob: key, byteSize: ranked.bytes, lastAccess: holder.lastAccess))
                return
            }
            for holder in holders {
                victims.append(EvictionVictim(id: holder.id, blob: key, byteSize: ranked.bytes, lastAccess: holder.lastAccess))
            }
        }

        /// `ranked` as a candidate.
        func candidate(_ ranked: Ranked) -> EvictionCandidate {
            var victims: [EvictionVictim] = []
            self.appendVictims(of: ranked, to: &victims)
            return EvictionCandidate(
                key: self.tallies[ranked.slot].key,
                bytes: ranked.bytes,
                lastAccess: Date(timeIntervalSinceReferenceDate: ranked.lastAccess),
                outsideScope: ranked.outsideScope,
                victims: victims
            )
        }
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
