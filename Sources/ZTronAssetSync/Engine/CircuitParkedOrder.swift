import ZTronAssetModel

/// The jobs the origin's breaker parked, ordered as the pump serves them (queue rank, then queue ticket): a binary
/// min-heap with lazy deletion (S3-B-063, L4-R22). A breaker that admits only a probe re-admits one parked job per
/// event, the first of this order (`SyncEngine.readmitForProbe()`), in O(log n), instead of every parked job for the pump
/// to park all but one again: a chain of half-open probes ending without a verdict was quadratic in the parked jobs
/// (10,000 parked: about 161 s of actor work in total, each turn within C2).
///
/// An entry is pushed when a job enters `blocked(circuitOpen)` and when an interest that may raise its rank joins it
/// while parked; an entry whose job left the park, was queued again (a new ticket) or now ranks differently is stale,
/// skipped (or re-pushed at its rank) when it reaches the top. The heap is emptied when no job is parked and rebuilt
/// from the parked set when stale entries outnumber live ones (`SyncEngine.noteCircuitParked`), so it stays O(parked).
struct CircuitParkedOrder {
    /// One parked job's place.
    struct Entry: Comparable {
        /// `SyncEngine.queueRank(_:)` when pushed.
        let rank: Int
        /// The job's queue ticket when pushed.
        let ticket: UInt64
        /// The job.
        let transfer: TransferID

        static func < (lhs: Entry, rhs: Entry) -> Bool {
            (lhs.rank, lhs.ticket, lhs.transfer) < (rhs.rank, rhs.ticket, rhs.transfer)
        }
    }

    /// The heap, smallest entry first.
    private(set) var entries: [Entry] = []

    /// The smallest entry.
    var first: Entry? {
        self.entries.first
    }

    /// The number of entries, stale ones included.
    var count: Int {
        self.entries.count
    }

    /// Adds `entry`.
    mutating func insert(_ entry: Entry) {
        self.entries.append(entry)
        var child = self.entries.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard self.entries[child] < self.entries[parent] else {
                break
            }
            self.entries.swapAt(child, parent)
            child = parent
        }
    }

    /// Removes and returns the smallest entry.
    @discardableResult
    mutating func removeFirst() -> Entry? {
        guard !self.entries.isEmpty else {
            return nil
        }
        self.entries.swapAt(0, self.entries.count - 1)
        let smallest = self.entries.removeLast()
        self.siftDown(from: 0)
        return smallest
    }

    /// Replaces every entry with `entries` (heapified in O(n)).
    mutating func rebuild(_ entries: [Entry]) {
        self.entries = entries
        var index = self.entries.count / 2
        while index > 0 {
            index -= 1
            self.siftDown(from: index)
        }
    }

    /// Removes every entry.
    mutating func removeAll() {
        self.entries.removeAll()
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        while true {
            let left = 2 * parent + 1
            guard left < self.entries.count else {
                return
            }
            var smallest = left
            let right = left + 1
            if right < self.entries.count, self.entries[right] < self.entries[left] {
                smallest = right
            }
            guard self.entries[smallest] < self.entries[parent] else {
                return
            }
            self.entries.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
