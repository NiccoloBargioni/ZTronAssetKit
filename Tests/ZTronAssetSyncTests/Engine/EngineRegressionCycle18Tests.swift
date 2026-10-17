import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Pins from close-out cycle 18 of the level-4 close-out (`docs/adr-drafts/f.md`, F-38): the throttle end a run and a
/// fetch-first `ensureAvailable` report when a 429 extends the origin's throttle between their manifest fetch's outcome
/// and their answer. No test here moves the clock; every wait is a condition, a held seam or a join that ends on
/// cancellation (L4-R17).
@Suite("Engine regressions, close-out cycle 18")
struct EngineRegressionCycle18Tests {
    /// An engine whose origin a prefetch transfer's 429 throttled for 30 s, with a second prefetch transfer held in
    /// flight whose 429 the test sends later, and the manifest fetch outcomes held from their waiters.
    @available(macOS 15.0, iOS 18.0, *)
    struct Throttled {
        let harness: EngineHarness
        /// The transfer held in flight; its 429 extends the throttle.
        let extender: ManifestEntry
        /// An on-demand entry nothing fetched yet.
        let missing: ManifestEntry
        /// The throttle's end the first 429 set.
        let firstEnd: MonotonicInstant
        /// The manifest requests made before the throttled fetch.
        let requests: Int
        let tokens: [InterestToken]
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func throttled() async throws -> Throttled {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0))
        let bytesA = EngineFixture.bytes(6_501)
        let bytesB = EngineFixture.bytes(6_502)
        let bytesM = EngineFixture.bytes(6_503)
        let a = EngineHarness.onDemand("a", bytesA)
        let b = EngineHarness.onDemand("b", bytesB)
        let m = EngineHarness.onDemand("m", bytesM)
        await harness.serveManifest([a, b, m])
        let engine = harness.engine
        let origin = harness.source.originID
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        // B is held in flight; A's 429 then throttles the origin for 30 s.
        await harness.source.script(b.transferID, [.hold, .stage(bytesB)])
        let tokenB = try await engine.registerGroup([b.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.active != nil }
        await harness.source.script(a.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(30))), .stage(bytesA)])
        let tokenA = try await engine.registerGroup([a.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state.isThrottleParked == true }
        let throttle = await engine.readForTests { $0.state.throttles[origin] }
        let firstEnd = try #require(throttle, "setup: the first 429 throttles the origin")
        let requests = await harness.source.manifestRequests.count
        await engine.holdManifestOutcomeDelivery()
        return Throttled(harness: harness, extender: b, missing: m, firstEnd: firstEnd, requests: requests, tokens: [tokenA, tokenB])
    }

    /// Waits until the fetch the caller joined holds its outcome, then lets B's 429 extend the origin's throttle to 60 s
    /// before the outcome reaches the caller; returns the extended end.
    @available(macOS 15.0, iOS 18.0, *)
    static func extendWhileHeld<T: Sendable>(_ throttled: Throttled, caller: Task<T, Never>) async throws -> MonotonicInstant {
        let engine = throttled.harness.engine
        let origin = throttled.harness.source.originID
        await untilFinishedOrCondition(caller, engine) { $0.manifestOutcomeHeld }
        let held = await engine.readForTests { $0.manifestOutcomeHeld }
        try #require(held, "setup: the throttled fetch's outcome waits for the release")
        await throttled.harness.source.release(throttled.extender.transferID, with: .failed(.transient(.throttled, retryAfter: .seconds(60))))
        let firstEnd = throttled.firstEnd
        await engine.awaitCondition { ($0.state.throttles[origin] ?? .zero) > firstEnd }
        let extended = await engine.readForTests { $0.state.throttles[origin] }
        let end = try #require(extended, "setup: the origin stays throttled")
        try #require(end > firstEnd, "setup: B's 429 extends the throttle")
        return end
    }

    // MARK: A fetch-first ensureAvailable answered after a 429 extended the throttle (R-SYN-10, R-SYN-5; cycle-17 verifier)

    /// `ensureAvailable` answers a throttled manifest fetch with the time left until the throttle ends (F-37). It read
    /// that end from the fetch's outcome, which the fetch's turn computed; its answer comes after two awaits (the
    /// waiter's resumption and the store's availability read), and a transfer's 429 in either window extends the
    /// origin's throttle. The caller was then told to retry 30 s before the throttle ends, while a request made at the
    /// same moment is told the extended end (F-36's rule; the cycle-17 correctness verifier's PROBE-C17C-ENSURESTALE).
    /// The fetch's outcome is held from the caller here (`holdManifestOutcomeDelivery()`), so the order is fixed.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: an ensureAvailable whose throttled manifest fetch is answered after a 429 extended the throttle reports the time left until the extended end", .timeLimit(.minutes(1)))
    func ensureReportsExtendedEnd() async throws {
        let throttled = try await Self.throttled()
        let harness = throttled.harness
        let engine = harness.engine
        let origin = harness.source.originID
        let missing = throttled.missing.identifier
        let ensure = Task { await engine.ensureAvailable(scope: .identifiers([missing])) }
        let extended = try await Self.extendWhileHeld(throttled, caller: ensure)
        await engine.releaseManifestOutcomeDelivery()
        let result = await joinCancelling(ensure)
        let throttle = await engine.readForTests { $0.state.throttles[origin] }
        #expect(throttle == extended, "nothing moved the throttle after B's 429")
        let expected = extended.seconds(since: harness.time.monotonicNow())
        if case .failure(.serverUnavailable(retryAfter: let wait)) = result {
            #expect(wait == expected, "the caller is told when the extended throttle ends: \(String(describing: wait)), expected \(expected)")
        } else {
            Issue.record("a throttled fetch-first ensureAvailable that the store cannot answer is unavailable: \(result)")
        }
        let requests = await harness.source.manifestRequests.count
        #expect(requests == throttled.requests, "the throttle refuses the fetch before any request: \(requests - throttled.requests)")
        for token in throttled.tokens {
            await engine.releaseGroup(token)
        }
        await engine.shutdown()
    }

    // MARK: A throttled sync answered after a 429 extended the throttle (R-SYN-5, R-SYN-6; cycle-17 verifier)

    /// A run whose manifest fetch the throttle refuses settles `.blocked(.throttled(until:))` and leaves a pending run
    /// for the throttle's end. The run reported the end the fetch's outcome carried, while its pending run was scheduled
    /// at the origin's end when the run answered: a transfer's 429 between the two (the run's task resumes after the
    /// fetch's turn) left the caller's outcome and `syncFinished` 30 s short of the throttle and of the pending run
    /// (the cycle-17 correctness verifier's PROBE-C17C-RUNEND, which reached the order 13 times in 300 without a seam).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a sync whose manifest fetch the throttle refuses reports the origin's end when a 429 extends the throttle before the run answers", .timeLimit(.minutes(1)))
    func throttledRunReportsExtendedEnd() async throws {
        let throttled = try await Self.throttled()
        let harness = throttled.harness
        let engine = harness.engine
        let origin = harness.source.originID
        let run = Task { await engine.sync(.force) }
        let extended = try await Self.extendWhileHeld(throttled, caller: run)
        await engine.releaseManifestOutcomeDelivery()
        let outcome = await joinCancelling(run)
        let after = await engine.readForTests { engine in
            (engine.state.throttles[origin], engine.state.heap.deadline(for: .pendingRun), engine.state.pendingRun?.gate)
        }
        #expect(after.0 == extended, "nothing moved the throttle after B's 429")
        if case .blocked(.throttled(let until), _) = outcome {
            #expect(until == extended, "the run reports the origin's throttle end \(extended), not \(until)")
            #expect(after.1 == until, "the pending run waits for the end the run reports: \(String(describing: after.1)), reported \(until)")
        } else {
            Issue.record("the run is blocked by the throttle: \(outcome)")
        }
        #expect(after.2 == .throttle, "the pending run waits for the throttle: \(String(describing: after.2))")
        let requests = await harness.source.manifestRequests.count
        #expect(requests == throttled.requests, "the throttle refuses the fetch before any request: \(requests - throttled.requests)")
        for token in throttled.tokens {
            await engine.releaseGroup(token)
        }
        await engine.shutdown()
    }
}
