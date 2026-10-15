import Foundation
import ZTronAssetModel

extension SyncEngine {
    // MARK: Broadcast (R-SYN-12, ADR-023)

    /// Publishes `event` to every subscriber queue (bounded per key and subject); a waiting pull receives it directly.
    /// Each queue is mutated in place through the dictionary (a copy taken out and written back would copy a stalled
    /// subscriber's slots on every publication: O(n) each, O(n²) for a mass prune announced in one turn).
    func broadcast(_ event: AssetEvent) {
        self.state.lastEventSequence += 1
        let sequence = self.state.lastEventSequence
        var handOffs: [CheckedContinuation<AssetEvent?, Never>] = []
        for key in self.state.subscribers.keys.sorted() {
            guard let published = self.state.subscribers[key]?.publish(event, sequence: sequence) else {
                continue
            }
            if published.coalesced {
                self.state.metrics.eventsCoalesced += 1
            }
            if let handOff = published.handOff {
                handOffs.append(handOff)
                self.state.metrics.eventsDelivered += 1
                if let queue = self.state.subscribers[key], queue.finished, queue.isEmpty {
                    self.state.subscribers[key] = nil
                }
            }
        }
        for handOff in handOffs {
            handOff.resume(returning: event)
        }
        self.notifyObservers()
    }

    /// Offers a progress event to the source-side rate limit (≤ 1 per `progressInterval` per key, with a trailing
    /// emission, sync.md §10.5, sync-2 S2-24).
    func offerProgress(_ event: AssetEvent) {
        let slot = EventSlot(event)
        if slot == .run {
            self.state.progress.latestRun = event
        }
        let now = self.environment.time.monotonicNow()
        let interval = self.tuning.progressInterval
        if let last = self.state.progress.lastEmitted[slot], now < last.adding(seconds: interval) {
            if self.state.progress.trailing.updateValue(event, forKey: slot) == nil {
                self.state.heap.schedule(.progress(slot), at: last.adding(seconds: interval))
                self.rearm()
            }
            return
        }
        self.state.progress.lastEmitted[slot] = now
        self.state.progress.trailing[slot] = nil
        self.state.heap.remove(.progress(slot))
        self.broadcast(event)
    }

    /// The trailing emission of `slot`, when its interval ended.
    func flushProgress(_ slot: EventSlot, now: MonotonicInstant) {
        guard let event = self.state.progress.trailing.removeValue(forKey: slot) else {
            return
        }
        self.state.progress.lastEmitted[slot] = now
        self.broadcast(event)
    }

    /// Retires a progress key (its transfer or run ended): the pending trailing emission and every undelivered slot
    /// go (ADR-023; the terminal event supersedes them).
    func retireProgress(_ slot: EventSlot) {
        self.state.progress.trailing[slot] = nil
        self.state.progress.lastEmitted[slot] = nil
        self.state.heap.remove(.progress(slot))
        if slot == .run {
            self.state.progress.latestRun = nil
        }
        if case .transfer = slot {
            for key in self.state.subscribers.keys.sorted() {
                self.state.subscribers[key]?.retire(slot)
            }
        }
    }

    /// The active run's aggregate progress, rate-limited.
    func offerRunProgress() {
        guard let run = self.state.run, run.transferring else {
            return
        }
        let total = run.fetches.count
        let done = run.fetched + run.failures.count
        var inFlight: Int64 = 0
        for transfer in run.outstanding.keys {
            inFlight = PlanBuilder.adding(inFlight, self.state.jobs[transfer]?.active?.bytesReceived ?? 0)
        }
        let received = PlanBuilder.adding(run.bytes, inFlight)
        let expected = run.planned.fetchBytes
        var fraction = total == 0 ? 1 : Double(min(done, total)) / Double(total)
        if expected > 0, done < total {
            fraction = max(fraction, min(1, Double(received) / Double(expected)) * 0.999)
        }
        let progress = SyncProgress(fraction: min(1, max(0, fraction)), completedCount: min(done, total), totalCount: total, bytesReceived: received, bytesExpected: expected)
        self.offerProgress(.syncProgress(run.id, progress))
    }

    // MARK: Subscriptions

    /// Registers a subscriber with the initial replay (sync.md §10.6); after shutdown began, a queue holding only
    /// `clientShutDown` (R-SYN-15).
    func registerSubscriber() -> UInt64 {
        self.state.lastSubscriber += 1
        let key = self.state.lastSubscriber
        var queue = SubscriberQueue()
        func replay(_ event: AssetEvent) {
            self.state.lastEventSequence += 1
            _ = queue.publish(event, sequence: self.state.lastEventSequence)
        }
        if self.isShuttingDown {
            replay(.clientShutDown)
        } else {
            if self.state.launch != nil {
                replay(.snapshotChanged(generation: self.state.generation))
            }
            if let conditions = self.state.conditions {
                replay(.conditionsChanged(conditions))
            }
            if let run = self.state.run {
                replay(.syncStarted(run.id, run.trigger))
                if let progress = self.state.progress.latestRun {
                    replay(progress)
                }
            }
        }
        self.state.subscribers[key] = queue
        self.notifyObservers()
        return key
    }

