import ZTronAssetModel

/// Makes packs local, single-flight per pack (R-APL-1, transport-2 T2-14).
///
/// `ensureAvailable` may take as long as a multi-GB download, and whether the OS await returns on cancellation is
/// UNVERIFIED (APPLE-API-VERIFICATION §1.4, §5). So it never runs in a caller's task: each pack has one flight, a
/// task the coordinator owns, and callers wait on continuations the coordinator resumes. A caller that is cancelled
/// leaves at once without disturbing the others (H-3: one swipe never cancels a neighbour's asset), and the flight is
/// cancelled only when its last waiter left. Pack progress fans out to every waiter as values (D-12).
@available(iOS 26.0, macOS 26.0, *)
actor PackAvailabilityCoordinator {
    /// How one wait ended.
    enum Outcome: Sendable, Hashable {
        /// The pack is local.
        case available
        /// The pack seam failed.
        case failed(PackError)
        /// The waiter was cancelled, or the coordinator closed.
        case cancelled
    }

    private struct Waiter {
        let pack: PackID
        let continuation: CheckedContinuation<Outcome, Never>
        let progress: AsyncStream<PackProgress>.Continuation?
    }

    private struct Flight {
        let id: UInt64
        let task: Task<Void, Never>
        var waiters: Set<UInt64>
    }

    /// What a test-seam wait waits for.
    private enum Condition {
        /// At least `count` callers wait on `pack`'s flight.
        case waiters(PackID, count: Int)
        /// At least `count` flights reported their outcome after they had stopped being current.
        case staleCompletions(count: Int)
    }

    private struct ConditionWaiter {
        let condition: Condition
        let continuation: CheckedContinuation<Void, Never>
    }

    private let backend: any PackBackend
    private var flights: [PackID: Flight] = [:]
    private var waiters: [UInt64: Waiter] = [:]
    private var conditionWaiters: [ConditionWaiter] = []
    private var staleCompletions = 0
    private var nextID: UInt64 = 0
    private var closed = false

    /// A coordinator over `backend`; touches no pack API.
    init(backend: any PackBackend) {
        self.backend = backend
    }

    /// Waits until `pack` is local, joining the pack's flight or starting it. `progress` receives the pack's
    /// progress while this caller waits. Returns `.cancelled` when the calling task is cancelled (at once, whatever
    /// the OS does) or the coordinator closed.
    func ensure(_ pack: PackID, progress: AsyncStream<PackProgress>.Continuation?) async -> Outcome {
        let id = self.makeID()
        // REENTRANCY: e-4 (proposed) — nothing is read after the resumption: the outcome travels in the
        // continuation, and `join`, `leave`, `complete` and `close` each re-read the waiter and flight tables on the
        // actor (a waiter is resumed exactly once, by whichever of them removes it first).
        return await withTaskCancellationHandler {
            // REENTRANCY: e-4 (proposed) — as above: the body registers the waiter synchronously on the actor.
            await withCheckedContinuation { continuation in
                self.join(id, pack: pack, continuation: continuation, progress: progress)
            }
        } onCancel: {
            Task {
                // REENTRANCY: e-8 (proposed) — a hop onto the actor from a cancellation handler, which cannot touch
                // actor state synchronously; `leave` re-reads the waiter table, so a waiter already resumed and
                // removed by `complete` or `close` is left alone.
                await self.leave(id)
            }
        }
    }

    /// Cancels every flight and resumes every waiter with `.cancelled`; later calls return `.cancelled` at once.
    func close() {
        self.closed = true
        for flight in self.flights.values {
            flight.task.cancel()
        }
        self.flights.removeAll()
        let waiting = self.waiters.values
        self.waiters.removeAll()
        for waiter in waiting {
            waiter.continuation.resume(returning: .cancelled)
        }
        self.notifyConditionWaiters()
    }

    /// Test seam: the callers waiting on `pack`'s flight.
    func waiterCount(on pack: PackID) -> Int {
        self.flights[pack]?.waiters.count ?? 0
    }

    /// Test seam: returns once at least `count` callers wait on `pack`'s flight, the coordinator closed, or the
    /// calling task was cancelled (so a test's time limit ends a wait that a defect would make endless). `registered`
    /// runs on the actor once the wait is registered, so a test can cancel a wait it knows is pending.
    func waitForWaiters(on pack: PackID, count: Int, registered: (@Sendable () -> Void)? = nil) async {
        // REENTRANCY: e-5 (proposed) — nothing: a terminal wait (see `wait(for:registered:)`); the caller re-reads
        // the census.
        await self.wait(for: .waiters(pack, count: count), registered: registered)
    }

    /// Test seam: returns once at least `count` flights reported their outcome after they had stopped being current
    /// (their last waiter left, or the coordinator closed), the coordinator closed, or the calling task was cancelled.
    /// Such a report is ignored; this lets a test order a newer flight after it.
    func waitForStaleCompletions(_ count: Int) async {
        // REENTRANCY: e-5 (proposed) — nothing: a terminal wait (see `wait(for:registered:)`); the caller re-reads
        // the census.
        await self.wait(for: .staleCompletions(count: count), registered: nil)
    }

    private func wait(for condition: Condition, registered: (@Sendable () -> Void)?) async {
        guard !self.holds(condition) else {
            return
        }
        // REENTRANCY: e-5 (proposed) — nothing: a terminal wait registered synchronously and resumed only by the
        // turn that made the condition hold, `close`, or the cancellation turn; the caller re-reads the census.
        await withTaskCancellationHandler {
            // REENTRANCY: e-5 (proposed) — as above.
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    self.conditionWaiters.append(ConditionWaiter(condition: condition, continuation: continuation))
                    registered?()
                }
            }
        } onCancel: {
            Task {
                // REENTRANCY: e-8 (proposed) — a hop onto the actor from a cancellation handler;
                // `releaseConditionWaiters` re-reads the list, so a wait already resumed is never resumed twice.
                await self.releaseConditionWaiters()
            }
        }
    }

    private func holds(_ condition: Condition) -> Bool {
        guard !self.closed else {
            return true
        }
        switch condition {
        case .waiters(let pack, let count):
            return self.waiterCount(on: pack) >= count
        case .staleCompletions(let count):
            return self.staleCompletions >= count
        }
    }

    private func releaseConditionWaiters() {
        let waiting = self.conditionWaiters
        self.conditionWaiters.removeAll()
        for waiter in waiting {
            waiter.continuation.resume()
        }
    }

    // MARK: Waiters

    private func makeID() -> UInt64 {
        self.nextID += 1
        return self.nextID
    }

    private func join(
        _ id: UInt64,
        pack: PackID,
        continuation: CheckedContinuation<Outcome, Never>,
        progress: AsyncStream<PackProgress>.Continuation?
    ) {
        guard !self.closed, !Task.isCancelled else {
            continuation.resume(returning: .cancelled)
            return
        }
        self.waiters[id] = Waiter(pack: pack, continuation: continuation, progress: progress)
        if var flight = self.flights[pack] {
            flight.waiters.insert(id)
            self.flights[pack] = flight
        } else {
            let flightID = self.makeID()
            let backend = self.backend
            let task = Task {
                // REENTRANCY: e-6 (proposed) — nothing runs after the flight: `fly` reports through `broadcast`
                // and `complete`, which re-check that the flight is still current.
                await PackFlight.fly(pack, flightID: flightID, backend: backend, coordinator: self)
            }
            self.flights[pack] = Flight(id: flightID, task: task, waiters: [id])
        }
        self.notifyConditionWaiters()
    }

    private func leave(_ id: UInt64) {
        guard let waiter = self.waiters.removeValue(forKey: id) else {
            return
        }
        waiter.continuation.resume(returning: .cancelled)
        if var flight = self.flights[waiter.pack] {
            flight.waiters.remove(id)
            if flight.waiters.isEmpty {
                flight.task.cancel()
                self.flights[waiter.pack] = nil
            } else {
                self.flights[waiter.pack] = flight
            }
        }
        self.notifyConditionWaiters()
    }

    // MARK: Flight reports

    /// Forwards one progress value of the current flight of `pack` to its waiters. A flight that stopped being
    /// current had its task cancelled, which also ends its progress stream, so a stale value can only be one that
    /// was already taken from the stream when the flight was cancelled; it is dropped here by flight id.
    func broadcast(_ progress: PackProgress, pack: PackID, flightID: UInt64) {
        guard let flight = self.flights[pack], flight.id == flightID else {
            return
        }
        for id in flight.waiters {
            self.waiters[id]?.progress?.yield(progress)
        }
    }

    /// Ends the wait of every caller of the current flight of `pack`. The outcome of a flight that stopped being
    /// current (an OS await that outlived its cancellation, APPLE-API-VERIFICATION §5) is ignored: a newer flight's
    /// waiters get their own outcome.
    func complete(_ pack: PackID, flightID: UInt64, outcome: Outcome) {
        guard let flight = self.flights[pack], flight.id == flightID else {
            self.staleCompletions += 1
            self.notifyConditionWaiters()
            return
        }
        self.flights[pack] = nil
        for id in flight.waiters {
            self.waiters.removeValue(forKey: id)?.continuation.resume(returning: outcome)
        }
        self.notifyConditionWaiters()
    }

    private func notifyConditionWaiters() {
        var remaining: [ConditionWaiter] = []
        for waiter in self.conditionWaiters {
            if self.holds(waiter.condition) {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        self.conditionWaiters = remaining
    }
}

/// One `ensureAvailable` of one flight, run in the flight's task outside the coordinator: progress is forwarded
/// while the call runs, and the outcome is reported only after every progress value was, so a waiter sees all
/// progress before its wait ends.
@available(iOS 26.0, macOS 26.0, *)
enum PackFlight {
    /// Pack progress values buffered between the OS and a consumer. Progress only grows, and the scaler reports at
    /// most 101 values per waiter, so when a consumer falls behind a chatty OS status stream the oldest values are
    /// dropped and memory stays bounded; the newest value, and `finish()` after it, are always kept.
    static let progressBuffer = 64

    /// Runs the flight `flightID` of `pack` and reports to `coordinator`.
    static func fly(
        _ pack: PackID,
        flightID: UInt64,
        backend: any PackBackend,
        coordinator: PackAvailabilityCoordinator
    ) async {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PackProgress.self,
            bufferingPolicy: .bufferingNewest(Self.progressBuffer)
        )
        async let outcome = Self.ensureOnce(pack, backend: backend, progress: continuation)
        for await progress in stream {
            await coordinator.broadcast(progress, pack: pack, flightID: flightID)
        }
        await coordinator.complete(pack, flightID: flightID, outcome: await outcome)
    }

    private static func ensureOnce(
        _ pack: PackID,
        backend: any PackBackend,
        progress: AsyncStream<PackProgress>.Continuation
    ) async -> PackAvailabilityCoordinator.Outcome {
        defer {
            progress.finish()
        }
        do {
            try await backend.ensureAvailable(pack, progress: progress)
            return .available
        } catch {
            return .failed(error)
        }
    }
}
