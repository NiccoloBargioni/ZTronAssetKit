import Testing
import ZTronAssetTestSupport

/// The release poll every WP-C test drives held store units with (`CorePoll.releasing`; Stage 3 ruling S3C-1).
@Suite("Test support: the poll that releases held store units (S3C-1)")
struct PollReleaseTests {
    /// The two ways a round lets units through (ungated, so it can be a test argument).
    enum Mode: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case oldest
        case everyUnit

        var testDescription: String {
            self.rawValue
        }
    }

    /// The race of S3-STAB-01 made deterministic: the condition captures its value, then the product overtakes it, makes
    /// the state change the condition reads and submits its next unit before the round ends. A poll that reads the held
    /// units after the condition releases that unit, which is the one the test means to keep (`listings() → 3` in
    /// `LegacyEdgeTests`, `plan.victims → [o4, o5]` in `EvictionOverlapTests`).
    @Test(
        "Test support: the release poll never lets through a unit submitted after a condition read it outran",
        .timeLimit(.minutes(1)),
        arguments: Mode.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func neverReleasesTheNextUnit(mode: Mode) async throws {
        let executor = SteppedBlockingExecutor(holding: true)
        let product = PollRaceProduct()
        // The product: unit 1, then the state change the condition reads, then unit 2. The state change waits for the
        // product's gate, so the test decides when it happens relative to the condition's read.
        let flow = Task {
            await executor.run {}
            await product.passGate()
            await product.markDone()
            await executor.run {}
        }
        try await executor.requireHeldUnits(atLeast: 1)
        var rounds = 0
        try await CorePoll.releasing(executor, mode == .oldest ? .oldest : .allExcept([]), until: "the product's state changed") {
            rounds += 1
            let done = await product.done
            if rounds == 2 {
                // Unit 1 was let through by the first round. This read is now older than what follows: the product makes
                // its change and submits unit 2 before the round decides what to release.
                await product.openGate()
                try await executor.requireHeldUnits(atLeast: 1)
            }
            return done
        }
        let held = await executor.heldUnits
        let completed = await executor.completedUnits
        await product.openGate()
        await executor.releaseAll()
        await flow.value

        #expect(rounds == 3, "one round released unit 1, one raced the product, one saw the change: \(rounds)")
        #expect(held == [2], "the unit submitted after the condition held is still held: \(held)")
        #expect(completed == [1], "only the unit submitted before the change ran: \(completed)")
    }
}

/// The product side of `PollReleaseTests`: a state flag and a gate the test opens.
actor PollRaceProduct {
    private(set) var done = false
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?

    /// Waits until `openGate()` was called (at once when it already was).
    func passGate() async {
        guard !self.open else {
            return
        }
        // REENTRANCY: nothing to re-validate: `open` only ever becomes true, and the continuation is resumed exactly once.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.waiter = continuation
        }
    }

    /// Opens the gate for good; idempotent.
    func openGate() {
        self.open = true
        self.waiter?.resume()
        self.waiter = nil
    }

    /// The state change the condition reads.
    func markDone() {
        self.done = true
    }
}