    /// The next event of subscriber `key`; `nil` once its stream is over (unknown key, or drained after
    /// `clientShutDown`). Suspends on an empty queue; `unsubscribe` resumes it with `nil`.
    func pull(_ key: UInt64) async -> AssetEvent? {
        // REENTRANCY: f-6 (proposed) — nothing: the body takes or registers synchronously; the event arrives by value.
        await withCheckedContinuation { (continuation: CheckedContinuation<AssetEvent?, Never>) in
            // Taken in place, as `broadcast` publishes (no copy of a long backlog per pull).
            guard self.state.subscribers[key] != nil else {
                continuation.resume(returning: nil)
                return
            }
            if let event = self.state.subscribers[key]?.take() {
                self.state.metrics.eventsDelivered += 1
                if let queue = self.state.subscribers[key], queue.finished, queue.isEmpty {
                    self.state.subscribers[key] = nil
                }
                self.notifyObservers()
                continuation.resume(returning: event)
                return
            }
            if self.state.subscribers[key]?.finished == true {
                self.state.subscribers[key] = nil
                self.notifyObservers()
                continuation.resume(returning: nil)
                return
            }
            self.state.subscribers[key]?.pending?.resume(returning: nil)
            self.state.subscribers[key]?.pending = continuation
        }
    }

    /// Releases subscriber `key` (cancel, stream release); a waiting pull returns `nil`.
    func unsubscribe(_ key: UInt64) {
        guard let queue = self.state.subscribers.removeValue(forKey: key) else {
            return
        }
        queue.pending?.resume(returning: nil)
        self.notifyObservers()
    }

    /// `subscribe()`: registers and replays before returning (tests); `.shutDown` after shutdown began.
    func performSubscribe() async -> Result<AsyncStream<AssetEvent>, AssetError> {
        guard !self.isShuttingDown else {
            return .failure(.shutDown)
        }
        let key = self.registerSubscriber()
        return .success(EventSubscription.stream(engine: self, registered: key))
    }
}

/// One subscription's consumer side (sync.md §10.2): pull-based, registered on the first pull (or before
/// `subscribe()` returns), released on cancellation, on release of the stream and at shutdown. An actor, so its state
/// needs no lock (C1).
actor EventSubscription {
    private let engine: SyncEngine
    private var key: UInt64?
    private var done = false

    private init(engine: SyncEngine, key: UInt64?) {
        self.engine = engine
        self.key = key
    }

    /// A stream over a new subscription; `registered` is the key `subscribe()` already registered.
    nonisolated static func stream(engine: SyncEngine, registered: UInt64?) -> AsyncStream<AssetEvent> {
        let subscription = EventSubscription(engine: engine, key: registered)
        return AsyncStream(unfolding: {
            // REENTRANCY: f-6 (proposed) — nothing: `next()` re-reads its own state after every await.
            await subscription.next()
        }, onCancel: {
            subscription.cancel()
        })
    }

    /// The next event; registers on the first pull.
    func next() async -> AssetEvent? {
        guard !self.done else {
            return nil
        }
        let key: UInt64
        if let registered = self.key {
            key = registered
        } else {
            // REENTRANCY: f-6 (proposed) — `done`: a cancellation during the registration releases it at once.
            let registered = await self.engine.registerSubscriber()
            self.key = registered
            guard !self.done else {
                // REENTRANCY: f-6 (proposed) — nothing: terminal.
                await self.engine.unsubscribe(registered)
                return nil
            }
            key = registered
        }
        // REENTRANCY: f-6 (proposed) — `done` is set when the stream is over; nothing else is read.
        let event = await self.engine.pull(key)
        if event == nil {
            self.done = true
        }
        return event
    }

    /// The consumer was cancelled: release the subscription (one hop).
    nonisolated func cancel() {
        Task {
            // REENTRANCY: f-6 (proposed) — nothing: `finish` re-reads the state on the actor.
            await self.finish()
        }
    }

    private func finish() async {
        self.done = true
        if let key = self.key {
            // REENTRANCY: f-6 (proposed) — nothing: terminal.
            await self.engine.unsubscribe(key)
        }
    }

    deinit {
        if !self.done, let key = self.key {
            let engine = self.engine
            Task {
                // REENTRANCY: f-6 (proposed) — nothing: a released stream unsubscribes once.
                await engine.unsubscribe(key)
            }
        }
    }
}
