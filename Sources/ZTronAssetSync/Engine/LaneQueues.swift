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
    /// dropped, valid ones it skips stay in order.
    mutating func pop(_ kind: Kind, isValid: (Entry) -> Bool, accept: (Entry) -> Bool = { _ in true }) -> Entry? {
        guard var list = self.entries[kind] else {
            return nil
        }
        var head = self.heads[kind] ?? 0
        while head < list.count, !isValid(list[head]) {
            head += 1
        }
        var index = head
        var found: Entry?
        while index < list.count {
            let entry = list[index]
            if isValid(entry), accept(entry) {
                found = entry
                break
            }
            index += 1
        }
        if found != nil {
            if index == head {
                head += 1
            } else {
                list.remove(at: index)
            }
        }
        if head > 32, head * 2 > list.count {
            list.removeFirst(head)
            head = 0
        }
        self.entries[kind] = list
        self.heads[kind] = head
        return found
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

    /// Drops every invalid entry, keeping order (the engine calls it when stale entries outnumber the jobs).
    mutating func compact(isValid: (Entry) -> Bool) {
        for kind in Kind.allCases {
            let list = self.entries[kind] ?? []
            let head = self.heads[kind] ?? 0
            self.entries[kind] = list[min(head, list.count)...].filter(isValid)
            self.heads[kind] = 0
        }
    }

    /// Stored entries, stale ones included (the 2 × live bound).
    var storedCount: Int {
        Kind.allCases.reduce(0) { $0 + (self.entries[$1]?.count ?? 0) - (self.heads[$1] ?? 0) }
    }
}
