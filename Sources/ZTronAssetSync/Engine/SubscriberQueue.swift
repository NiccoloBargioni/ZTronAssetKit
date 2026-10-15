import ZTronAssetModel

/// The key an event coalesces under (ADR-023): progress events per key, terminal events per subject.
enum EventSlot: Hashable, Sendable {
    /// `snapshotChanged` (progress).
    case snapshot
    /// `conditionsChanged` (progress).
    case conditions
    /// `syncProgress` (progress).
    case run
    /// `transferProgress` of one asset (progress); retired with its transfer.
    case transfer(AssetID)
    /// `clientStarted`, `clientShutDown`.
    case client
    /// `syncStarted`.
    case runStarted
    /// `syncFinished`.
    case runFinished
    /// `assetAvailable`, `assetFailed`, `assetRemoved`.
    case asset(AssetID)
    /// `circuitChanged` of one origin.
    case breaker(String)
    /// `maintenanceFinished`.
    case maintenance

    /// Whether events of this slot are progress (replaced in place) rather than terminal (moved to the tail).
    var isProgress: Bool {
        switch self {
        case .snapshot, .conditions, .run, .transfer:
            return true
        case .client, .runStarted, .runFinished, .asset, .breaker, .maintenance:
            return false
        }
    }

    /// The slot of `event`.
    init(_ event: AssetEvent) {
        switch event {
        case .snapshotChanged:
            self = .snapshot
        case .conditionsChanged:
            self = .conditions
        case .syncProgress:
            self = .run
        case .transferProgress(let id, _):
            self = .transfer(id)
        case .clientStarted, .clientShutDown:
            self = .client
        case .syncStarted:
            self = .runStarted
        case .syncFinished:
            self = .runFinished
        case .assetAvailable(let id, _), .assetFailed(let id, _, _), .assetRemoved(let id, _):
            self = .asset(id)
        case .circuitChanged(let origin, _):
            self = .breaker(origin)
        case .maintenanceFinished:
            self = .maintenance
        }
    }
}

/// One subscriber's bounded queue (sync.md §10.3, H-9): at most one live slot per progress key and per subject, so a
/// stalled subscriber costs memory bounded by keys and subjects, never by time or event volume. Delivery order is
/// the publication order of each slot's latest occurrence; `clientShutDown` is always last.
struct SubscriberQueue {
    /// A live slot.
    private struct Live {
        let sequence: UInt64
        var event: AssetEvent
    }

    private var slots: [EventSlot: Live] = [:]
    private var order: [(sequence: UInt64, slot: EventSlot)] = []
    private var head = 0
    /// A suspended pull.
    var pending: CheckedContinuation<AssetEvent?, Never>?
    /// Whether `clientShutDown` was published: nothing follows it.
    private(set) var finished = false

    /// Live slots (`EngineIntrospection.bufferedEvents`).
    var liveCount: Int {
        self.slots.count
    }

    /// Whether the queue holds no event.
    var isEmpty: Bool {
        self.slots.isEmpty
    }

    /// Publishes `event`; returns the continuation to resume with it when a pull was waiting on an empty queue (the
    /// caller resumes it outside the mutation), and whether it replaced or moved a live slot.
    mutating func publish(_ event: AssetEvent, sequence: UInt64) -> (handOff: CheckedContinuation<AssetEvent?, Never>?, coalesced: Bool) {
        guard !self.finished else {
            return (nil, false)
        }
        if case .clientShutDown = event {
            self.finished = true
        }
        if self.slots.isEmpty, let pending = self.pending {
            self.pending = nil
            return (pending, false)
        }
        let slot = EventSlot(event)
        if var live = self.slots[slot] {
            if slot.isProgress, !self.finished {
                live.event = event
                self.slots[slot] = live
                return (nil, true)
            }
            self.slots[slot] = Live(sequence: sequence, event: event)
            self.order.append((sequence, slot))
            self.compactIfNeeded()
            return (nil, true)
        }
        self.slots[slot] = Live(sequence: sequence, event: event)
        self.order.append((sequence, slot))
        self.compactIfNeeded()
        return (nil, false)
    }

    /// Removes and returns the next event in order.
    mutating func take() -> AssetEvent? {
        while self.head < self.order.count {
            let (sequence, slot) = self.order[self.head]
            self.head += 1
            if let live = self.slots[slot], live.sequence == sequence {
                self.slots[slot] = nil
                self.compactIfNeeded()
                return live.event
            }
        }
        return nil
    }

    /// Drops an undelivered progress slot (a transfer's key retires with the transfer, ADR-023).
    mutating func retire(_ slot: EventSlot) {
        self.slots[slot] = nil
        self.compactIfNeeded()
    }

    /// Keeps `order` within twice the live slots (plus a constant).
    private mutating func compactIfNeeded() {
        let stored = self.order.count - self.head
        guard stored > 2 * self.slots.count + 16 || (self.head > 64 && self.head * 2 > self.order.count) else {
            return
        }
        let live = self.slots
        self.order = self.order[self.head...].filter { entry in live[entry.slot]?.sequence == entry.sequence }
        self.head = 0
    }

    /// Stored order entries, stale ones included (the 2 × live + 16 bound).
    var storedOrderCount: Int {
        self.order.count - self.head
    }
}

/// Progress rate limiting at the source (R-SYN-12, sync.md §10.5, sync-2 S2-24): a progress event of a key is
/// published at most once per `progressInterval`; a suppressed one waits as the key's trailing emission, published
/// when the interval ends unless a terminal event retires the key first.
struct ProgressGate {
    /// When each key last published.
    var lastEmitted: [EventSlot: MonotonicInstant] = [:]
    /// Each key's suppressed newest event.
    var trailing: [EventSlot: AssetEvent] = [:]
    /// The newest run progress offered (the replay of a late subscriber, sync.md §10.6).
    var latestRun: AssetEvent?
}
