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
/// The pump starts on the first pull and ends with the stream; the consumer's cancellation stops it, and the
/// engine's stream it was reading is released by its own cancellation handler.
actor EventForwarder {
    private let lifecycle: ClientLifecycle
    /// A stream already registered (`subscribe()`) and the generation of its engine; read first.
    private var first: (stream: AsyncStream<AssetEvent>, generation: UInt64)?
    private var pump: Task<Void, Never>?
    /// A consumer waiting for an event.
    private var consumer: CheckedContinuation<AssetEvent?, Never>?
    /// An event waiting for a consumer, and the pump waiting for it to be taken (`false`: stop).
    private var offered: (event: AssetEvent, taken: CheckedContinuation<Bool, Never>)?
    private var finished = false

    /// A forwarder that reads `first` before any other engine stream.
    init(lifecycle: ClientLifecycle, first: (stream: AsyncStream<AssetEvent>, generation: UInt64)?) {
        self.lifecycle = lifecycle
        self.first = first
    }

    /// The consumer's stream: pulls through the forwarder.
    nonisolated static func stream(lifecycle: ClientLifecycle, first: (stream: AsyncStream<AssetEvent>, generation: UInt64)?) -> AsyncStream<AssetEvent> {
        let forwarder = EventForwarder(lifecycle: lifecycle, first: first)
        return AsyncStream(unfolding: {
            // REENTRANCY: g-7 (proposed) — nothing: `next()` re-reads its own state after every await.
            await forwarder.next()
        }, onCancel: {
            forwarder.cancel()
        })
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
            self.consumer = continuation
        }
    }

    /// The consumer was cancelled: stop the pump (one hop).
    nonisolated func cancel() {
        Task {
            // REENTRANCY: g-7 (proposed) — nothing: `stop` re-reads the state on the actor.
            await self.stop()
        }
    }

    private func stop() {
        self.finished = true
        self.pump?.cancel()
        self.offered?.taken.resume(returning: false)
        self.offered = nil
        self.consumer?.resume(returning: nil)
        self.consumer = nil
    }

    /// Hands `event` to a waiting consumer, or waits for one; `false` when the consumer is gone.
    private func offer(_ event: AssetEvent) async -> Bool {
        guard !self.finished else {
            return false
        }
        if let consumer = self.consumer {
            self.consumer = nil
            consumer.resume(returning: event)
            return true
        }
        // REENTRANCY: g-7 (proposed) — nothing: a terminal wait, resumed once by `next` or `stop`.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.offered = (event, continuation)
        }
    }

    /// The pump ended: a waiting consumer gets the end of the stream.
    private func end() {
        self.finished = true
        self.consumer?.resume(returning: nil)
        self.consumer = nil
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
                    // The consumer is gone and this task cancelled: one more pull runs the engine stream's
                    // cancellation handler, which releases its subscription.
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
