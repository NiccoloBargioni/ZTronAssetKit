import ZTronAssetModel
import ZTronAssetSync

/// One consumer's event stream across reopens (R-SYN-12, B-15; WP-G, `docs/adr-drafts/g.md` G-2 and G-16).
///
/// The engine's streams are bound to their engine, and a reopen replaces the engine, whose shutdown ends its streams
/// with `clientShutDown`. The forwarder reads engine streams in one pump task and hands each event to the consumer pull
/// by pull, so the engine's backpressure still holds (at most one event waits here, R-SYN-12); when the engine it reads
/// was retired by a reopen, it drops that engine's `clientShutDown`, drains that stream to its end and continues with the
/// replacement's stream. A real shutdown ends the stream with `clientShutDown`, the last event (R-SYN-12, R-SYN-15).
///
/// **Followership precedes registration** (orchestrator ruling L5-R13, G-16). The forwarder becomes a follower of the
/// lifecycle in the same lifecycle turn that chooses the engine it registers with, before the registration's await
/// (`ClientLifecycle.register(_:)`): a `subscribe()` stream before `subscribe()` returns, an `events` stream on its first
/// pull. Every reopen hands every follower its replacement's stream before installing it, so a stream receives every
/// event of its registration's generation from that registration on, and every event of each later generation from that
/// generation's first one on (`clientStarted` included), except what the engine's own queue coalesces (one slot per
/// progress key and per subject, H-9). The pump never registers or follows by itself: it reads the registered stream,
/// then, after each retired one, the stream handed over for the next generation; only when the client was shut down
/// while that reopen ran is nothing handed over, and the last engine's stream, which yields its `clientShutDown`, ends
/// this one. A handed stream not newer than the one the forwarder holds is dropped.
///
/// The pump starts on the first pull and ends with the stream. The consumer's stream holds the forwarder through a
/// `Consumer` that the pump never retains, so the forwarder stops when the consumer's task is cancelled (`onCancel`) and
/// also when the consumer drops the stream without cancelling it (the usual `break` out of a `for await`, after which
/// `AsyncStream(unfolding:onCancel:)` calls no handler): the `Consumer`'s deinit stops it. Either way the pump's last
/// pull runs under cancellation, so the engine stream's own cancellation handler releases its subscription. The follower
/// entry goes when the pump ends (`end()`), or at once when no pump ever started (`stop()`: a `subscribe()` stream
/// dropped before its first pull), so it outlives neither the pump nor the consumer's stream (R-SYN-12).
actor EventForwarder {
    private let lifecycle: ClientLifecycle
    /// Whether the forwarder registers on its first pull (an `events` stream); a `subscribe()` stream's forwarder was
    /// registered before `subscribe()` returned.
    private var registersOnFirstPull: Bool
    /// An `events` stream's first pull is registering; a pull meanwhile waits for the pump that registration starts.
    private var registering = false
    /// The lifecycle's key for this forwarder while it is a follower (L5-R13): received with the registration, given
    /// back once, by `end()` or by `stop()`.
    private var followKey: UInt64?
    /// The registered stream and the generation of its engine, which the pump reads first; `nil` when that engine was
    /// retired before it answered (the streams the reopens handed over since carry the registration), or once the pump
    /// took it.
    private var first: (stream: AsyncStream<AssetEvent>, generation: UInt64)?
    /// The newest generation whose stream the forwarder holds or reads: a stream handed over for it or an older one is
    /// dropped (L5-R13).
    private var held: UInt64?
    private var pump: Task<Void, Never>?
    /// Consumers waiting for an event, in arrival order: two iterators of one stream that pull at once are served one
    /// event each, in turn, and neither waits for good.
    private var consumers: [CheckedContinuation<AssetEvent?, Never>] = []
    /// An event waiting for a consumer, and the pump waiting for it to be taken (`false`: stop).
    private var offered: (event: AssetEvent, taken: CheckedContinuation<Bool, Never>)?
    /// Streams of replacement engines that reopens subscribed this forwarder to before installing them (L5-R3), in
    /// generation order; the pump reads each once the stream before it ended with its retired engine's `clientShutDown`.
    private var handovers: [(stream: AsyncStream<AssetEvent>, generation: UInt64)] = []
    private var finished = false
    /// Test seam, `nil` in production: called on the actor once the pump waits in `offer` with an event no consumer
    /// asked for yet, so a test can drop the consumer's stream exactly then (`stop()` must end that wait; CLAUDE.md G4).
    private let offerParked: (@Sendable () -> Void)?

    private init(lifecycle: ClientLifecycle, registersOnFirstPull: Bool, offerParked: (@Sendable () -> Void)?) {
        self.lifecycle = lifecycle
        self.registersOnFirstPull = registersOnFirstPull
        self.offerParked = offerParked
    }

    /// An `events` stream: it registers, and becomes a follower, on its first pull. `offerParked` is the test seam
    /// (`nil` in production).
    nonisolated static func stream(
        lifecycle: ClientLifecycle,
        offerParked: (@Sendable () -> Void)? = nil
    ) -> AsyncStream<AssetEvent> {
        EventForwarder.stream(of: EventForwarder(lifecycle: lifecycle, registersOnFirstPull: true, offerParked: offerParked))
    }

    /// A `subscribe()` stream: registered with the engine serving now, and a follower, before it is returned;
    /// `.shutDown` after shutdown.
    static func subscribed(lifecycle: ClientLifecycle) async throws(AssetError) -> AsyncStream<AssetEvent> {
        let forwarder = EventForwarder(lifecycle: lifecycle, registersOnFirstPull: false, offerParked: nil)
        let registration = try await lifecycle.register(forwarder).get()
        await forwarder.registered(registration)
        return EventForwarder.stream(of: forwarder)
    }

    /// The consumer's stream: pulls through `forwarder`.
    private nonisolated static func stream(of forwarder: EventForwarder) -> AsyncStream<AssetEvent> {
        let consumer = Consumer(forwarder)
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

    /// How many events wait in the forwarder for a consumer: 0 or 1, R-SYN-12's bound (a test read: the L5-R13 model's
    /// I4).
    var bufferedEvents: Int {
        self.offered == nil ? 0 : 1
    }

    /// Takes a registration: its follower key and its stream, which the pump reads first. Streams handed over for the
    /// registration's generation or an older one are dropped; newer ones stay, for the reopens that ran meanwhile.
    private func registered(_ registration: ClientLifecycle.ForwarderRegistration) {
        self.followKey = registration.key
        guard let first = registration.first else {
            return
        }
        self.first = first
        self.held = max(self.held ?? first.generation, first.generation)
        self.handovers.removeAll { $0.generation <= first.generation }
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
        if self.pump == nil, !self.registering {
            if self.registersOnFirstPull {
                self.registering = true
                // REENTRANCY: g-7 (proposed) — `finished`, re-read right below: a consumer that stopped meanwhile leaves
                // the registration unused (its stream is released with it) and gives its follower entry back here.
                let registration = await self.lifecycle.registerEvents(self)
                self.registering = false
                self.registersOnFirstPull = false
                guard !self.finished else {
                    if let key = registration.key {
                        // REENTRANCY: g-7 (proposed) — nothing: terminal for this forwarder.
                        await self.lifecycle.unfollow(key)
                    }
                    return nil
                }
                self.registered(registration)
            }
            self.startPump()
        }
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

    private func stop() async {
        self.finished = true
        // Registered streams the pump never read are released here rather than with the forwarder.
        self.first = nil
        self.handovers = []
        self.pump?.cancel()
        self.offered?.taken.resume(returning: false)
        self.offered = nil
        self.resumeConsumers()
        // A pump that started gives the follower entry back when it ends (`end()`), so the entry outlives no pump; with
        // none, nobody else will (a `subscribe()` stream dropped before its first pull).
        if self.pump == nil, let key = self.followKey {
            self.followKey = nil
            // REENTRANCY: g-7 (proposed) — nothing: terminal; the key was taken before the await, so it is given back once.
            await self.lifecycle.unfollow(key)
        }
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

    /// The pump ended: a waiting consumer gets the end of the stream, and the follower entry is given back.
    private func end() async {
        self.finished = true
        self.first = nil
        self.handovers = []
        self.resumeConsumers()
        if let key = self.followKey {
            self.followKey = nil
            // REENTRANCY: g-7 (proposed) — nothing: terminal; the key was taken before the await, so it is given back once.
            await self.lifecycle.unfollow(key)
        }
    }

    /// A reopen subscribed this forwarder to the replacement engine of `generation` before installing it (L5-R3,
    /// L5-R13). A forwarder that already finished, or that holds a stream of that generation or a newer one, drops the
    /// stream at once, which releases its subscription.
    func handOver(_ stream: AsyncStream<AssetEvent>, generation: UInt64) {
        guard !self.finished else {
            return
        }
        if let held = self.held, generation <= held {
            return
        }
        self.handovers.append((stream, generation))
    }

    /// The oldest stream handed over for a generation after `previous` (the one whose stream just ended, retired) and up
    /// to `installed` (the generation serving now). Older ones are dropped; later ones belong to a reopen that has not
    /// installed its replacement and stay, and a reopen that never installs (the client shut down) leaves them unread.
    private func takeHandover(after previous: UInt64?, through installed: UInt64) -> (stream: AsyncStream<AssetEvent>, generation: UInt64)? {
        if let previous {
            self.handovers.removeAll { $0.generation <= previous }
        }
        guard let index = self.handovers.firstIndex(where: { $0.generation <= installed }) else {
            return nil
        }
        let handed = self.handovers.remove(at: index)
        self.held = max(self.held ?? handed.generation, handed.generation)
        return handed
    }

    /// Ends every waiting consumer's pull with the end of the stream.
    private func resumeConsumers() {
        let waiting = self.consumers
        self.consumers = []
        for consumer in waiting {
            consumer.resume(returning: nil)
        }
    }

    /// Starts the pump; `next()` calls it once, with no pump started and no registration in flight.
    private func startPump() {
        let lifecycle = self.lifecycle
        let first = self.first
        self.first = nil
        self.pump = Task {
            // REENTRANCY: g-7 (proposed) — nothing: the pump runs off the actor and re-enters only through `offer`,
            // `takeHandover` and `end`, which re-read the state.
            await EventForwarder.pump(into: self, lifecycle: lifecycle, first: first)
        }
    }

    /// Reads the forwarder's engine streams (`forward`), then ends the forwarder, which gives its follower entry back.
    /// Off the actor, so the streams' iterators never cross an isolation boundary.
    private nonisolated static func pump(
        into forwarder: EventForwarder,
        lifecycle: ClientLifecycle,
        first: (stream: AsyncStream<AssetEvent>, generation: UInt64)?
    ) async {
        await EventForwarder.forward(into: forwarder, lifecycle: lifecycle, first: first)
        await forwarder.end()
    }

    /// Reads engine streams until one ends without having been retired, or the consumer is gone: the registered stream,
    /// then after each retired one the stream a reopen handed over for the next generation.
    private nonisolated static func forward(
        into forwarder: EventForwarder,
        lifecycle: ClientLifecycle,
        first: (stream: AsyncStream<AssetEvent>, generation: UInt64)?
    ) async {
        var pending = first
        var ended: UInt64?
        while !Task.isCancelled {
            let source: (stream: AsyncStream<AssetEvent>, generation: UInt64)
            if let given = pending {
                source = given
                pending = nil
            } else {
                // After a retired stream, or when the registration's engine was retired before it answered: the reopen
                // that retired it handed this follower its replacement's stream before installing it, and `current()`
                // waits for that reopen.
                let core = await lifecycle.current()
                if let handed = await forwarder.takeHandover(after: ended, through: core.generation) {
                    source = handed
                } else {
                    // Nothing handed over: the client was shut down while that reopen ran, so it installed nothing (L5-R13
                    // makes this the only case). The last engine's stream, made after its shutdown, yields only its
                    // `clientShutDown`, the real shutdown's, which ends this stream.
                    source = (core.engine.makeEventStream(), core.generation)
                }
            }
            var iterator = source.stream.makeAsyncIterator()
            var retired = false
            while let event = await iterator.next() {
                if event == .clientShutDown, await lifecycle.hasRetired(source.generation) {
                    // The retired engine's last event: its stream is drained to its end, so its events all precede the
                    // replacement's.
                    while await iterator.next() != nil {}
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
            ended = source.generation
        }
    }
}
