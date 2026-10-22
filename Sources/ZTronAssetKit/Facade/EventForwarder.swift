import ZTronAssetModel
import ZTronAssetSync

/// One consumer's event stream across reopens (R-SYN-12, B-15; WP-G, `docs/adr-drafts/g.md` G-2).
///
/// The engine's streams are bound to their engine, and a reopen replaces the engine, whose shutdown ends its streams
/// with `clientShutDown`. The forwarder reads the current engine's stream in one pump task and hands each event to the
/// consumer pull by pull, so the engine's backpressure still holds (at most one event waits here, R-SYN-12); when the
/// engine it reads was retired by a reopen, it drops that engine's `clientShutDown` and continues with the
/// replacement's stream. A real shutdown ends the stream with `clientShutDown`, the last event (R-SYN-12, R-SYN-15).
///
/// The pump starts on the first pull and ends with the stream. The consumer's stream holds the forwarder through a
/// `Consumer` that the pump never retains, so the pump stops when the consumer's task is cancelled (`onCancel`) and
/// also when the consumer drops the stream without cancelling it (the usual `break` out of a `for await`, after which
/// `AsyncStream(unfolding:onCancel:)` calls no handler): the `Consumer`'s deinit stops the forwarder. Either way the
/// pump's last pull runs under cancellation, so the engine stream's own cancellation handler releases its
/// subscription; nothing outlives the consumer's stream (R-SYN-12).
actor EventForwarder {
    private let lifecycle: ClientLifecycle
    /// A stream already registered (`subscribe()`) and the generation of its engine; read first.
    private var first: (stream: AsyncStream<AssetEvent>, generation: UInt64)?
    private var pump: Task<Void, Never>?
    /// Consumers waiting for an event, in arrival order: two iterators of one stream that pull at once are served one
    /// event each, in turn, and neither waits for good.
    private var consumers: [CheckedContinuation<AssetEvent?, Never>] = []
    /// An event waiting for a consumer, and the pump waiting for it to be taken (`false`: stop).
    private var offered: (event: AssetEvent, taken: CheckedContinuation<Bool, Never>)?
    private var finished = false
    /// Test seam, `nil` in production: called on the actor once the pump waits in `offer` with an event no consumer
    /// asked for yet, so a test can drop the consumer's stream exactly then (`stop()` must end that wait; CLAUDE.md G4).
    private let offerParked: (@Sendable () -> Void)?

    /// A forwarder that reads `first` before any other engine stream.
    init(
        lifecycle: ClientLifecycle,
        first: (stream: AsyncStream<AssetEvent>, generation: UInt64)?,
        offerParked: (@Sendable () -> Void)? = nil
    ) {
        self.lifecycle = lifecycle
        self.first = first
        self.offerParked = offerParked
    }

    /// The consumer's stream: pulls through the forwarder. `offerParked` is the test seam (`nil` in production).
    nonisolated static func stream(
        lifecycle: ClientLifecycle,
        first: (stream: AsyncStream<AssetEvent>, generation: UInt64)?,
        offerParked: (@Sendable () -> Void)? = nil
    ) -> AsyncStream<AssetEvent> {
        let consumer = Consumer(EventForwarder(lifecycle: lifecycle, first: first, offerParked: offerParked))
        return AsyncStream(unfolding: {
            // REENTRANCY: g-7 (proposed) — nothing: `next()` re-reads its own state after every await.
            await consumer.forwarder.next()
        }, onCancel: {
            consumer.forwarder.cancel()
        })
    }

    /// The consumer's hold on its forwarder: captured by the consumer's stream only, never by the pump, so it is
    /// released with that stream and its deinit stops the forwarder (release on drop as well as on cancellation).
    private final class Consumer: Sendable {
        let forwarder: EventForwarder

        init(_ forwarder: EventForwarder) {
            self.forwarder = forwarder
        }

        deinit {
            self.forwarder.cancel()
        }
    }

    /// The next event, or `nil` once the stream ended.
    func next() async -> AssetEvent? {
        if let offered = self.offered {
            self.offered = nil
            offered.taken.resume(returning: true)
            return offered.event
        }
        guard !self.finished else {
            return nil
        }
        self.startPump()
        // REENTRANCY: g-7 (proposed) — nothing: a terminal wait, resumed once by `offer`, `end` or `stop`.
        return await withCheckedContinuation { (continuation: CheckedContinuation<AssetEvent?, Never>) in
            self.consumers.append(continuation)
        }
    }

    /// The consumer was cancelled or dropped its stream: stop the pump (one hop).
    nonisolated func cancel() {
        Task {
            // REENTRANCY: g-7 (proposed) — nothing: `stop` re-reads the state on the actor.
            await self.stop()
        }
    }

    private func stop() {
        self.finished = true
        // A registered stream the pump never read is released here rather than with the forwarder.
        self.first = nil
        self.pump?.cancel()
        self.offered?.taken.resume(returning: false)
        self.offered = nil
        self.resumeConsumers()
    }

    /// Hands `event` to a waiting consumer, or waits for one; `false` when the consumer is gone.
    private func offer(_ event: AssetEvent) async -> Bool {
        guard !self.finished else {
            return false
        }
        if !self.consumers.isEmpty {
            self.consumers.removeFirst().resume(returning: event)
            return true
        }
        // REENTRANCY: g-7 (proposed) — nothing: a terminal wait, resumed once by `next` or `stop`.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.offered = (event, continuation)
            self.offerParked?()
        }
    }

    /// The pump ended: a waiting consumer gets the end of the stream.
    private func end() {
        self.finished = true
        self.resumeConsumers()
    }

    /// Ends every waiting consumer's pull with the end of the stream.
    private func resumeConsumers() {
        let waiting = self.consumers
        self.consumers = []
        for consumer in waiting {
            consumer.resume(returning: nil)
        }
    }

    private func startPump() {
        guard self.pump == nil else {
            return
        }
        let lifecycle = self.lifecycle
        let first = self.first
        self.first = nil
        self.pump = Task {
            // REENTRANCY: g-7 (proposed) — nothing: the pump runs off the actor and re-enters only through `offer` and
            // `end`, which re-read the state.
            await EventForwarder.pump(into: self, lifecycle: lifecycle, first: first)
        }
    }

    /// Reads engine streams until one ends without having been retired, or the consumer is gone. Off the actor, so
    /// the streams' iterators never cross an isolation boundary.
    private nonisolated static func pump(
        into forwarder: EventForwarder,
        lifecycle: ClientLifecycle,
        first: (stream: AsyncStream<AssetEvent>, generation: UInt64)?
    ) async {
        var pending = first
        while !Task.isCancelled {
            let source: (stream: AsyncStream<AssetEvent>, generation: UInt64)
            if let given = pending {
                source = given
                pending = nil
            } else {
                let core = await lifecycle.current()
                source = (core.engine.makeEventStream(), core.generation)
            }
            var iterator = source.stream.makeAsyncIterator()
            var retired = false
            while let event = await iterator.next() {
                if event == .clientShutDown, await lifecycle.hasRetired(source.generation) {
                    retired = true
                    break
                }
                guard await forwarder.offer(event) else {
                    // The consumer cancelled or dropped its stream, and this task is cancelled: one more pull runs
                    // the engine stream's cancellation handler, which releases its subscription.
                    _ = await iterator.next()
                    return
                }
            }
            guard retired else {
                break
            }
        }
        await forwarder.end()
    }
}
