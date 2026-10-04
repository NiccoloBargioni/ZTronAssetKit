import ZTronAssetModel

/// A `BlockingExecutor` that suspends every unit until the test releases it (H-5 reentrancy tests; WP-B, WP-C, WP-F).
///
/// The REENTRANCY ledger (ARCHITECTURE §10) is tested by holding a store unit at a known point (a hash unit of
/// `publish`, a commit unit, a deletion unit), doing something else on the actor meanwhile, then releasing it:
/// `R-INT-2: a manifest change during the publish rename…`, `R-CLN-5: two identifiers with identical bytes
/// published concurrently…` and rows R2–R14. Units are numbered from 1 in submission order; `submittedUnits` and
/// `completedUnits` record the order, `waitForHeldUnits(atLeast:)` is event-driven, never polled.
///
/// An actor (the protocol is async), so no lock and no availability gate. Units run on the actor once released,
/// one at a time, like the serial live executor. With `holding == false` units run as soon as they arrive but are
/// still recorded, so a test lets setup through and holds only from the point it cares about.
public actor SteppedBlockingExecutor: BlockingExecutor {
    private var holding: Bool
    private var nextSequence = 0
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var submitted: [Int] = []
    private var completed: [Int] = []
    private var heldWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Creates an executor that holds every unit (`holding == true`) or lets them through.
    public init(holding: Bool = true) {
        self.holding = holding
    }

    /// Records the unit, suspends it while holding, then runs it to completion.
    public func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        self.nextSequence += 1
        let sequence = self.nextSequence
        self.submitted.append(sequence)
        if self.holding {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.gates[sequence] = continuation
                self.notifyHeldWaiters()
            }
        }
        let value = work()
        self.completed.append(sequence)
        return value
    }

    /// Starts or stops holding; stopping releases every held unit in submission order.
    public func setHolding(_ holding: Bool) {
        self.holding = holding
        if !holding {
            self.releaseAll()
        }
    }

    /// Releases one held unit; unknown or already released sequences are ignored.
    public func release(_ sequence: Int) {
        self.gates.removeValue(forKey: sequence)?.resume()
    }

    /// Releases the oldest held unit and returns its sequence, or `nil` when none is held.
    @discardableResult
    public func releaseNext() -> Int? {
        guard let sequence = self.gates.keys.min() else {
            return nil
        }
        self.release(sequence)
        return sequence
    }

    /// Releases every held unit in submission order.
    public func releaseAll() {
        for sequence in self.gates.keys.sorted() {
            self.release(sequence)
        }
    }

    /// Units suspended now, in submission order.
    public var heldUnits: [Int] {
        self.gates.keys.sorted()
    }

    /// Every unit submitted, in order.
    public var submittedUnits: [Int] {
        self.submitted
    }

    /// Every unit that finished running, in order.
    public var completedUnits: [Int] {
        self.completed
    }

    /// Suspends until at least `count` units are held at once.
    public func waitForHeldUnits(atLeast count: Int) async {
        if self.gates.count >= count {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.heldWaiters.append((count, continuation))
        }
    }

    private func notifyHeldWaiters() {
        let held = self.gates.count
        var ready: [CheckedContinuation<Void, Never>] = []
        self.heldWaiters.removeAll { waiter in
            if waiter.count <= held {
                ready.append(waiter.continuation)
                return true
            }
            return false
        }
        for continuation in ready {
            continuation.resume()
        }
    }
}
