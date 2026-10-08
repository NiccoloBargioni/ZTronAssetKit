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

    private struct CountWaiter {
        let pack: PackID
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let backend: any PackBackend
    private var flights: [PackID: Flight] = [:]
    private var waiters: [UInt64: Waiter] = [:]
    private var countWaiters: [CountWaiter] = []
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
        self.notifyCountWaiters()
    }

    /// Test seam: the callers waiting on `pack`'s flight.
    func waiterCount(on pack: PackID) -> Int {
        self.flights[pack]?.waiters.count ?? 0
    }

    /// Test seam: returns once at least `count` callers wait on `pack`'s flight, the coordinator closed, or the
    /// calling task was cancelled (so a test's time limit ends a wait that a defect would make endless).
    func waitForWaiters(on pack: PackID, count: Int) async {
        guard !self.closed, self.waiterCount(on: pack) < count else {
            return
        }
        // REENTRANCY: e-5 (proposed) — nothing: a terminal wait registered synchronously and resumed only by the
        // turn that reached the count, `close`, or the cancellation turn; the caller re-reads the census.
        await withTaskCancellationHandler {
            // REENTRANCY: e-5 (proposed) — as above.
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    self.countWaiters.append(CountWaiter(pack: pack, count: count, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.releaseCountWaiters()
            }
        }
    }

    private func releaseCountWaiters() {
        let waiting = self.countWaiters
        self.countWaiters.removeAll()
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
                await Self.fly(pack, flightID: flightID, backend: backend, coordinator: self)
            }
            self.flights[pack] = Flight(id: flightID, task: task, waiters: [id])
        }
        self.notifyCountWaiters()
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
        self.notifyCountWaiters()
    }

    // MARK: Flights

    /// One `ensureAvailable`, off the actor: progress is forwarded while the call runs, and the outcome is reported
    /// only after every progress value was, so a waiter sees all progress before its wait ends.
    private nonisolated static func fly(
        _ pack: PackID,
        flightID: UInt64,
        backend: any PackBackend,
        coordinator: PackAvailabilityCoordinator
    ) async {
        let (stream, continuation) = AsyncStream.makeStream(of: PackProgress.self)
        async let outcome = Self.ensureOnce(pack, backend: backend, progress: continuation)
        for await progress in stream {
            await coordinator.broadcast(progress, pack: pack, flightID: flightID)
        }
        await coordinator.complete(pack, flightID: flightID, outcome: await outcome)
    }

    private nonisolated static func ensureOnce(
        _ pack: PackID,
        backend: any PackBackend,
        progress: AsyncStream<PackProgress>.Continuation
    ) async -> Outcome {
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

    private func broadcast(_ progress: PackProgress, pack: PackID, flightID: UInt64) {
        guard let flight = self.flights[pack], flight.id == flightID else {
            return
        }
        for id in flight.waiters {
            self.waiters[id]?.progress?.yield(progress)
        }
    }

    private func complete(_ pack: PackID, flightID: UInt64, outcome: Outcome) {
        guard let flight = self.flights[pack], flight.id == flightID else {
            return
        }
        self.flights[pack] = nil
        for id in flight.waiters {
            self.waiters.removeValue(forKey: id)?.continuation.resume(returning: outcome)
        }
        self.notifyCountWaiters()
    }

    private func notifyCountWaiters() {
        var remaining: [CountWaiter] = []
        for waiter in self.countWaiters {
            if self.closed || self.waiterCount(on: waiter.pack) >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        self.countWaiters = remaining
    }
}
