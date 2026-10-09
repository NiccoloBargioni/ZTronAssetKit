import ZTronAssetModel

/// A `BlockingExecutor` that suspends every unit until the test releases it (H-5 reentrancy tests; WP-B, WP-C, WP-F).
///
/// The REENTRANCY ledger (ARCHITECTURE §10) is tested by holding a store unit at a known point (a hash unit of
/// `publish`, a commit unit, a deletion unit), doing something else on the actor meanwhile, then releasing it:
/// `R-INT-2: a manifest change during the publish rename…`, `R-CLN-5: two identifiers with identical bytes
/// published concurrently…` and rows R2–R14. Units are numbered from 1 in submission order; `submittedUnits` and
/// `completedUnits` record the order, `waitForHeldUnits(atLeast:)` is event-driven, never polled, and ends when its
/// caller is cancelled (L2 follow-up): `requireHeldUnits(atLeast:)` is the form that then throws.
///
/// An actor (the protocol is async), so no lock and no availability gate. Units run on the actor once released,
/// one at a time, like the serial live executor. With `holding == false` units run as soon as they arrive but are
/// still recorded, so a test lets setup through and holds only from the point it cares about.
public actor SteppedBlockingExecutor: BlockingExecutor, CensusWaiting {
    private var holding: Bool
    private var nextSequence = 0
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var submitted: [Int] = []
    private var completed: [Int] = []
    /// Waits for a number of held units (`CensusWaiting`).
    var censusWaiters = CensusWaiters()

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
            // REENTRANCY: TS3 — nothing to re-validate: `sequence` is this call's own local, the gate was removed by
            // the release that resumed it, and `completed` is append-only, so units released out of order record
            // their completion in the order they actually ran (other calls may run or be released meanwhile; that
            // interleaving is what the executor exists to expose, H-5).
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

    /// Suspends until at least `count` units are held at once, or until the calling task is cancelled (a test past its
    /// time limit). A cancelled wait returns with fewer units held, so the caller's following expectations on
    /// `heldUnits` fail instead of the run hanging; a caller that goes on to index `heldUnits` or to await a held
    /// operation uses `requireHeldUnits(atLeast:)`, which throws instead.
    public func waitForHeldUnits(atLeast count: Int) async {
        // REENTRANCY: TS2 — nothing: a terminal wait (l2fu-1); no state is read afterwards.
        _ = await self.awaitCensus(target: count, met: { self.gates.count >= $0 }, registered: nil)
    }

    /// Suspends until at least `count` units are held at once; throws `CancellationError` when the calling task is
    /// cancelled first, so a test past its time limit ends at once instead of running on without the units.
    public func requireHeldUnits(atLeast count: Int) async throws(CancellationError) {
        // REENTRANCY: TS2 — nothing: a terminal wait (l2fu-1); no state is read afterwards.
        guard await self.awaitCensus(target: count, met: { self.gates.count >= $0 }, registered: nil) else {
            throw CancellationError()
        }
    }

    /// Test seam for the wait itself: `true` once at least `count` units are held, `false` when the calling task was
    /// cancelled first; `registered` runs on the actor once the wait is registered.
    package func waitForHeldUnits(atLeast count: Int, registered: @escaping @Sendable () -> Void) async -> Bool {
        // REENTRANCY: TS2 — nothing: a terminal wait (l2fu-1); no state is read afterwards.
        await self.awaitCensus(target: count, met: { self.gates.count >= $0 }, registered: registered)
    }

    private func notifyHeldWaiters() {
        let held = self.gates.count
        self.censusWaiters.resume { $0 <= held }
    }
}
