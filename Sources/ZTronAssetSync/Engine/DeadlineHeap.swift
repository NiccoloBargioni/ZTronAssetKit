import ZTronAssetModel

/// Why the alarm wakes (ARCHITECTURE §7.8): deadlines are data, re-validated against epochs when they fire.
enum DeadlineReason: Hashable, Sendable {
    /// A job's backoff ends (`failed(.at)`).
    case retry(TransferID, epoch: UInt64)
    /// An origin's throttle ends.
    case throttle(String)
    /// An origin's breaker cooldown or probe watchdog.
    case breaker(String)
    /// The store's own deadline (`AssetStore.nextDeadline()`).
    case store
    /// A pending run's debounce or gate.
    case pendingRun
    /// A trailing progress emission (sync-2 S2-24).
    case progress(EventSlot)
    /// A quarantined asset's re-download (R-CLN-8).
    case heal(AssetID)
    /// A manifest fetch's deadline (transport-2 T2-14).
    case manifest(UInt64)
}

/// One scheduled deadline.
struct Deadline: Hashable, Sendable {
    /// When.
    let at: MonotonicInstant
    /// Insertion order: ties fire in scheduling order, never in task-scheduling order (H-8).
    let sequence: UInt64
    /// Why.
    let reason: DeadlineReason
}

/// The min-heap of `(deadline, seq, reason)` behind the single alarm: a sorted array, since it holds at most a few
/// entries per job in flight; removal is eager (sync-1 S1-10).
struct DeadlineHeap {
    private(set) var entries: [Deadline] = []
    private var lastSequence: UInt64 = 0

    /// The earliest deadline.
    var first: Deadline? {
        self.entries.first
    }

    /// The number of entries (`EngineIntrospection.scheduledDeadlines`).
    var count: Int {
        self.entries.count
    }

    /// Schedules `reason` at `at`, replacing an existing entry for the same reason.
    mutating func schedule(_ reason: DeadlineReason, at: MonotonicInstant) {
        self.remove(reason)
        self.lastSequence += 1
        let deadline = Deadline(at: at, sequence: self.lastSequence, reason: reason)
        var low = 0
        var high = self.entries.count
        while low < high {
            let middle = (low + high) / 2
            let other = self.entries[middle]
            if (other.at, other.sequence) < (at, deadline.sequence) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        self.entries.insert(deadline, at: low)
    }

    /// The deadline scheduled for `reason`.
    func deadline(for reason: DeadlineReason) -> MonotonicInstant? {
        self.entries.first { $0.reason == reason }?.at
    }

    /// Removes the entry for `reason`.
    mutating func remove(_ reason: DeadlineReason) {
        self.entries.removeAll { $0.reason == reason }
    }

    /// Removes every entry `matches` selects.
    mutating func removeAll(where matches: (DeadlineReason) -> Bool) {
        self.entries.removeAll { matches($0.reason) }
    }

    /// Removes and returns every entry due at `now`, in `(deadline, seq)` order.
    mutating func popDue(at now: MonotonicInstant) -> [Deadline] {
        var due: [Deadline] = []
        while let first = self.entries.first, first.at <= now {
            due.append(self.entries.removeFirst())
        }
        return due
    }
}
