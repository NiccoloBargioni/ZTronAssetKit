import Foundation
import Synchronization
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

extension EngineFailurePathTests {
    /// What the chain's condition observer saw.
    struct ProbeChainWatch: Sendable {
        /// The most member jobs queued at one observation.
        var mostQueued = 0
        /// The most member jobs queued or downloading at one observation.
        var mostWorking = 0
    }

    /// A chain of half-open probes that each end without a verdict re-admits one parked job per probe exit, the first in
    /// the pump's order, not every job the breaker parked (L4-R22; Stage 3, S3-B-063): an ambiguous 403 opens the
    /// authentication breaker under a prefetch group while three other members are in flight, and the pump parks every
    /// queued member behind it; every member then answers 404, and the clock reaches the cooldown's end. Each parked member
    /// probes in turn. Re-admitting every parked job at each exit, for the pump to park all but the next probe again in the
    /// free slots, made the chain's work quadratic in the parked jobs (10,000 parked: about 161 s of actor work in total).
    /// The re-admission work is counted (`circuitReadmissions`): each parked member is re-queued once over the whole chain,
    /// one per exit. The condition observer, which runs at every notification of every turn, never sees more than one
    /// member queued, nor more than one queued and one downloading; the members probe in the pump's order, each once, and
    /// the chain ends with every member failed and nothing parked.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a chain of half-open probes ending without a verdict re-admits one parked job per probe exit, in the pump's order, not every job the breaker parked", .timeLimit(.minutes(1)))
    func probeChainReadmitsOnePerExit() async throws {
        let count = 64
        let slots = 4
        let tuning = SyncTuning(maxConcurrentTransfers: slots, reservedInteractiveSlots: 0, breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let harness = EngineHarness.make(tuning: tuning)
        let members = (0..<count).map { EngineHarness.onDemand(String(format: "chain-%03d", $0), EngineFixture.bytes(UInt64(71_000 + $0), count: 16)) }
        try await EngineSingleFlightTests.applied(members, harness: harness)
        let engine = harness.engine
        let origin = harness.source.originID
        let missing = TransferError.permanentMissing(httpStatus: 404)
        let group = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        // No attempt is scripted yet: the first `slots` members wait in flight, the others in the queue.
        await engine.awaitCondition { $0.state.inFlight.count == slots }
        // The 403 opens the breaker (it fails its asset for the run, no retry); the freed slot's pump parks every queued
        // member behind it. The other attempts in flight then answer 404 (no breaker input while it is open).
        await harness.source.script(members[0].transferID, [.fail(EngineRegressionCycle20Tests.forbidden)])
        await engine.awaitCondition { $0.state.circuitParked.count == count - slots }
        for member in members[1..<slots] {
            await harness.source.script(member.transferID, [.fail(missing)])
        }
        await engine.awaitCondition { $0.state.inFlight.isEmpty }
        for member in members[slots...] {
            await harness.source.script(member.transferID, [.fail(missing)])
        }
        guard case .open(_, let cooldownEnd, _)? = await engine.readForTests({ $0.state.breakers[origin]?.state }) else {
            Issue.record("setup: the 403 opened the breaker")
            await engine.shutdown()
            return
        }
        let readmittedBefore = await engine.readForTests { $0.state.circuitReadmissions }
        let ids = Set(members.map(\.transferID))
        let watch = Mutex(ProbeChainWatch())
        let observer = Task {
            await engine.awaitCondition { engine in
                var queued = 0
                var working = 0
                for transfer in ids {
                    switch engine.state.jobs[transfer]?.state {
                    case .queued?:
                        queued += 1
                        working += 1
                    case .downloading?:
                        working += 1
                    default:
                        break
                    }
                }
                watch.withLock { seen in
                    seen.mostQueued = max(seen.mostQueued, queued)
                    seen.mostWorking = max(seen.mostWorking, working)
                }
                return engine.state.circuitParked.isEmpty && working == 0
            }
        }
        // The cooldown's end: the chain runs without the clock moving again. A move lands on the instant exactly (F-41).
        harness.time.advance(to: cooldownEnd)
        while harness.time.monotonicNow() < cooldownEnd {
            harness.time.advance(by: 1e-9)
        }
        await EngineHarness.value(of: observer)
        let seen = watch.withLock { $0 }
        let readmitted = await engine.readForTests { $0.state.circuitReadmissions } - readmittedBefore
        #expect(readmitted == count - slots, "each parked member is re-admitted once over the chain of \(count - slots) exits: \(readmitted)")
        #expect(seen.mostQueued <= 1, "at most one member waits in the queue for the probe: \(seen.mostQueued)")
        #expect(seen.mostWorking <= 2, "at most the probe and the next member work: \(seen.mostWorking)")
        let starts = await harness.source.starts.map(\.id)
        #expect(starts.count == count, "each parked member probed once: \(starts.count)")
        #expect(Array(starts.dropFirst(slots)) == Array(members.dropFirst(slots).map(\.transferID)), "the parked members probe in the pump's order")
        let after = await engine.readForTests { engine in
            (failed: members.filter { engine.state.jobs[$0.transferID] == nil || engine.state.jobs[$0.transferID]?.state.kind == .failed }.count, violations: engine.invariantViolations())
        }
        #expect(after.failed == count, "every member failed its probe: \(after.failed)")
        #expect(after.violations.isEmpty, "\(after.violations.prefix(3))")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }
}
