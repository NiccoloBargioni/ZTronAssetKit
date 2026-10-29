/// The reaper's work list for one `reap` run (ARCHITECTURE §4.4, ADR draft B-10): the keys deletable when the run began,
/// in sorted order, read through a cursor.
///
/// A deletion unit is bounded by time as well as by count, so it may attempt only a prefix of its batch; the keys it did
/// not attempt lead the next batch, unchanged. They stay where they are in the list and the cursor stops at the first
/// of them, instead of being put back at the front of the remaining queue one by one: each such insertion shifted the
/// whole remaining queue, so a reclaim in units that attempt 20 of 64 keys cost O(n² / 20) element moves (Stage 3
/// S3-PERF-04). Now every key is read a bounded number of times however long the list is.
struct ReapQueue {
    /// The keys, sorted; never mutated.
    private let keys: [BlobKey]
    /// The first key not yet consumed.
    private var cursor = 0
    /// Where the keys of the last batch sit in `keys`, in batch order.
    private var positions: [Int] = []
    /// One past the last key the last batch's scan read.
    private var scanEnd = 0
    /// How many times a key was read for a batch over the run. A key is read again only while it is not yet consumed
    /// and inside the next batch's window, so this is at most about `batch size / keys attempted per unit` reads per key
    /// (the structural bound the tests pin), never a function of the list's length.
    private(set) var reads = 0

    /// A queue over `keys`, which the caller sorted.
    init(_ keys: [BlobKey]) {
        self.keys = keys
    }

    /// Whether every key was consumed.
    var isEmpty: Bool {
        self.cursor >= self.keys.count
    }

    /// The next batch: up to `limit` keys from the cursor that `admit` takes, in list order. `admit` re-validates a key
    /// against the state as it is now (and marks it when it takes it); a key it refuses is passed over. Nothing is
    /// consumed until `consume(attempted:)`.
    mutating func nextBatch(limit: Int, admit: (BlobKey) -> Bool) -> [BlobKey] {
        var batch: [BlobKey] = []
        self.positions.removeAll(keepingCapacity: true)
        var scan = self.cursor
        while scan < self.keys.count, batch.count < limit {
            let key = self.keys[scan]
            self.reads += 1
            if admit(key) {
                batch.append(key)
                self.positions.append(scan)
            }
            scan += 1
        }
        self.scanEnd = scan
        return batch
    }

    /// Consumes the last batch's first `attempted` keys and the keys its scan passed over before the first key the unit
    /// did not attempt; that key and the rest of the window lead the next batch, in their order.
    mutating func consume(attempted: Int) {
        if attempted < self.positions.count {
            self.cursor = self.positions[max(0, attempted)]
        } else {
            self.cursor = self.scanEnd
        }
        self.positions.removeAll(keepingCapacity: true)
    }
}
