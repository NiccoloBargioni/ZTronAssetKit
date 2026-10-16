import ZTronAssetModel

/// The four dispatch queues (sync.md §7.2): user-initiated singles before user-initiated batches, then prefetch and
/// bulk. Each is a FIFO with lazy deletion: an entry is valid only while the job still carries its ticket and is
/// queued, so withdrawal and promotion are O(1) (bump the ticket). Compaction keeps each queue within twice its live
/// entries.
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
    }

    private var entries: [Kind: [Entry]] = [:]
    private var heads: [Kind: Int] = [:]
    /// Entries a scan took out of their queue for the caller (`setAside`), in the order met: the jobs of a released
    /// group, which wait until their interests leave; `restoreAside` puts the ones still valid back.
    private var aside: [Kind: [Entry]] = [:]

    /// Appends `entry` to `kind` (`front` puts it first: a preempted job resumes before newer work).
    mutating func push(_ entry: Entry, to kind: Kind, front: Bool = false) {
        if front {
            var list = self.entries[kind] ?? []
            let head = self.heads[kind] ?? 0
            list.insert(entry, at: head)
            self.entries[kind] = list
        } else {
            self.entries[kind, default: []].append(entry)
        }
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

    /// Puts the entries set aside that are still valid back at the front of their queues, in the order they were met,
    /// and drops the others.
    mutating func restoreAside(isValid: (Entry) -> Bool) {
        let aside = self.aside
        self.aside = [:]
        for (kind, list) in aside {
            let valid = list.filter(isValid)
            guard !valid.isEmpty else {
                continue
            }
            let queue = self.entries[kind] ?? []
            self.entries[kind] = valid + queue[min(self.heads[kind] ?? 0, queue.count)...]
            self.heads[kind] = 0
        }
    }

    /// Every entry set aside, stale ones included (the invariant check).
    var asideEntries: [Entry] {
        Kind.allCases.flatMap { self.aside[$0] ?? [] }
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
    func pending(_ kind: Kind) -> ArraySlice<Entry> {
        let list = self.entries[kind] ?? []
        return list[min(self.heads[kind] ?? 0, list.count)...]
    }

    /// Drops the invalid entries at the head of `kind` (the jobs a lane-wide park just parked), so the next pass over
    /// the queue does not step over them again.
    mutating func dropInvalidHead(_ kind: Kind, isValid: (Entry) -> Bool) {
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
    func first(_ kind: Kind, isValid: (Entry) -> Bool) -> Entry? {
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
            let list = self.entries[kind] ?? []
            let head = self.heads[kind] ?? 0
            self.entries[kind] = list[min(head, list.count)...].filter(isValid)
            self.heads[kind] = 0
            if let aside = self.aside[kind] {
                self.aside[kind] = aside.filter(isValid)
            }
        }
    }

    /// Stored entries, stale and set-aside ones included (the 2 × live bound).
    var storedCount: Int {
        Kind.allCases.reduce(0) { $0 + (self.entries[$1]?.count ?? 0) - (self.heads[$1] ?? 0) + (self.aside[$1]?.count ?? 0) }
    }
}
