import ZTronAssetModel

/// The four dispatch queues (sync.md §7.2): user-initiated singles before user-initiated batches, then prefetch and
/// bulk. Each is a FIFO with lazy deletion: an entry is valid only while the job still carries its ticket and is
/// queued, so withdrawal and promotion are O(1) (bump the ticket). Compaction keeps each queue within twice its live
/// entries. Every entry carries its place (`Entry.place`), ascending from each queue's head, so an entry put back
/// (`reinstate`, `restoreAside`) returns to where it waited instead of jumping the queue (close-out cycle 11).
struct LaneQueues {
    /// A queue.
    enum Kind: Int, CaseIterable, Sendable {
        /// `resolve` at user-initiated priority.
        case userSingle
        /// `ensureAvailable` (user-initiated batches).
        case userBatch
        /// Carousel neighbours.
        case prefetch
        /// Background sync.
        case bulk
    }

    /// One queue entry.
    struct Entry: Hashable {
        /// The job's ticket when it was queued.
        let ticket: UInt64
        /// The job.
        let transfer: TransferID
        /// When it was queued (bulk aging).
        let queuedAt: MonotonicInstant
        /// Its place in its queue: `push` assigns it (appends count up from 1, front pushes down from 0, so a queue is
        /// in ascending order from its head); an entry put back keeps the place it had.
        var place: Int64 = 0
    }

    private var entries: [Kind: [Entry]] = [:]
    private var heads: [Kind: Int] = [:]
    /// Entries a scan took out of their queue for the caller (`setAside`), in the order met: the jobs of a released
    /// group, which wait until their interests leave; `restoreAside` puts the ones still valid back.
    private var aside: [Kind: [Entry]] = [:]
    /// Entries put back at their places (`reinstate`), merged into their queue at the next pass over it, so a batch of
    /// them costs one merge (C2).
    private var reinstated: [Kind: [Entry]] = [:]
    /// The last place an append took.
    private var lastBack: Int64 = 0
    /// The last place a front push took.
    private var lastFront: Int64 = 1

    /// Appends `entry` to `kind` (`front` puts it first: a preempted job resumes before newer work) and returns the place
    /// it took (`Entry.place`): after every place in the queue, or before every one.
    @discardableResult
    mutating func push(_ entry: Entry, to kind: Kind, front: Bool = false) -> Int64 {
        var entry = entry
        if front {
            self.lastFront -= 1
            entry.place = self.lastFront
            var list = self.entries[kind] ?? []
            let head = self.heads[kind] ?? 0
            list.insert(entry, at: head)
            self.entries[kind] = list
        } else {
            self.lastBack += 1
            entry.place = self.lastBack
            self.entries[kind, default: []].append(entry)
        }
        return entry.place
    }

    /// Puts `entry` back at its place (`entry.place`, the place its job had) among the entries still queued: the job
    /// of an entry a scan set aside, or left in place, while only released groups wanted it, which an interest wants
    /// again. Entries put back in one turn keep their order, whatever the order of the interests, and none passes work
    /// queued before it (R-SYN-3; review of close-out cycle 10, PROBE-C10R-3).
    mutating func reinstate(_ entry: Entry, to kind: Kind) {
        self.reinstated[kind, default: []].append(entry)
    }

    /// Merges the entries put back into `kind` by place, in one pass over the queue from its head.
    private mutating func absorb(_ kind: Kind) {
        guard var incoming = self.reinstated.removeValue(forKey: kind), !incoming.isEmpty else {
            return
        }
        incoming.sort { $0.place < $1.place }
        let list = self.entries[kind] ?? []
        var index = min(self.heads[kind] ?? 0, list.count)
        var merged: [Entry] = []
        merged.reserveCapacity(list.count - index + incoming.count)
        for entry in incoming {
            while index < list.count, list[index].place <= entry.place {
                merged.append(list[index])
                index += 1
            }
            merged.append(entry)
        }
        merged.append(contentsOf: list[index...])
        self.entries[kind] = merged
        self.heads[kind] = 0
    }

    /// Removes and returns the first valid entry of `kind` that `accept` takes; invalid entries before it are
    /// dropped, valid ones it skips stay in order, and valid ones `setAside` claims on the way are kept aside, so no
    /// later scan steps over them again.
    mutating func pop(
        _ kind: Kind,
        isValid: (Entry) -> Bool,
        setAside: (Entry) -> Bool = { _ in false },
        accept: (Entry) -> Bool = { _ in true }
    ) -> Entry? {
        self.scan(kind, isValid: isValid, setAside: setAside, accept: accept, take: true)
    }

    /// The first valid entry of `kind` that `accept` takes, left in place; valid entries `setAside` claims on the way
    /// are kept aside as in `pop`.
    mutating func peek(_ kind: Kind, isValid: (Entry) -> Bool, setAside: (Entry) -> Bool, accept: (Entry) -> Bool) -> Entry? {
        self.scan(kind, isValid: isValid, setAside: setAside, accept: accept, take: false)
    }

