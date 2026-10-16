import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Regressions the verifiers of close-out cycle 8 found in WP-F (cycle 9 of the level-4 close-out). Each failed before
/// its fix (`docs/adr-drafts/f.md`, F-29).
@Suite("Engine regressions, close-out cycle 9")
struct EngineRegressionCycle9Tests {
    // MARK: The cycle-6 clock driver outlived `driving` (L4-R8; PROBE-C8C-5)

    /// PROBE-C8C-5: `EngineRegressionCycle6Tests.driving` cancelled its clock driver without awaiting it, and the
    /// driver's wait for a sleeper returns on cancellation, so the driver could compute the earliest deadline and advance
    /// the clocks once more after `driving` returned: to a sleeper registered after it returned. In
    /// `R-SYN-10: ensureAvailable whose member waits for space fetches it as soon as a purge reclaimed the bytes, not at
    /// the store's next deadline` that sleeper was a purge's grace, which then reaped before the test's setup was done (a
    /// failed setup expectation, then a wait that never ended: the cycle-8 sanitizer run's time-limit overrun). Each round
    /// drives nothing while the driver waits, registers a sleeper 60 s ahead, waits until it is registered and gives a
    /// stale driver turns to act; the clock must not move. The verifier counted 7 and 6 stale advances in 2,000 rounds.
    @Test("R-SYN-11: the clock driver of the space tests has stopped when driving returns, so it never advances a clock to a sleeper registered afterwards (2,000 rounds)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func drivingStopsBeforeReturning() async {
        var stale = 0
        var unseen = 0
        for _ in 0..<2_000 {
            let clock = ManualTimeSource()
            let start = clock.monotonicNow()
            // The operation yields so the driver reaches its wait for a sleeper before `driving` cancels it.
            let value = await EngineRegressionCycle6Tests.driving([clock]) {
                for _ in 0..<4 {
                    await Task.yield()
                }
                return 0
            }
            let sleeper = Task {
                try? await clock.sleep(until: start.adding(seconds: 60))
            }
            // The registration is awaited by yielding (never a wall-clock wait): a stale driver may wake the sleeper
            // before it is seen, and then the clock has moved.
            var turns = 0
            while clock.pendingSleepers == 0, clock.monotonicNow() == start, turns < 10_000 {
                await Task.yield()
                turns += 1
            }
            for _ in 0..<8 {
                await Task.yield()
            }
            if clock.monotonicNow() != start || value != 0 {
                stale += 1
            } else if clock.pendingSleepers == 0 {
                unseen += 1
            }
            sleeper.cancel()
            await sleeper.value
        }
        #expect(stale == 0, "the clock moved after driving returned in \(stale) of 2,000 rounds")
        #expect(unseen == 0, "the sleeper never registered in \(unseen) rounds")
    }
}
