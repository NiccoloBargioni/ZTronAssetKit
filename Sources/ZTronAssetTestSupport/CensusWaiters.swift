/// The suspended census waits of one test-support actor (`waitForHeldUnits`, `waitForObservers`, `waitForInstalls`,
/// `EventProbe.waitForWaiters`; L2 follow-up, `docs/adr-drafts/l2fu.md` item 1).
///
/// A test past its `.timeLimit` is cancelled, and Swift Testing waits for its body to return. A wait that only its
/// census could end kept a regression that never reaches the census (a unit never parked, an observation never
/// started) suspended for good, so the whole run hung instead of failing one test. Each waiter here is therefore
/// resumed exactly once, by whichever comes first: with `true` by the actor turn whose census met its target, or with
/// `false` by its caller's cancellation (or by `resumeAll()` once the census can no longer change). A value stored in
/// its actor, so every mutation runs on that actor, and a waiter is always removed before it is resumed.
struct CensusWaiters {
    /// One suspended wait.
    private struct Waiter {
        let id: UInt64
        let target: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var waiters: [Waiter] = []
    private var lastID: UInt64 = 0

    /// Creates an empty table.
    init() {}

    /// Waits registered now.
    var count: Int {
        self.waiters.count
    }

    /// A fresh id for a wait about to register (its cancellation handler names it before the wait is registered).
    mutating func nextID() -> UInt64 {
        self.lastID += 1
        return self.lastID
    }

    /// Registers a wait for `target`.
    mutating func register(_ id: UInt64, target: Int, continuation: CheckedContinuation<Bool, Never>) {
        self.waiters.append(Waiter(id: id, target: target, continuation: continuation))
    }

    /// Resumes with `true`, and removes, every wait whose target the census now meets.
    mutating func resume(where met: (_ target: Int) -> Bool) {
        var ready: [CheckedContinuation<Bool, Never>] = []
        self.waiters.removeAll { waiter in
            guard met(waiter.target) else {
                return false
            }
            ready.append(waiter.continuation)
            return true
        }
        for continuation in ready {
            continuation.resume(returning: true)
        }
    }

    /// Resumes wait `id` with `false` (its caller was cancelled); a no-op for a wait already resumed and removed.
    mutating func cancel(_ id: UInt64) {
        guard let index = self.waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        self.waiters.remove(at: index).continuation.resume(returning: false)
    }

    /// Resumes every wait with `false`: the census can no longer reach any target (a finished `EventProbe`).
    mutating func resumeAll() {
        let pending = self.waiters
        self.waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(returning: false)
        }
    }
}

/// A test-support actor whose census waits end on their caller's cancellation (L2 follow-up). The conformance is
/// internal: the waits a test calls are each actor's own methods, which delegate to `awaitCensus`.
protocol CensusWaiting: Actor {
    /// The suspended census waits; mutated only on the actor.
    var censusWaiters: CensusWaiters { get set }
}

extension CensusWaiting {
    /// Suspends until `met(target)` holds, or until the calling task is cancelled: `true` when the census met
    /// `target`, `false` when the caller was cancelled first (a census already met is reported met, cancelled or not).
    /// The actor turns that change the census call `censusWaiters.resume(where:)`. `registered` runs on the actor once
    /// the wait is registered, so a test of the wait itself can cancel one it knows is pending.
    ///
    /// `met` is evaluated, and the wait registered, synchronously in the continuation body, so no census change can
    /// fall between the check and the registration. A caller cancelled before the body ran is never registered
    /// (`Task.isCancelled`); one cancelled afterwards is resumed by the hop of the cancellation handler, which cannot
    /// touch actor state synchronously and finds nothing to do for a wait the census already resumed.
    func awaitCensus(
        target: Int,
        met: (_ target: Int) -> Bool,
        registered: (@Sendable () -> Void)?
    ) async -> Bool {
        if met(target) {
            return true
        }
        let id = self.censusWaiters.nextID()
        // REENTRANCY: l2fu-1 (proposed) — nothing: a terminal wait (TS2), registered synchronously in the continuation
        // body and resumed exactly once, by the census turn that met `target` or by `cancelCensusWait(id)`; no state
        // is read afterwards (the caller re-reads the census).
        return await withTaskCancellationHandler {
            // REENTRANCY: l2fu-1 (proposed) — as above.
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if met(target) {
                    continuation.resume(returning: true)
                } else if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    self.censusWaiters.register(id, target: target, continuation: continuation)
                    registered?()
                }
            }
        } onCancel: {
            Task {
                // REENTRANCY: l2fu-2 (proposed) — nothing: this task is not the actor's turn; `cancelCensusWait`
                // re-reads the table and is a no-op for a wait the census already resumed.
                await self.cancelCensusWait(id)
            }
        }
    }

    /// Ends wait `id` with `false`, if it is still registered.
    func cancelCensusWait(_ id: UInt64) {
        self.censusWaiters.cancel(id)
    }
}