    /// Puts the entries set aside that are still valid back at their places in their queues, and drops the others.
    mutating func restoreAside(isValid: (Entry) -> Bool) {
        let aside = self.aside
        self.aside = [:]
        for kind in Kind.allCases {
            let valid = (aside[kind] ?? []).filter(isValid)
            guard !valid.isEmpty else {
                continue
            }
            self.reinstated[kind, default: []].append(contentsOf: valid)
            self.absorb(kind)
        }
    }

    /// Every entry set aside, stale ones included (the invariant check).
    var asideEntries: [Entry] {
        Kind.allCases.flatMap { self.aside[$0] ?? [] }
    }

    /// Every stored entry from the queues' heads, put-back and set-aside ones included, stale ones too (the invariant
    /// check: every queued job must be reachable from one of them).
    var storedEntries: [Entry] {
        Kind.allCases.flatMap { kind -> [Entry] in
            let list = self.entries[kind] ?? []
            return Array(list[min(self.heads[kind] ?? 0, list.count)...]) + (self.reinstated[kind] ?? []) + (self.aside[kind] ?? [])
        }
    }

    /// `pop` and `peek`: the scan from the head, which drops the invalid entries at the head and takes the entries set
    /// aside out of the part it scanned (and the entry it found when it takes it) in one rebuild of that part.
    private mutating func scan(
        _ kind: Kind,
        isValid: (Entry) -> Bool,
        setAside: (Entry) -> Bool,
        accept: (Entry) -> Bool,
        take: Bool
    ) -> Entry? {
        self.absorb(kind)
        guard var list = self.entries[kind] else {
            return nil
        }
        var head = self.heads[kind] ?? 0
        while head < list.count, !isValid(list[head]) {
            head += 1
        }
        var index = head
        var found: Entry?
        var removed: [Int] = []
        while index < list.count {
            let entry = list[index]
            if isValid(entry) {
                if setAside(entry) {
                    removed.append(index)
                    self.aside[kind, default: []].append(entry)
                } else if accept(entry) {
                    found = entry
                    break
                }
            }
            index += 1
        }
        if found != nil, take {
            removed.append(index)
        }
        if removed == [head] {
            head += 1
        } else if removed.count == 1 {
            list.remove(at: removed[0])
        } else if let last = removed.last {
            // One rebuild of the scanned part, whatever the number of entries removed from it.
            var kept: [Entry] = []
            kept.reserveCapacity(last + 1 - head - removed.count)
            var next = 0
            for position in head...last {
                if next < removed.count, removed[next] == position {
                    next += 1
                } else {
                    kept.append(list[position])
                }
            }
            list.replaceSubrange(head...last, with: kept)
        }
        if head > 32, head * 2 > list.count {
            list.removeFirst(head)
            head = 0
        }
        self.entries[kind] = list
        self.heads[kind] = head
        return found
    }

    /// The entries of `kind` from its head, in queue order, stale ones included (the caller checks each).
    mutating func pending(_ kind: Kind) -> ArraySlice<Entry> {
        self.absorb(kind)
        let list = self.entries[kind] ?? []
        return list[min(self.heads[kind] ?? 0, list.count)...]
    }

    /// Drops the invalid entries at the head of `kind` (the jobs a lane-wide park just parked), so the next pass over
    /// the queue does not step over them again.
    mutating func dropInvalidHead(_ kind: Kind, isValid: (Entry) -> Bool) {
        self.absorb(kind)
        guard var list = self.entries[kind] else {
            return
        }
        var head = self.heads[kind] ?? 0
        while head < list.count, !isValid(list[head]) {
            head += 1
        }
        if head > 32, head * 2 > list.count {
            list.removeFirst(head)
            head = 0
        }
        self.entries[kind] = list
        self.heads[kind] = head
    }

    /// The oldest valid entry of `kind`, without removing it (bulk aging).
    mutating func first(_ kind: Kind, isValid: (Entry) -> Bool) -> Entry? {
        self.absorb(kind)
        let list = self.entries[kind] ?? []
        var index = self.heads[kind] ?? 0
        while index < list.count {
            if isValid(list[index]) {
                return list[index]
            }
            index += 1
        }
        return nil
    }

    /// Drops every invalid entry, set-aside ones included, keeping order (the engine calls it when stale entries
    /// outnumber the jobs).
    mutating func compact(isValid: (Entry) -> Bool) {
        for kind in Kind.allCases {
            self.absorb(kind)
            let list = self.entries[kind] ?? []
            let head = self.heads[kind] ?? 0
            self.entries[kind] = list[min(head, list.count)...].filter(isValid)
            self.heads[kind] = 0
            if let aside = self.aside[kind] {
                self.aside[kind] = aside.filter(isValid)
            }
        }
    }

    /// Stored entries, stale, set-aside and put-back ones included (the 2 × live bound).
    var storedCount: Int {
        Kind.allCases.reduce(0) { count, kind in
            count + (self.entries[kind]?.count ?? 0) - (self.heads[kind] ?? 0) + (self.aside[kind]?.count ?? 0) + (self.reinstated[kind]?.count ?? 0)
        }
    }
}
