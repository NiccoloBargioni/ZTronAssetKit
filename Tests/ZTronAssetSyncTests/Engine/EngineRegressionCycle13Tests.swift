import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Pins from close-out cycle 13 of the level-4 close-out (`docs/adr-drafts/f.md`, F-33).
@Suite("Engine regressions, close-out cycle 13")
struct EngineRegressionCycle13Tests {
    /// What closes the gate of the pending run in `clockOpenedGateWaitsForTheAlarm`.
    enum TimedGate: String, CaseIterable, Sendable {
        /// A manifest fetch answered 429 with a Retry-After: the gate opens when the throttle ends.
        case throttle
        /// A manifest 403 opened the auth breaker: the gate opens when its cooldown ends.
        case breaker
    }

    // MARK: A gate the clock opened (R-SYN-2; found by this cycle's stress and iOS Simulator runs)

    /// The model test checks the invariants after every operation, and a clock move is one: it opens a pending run's
    /// throttle or breaker gate, and the run starts in the alarm's next turn, when the alarm fires the deadline the move
    /// made due. An invariant check that ran before that turn reported "the pending run's throttle gate is open but no
    /// run started" for an engine that was about to start it (`R-SYN-2: 10,000 seeded random operations…`, seed 155373
    /// at operation 131, under load and on the iOS Simulator). The check here runs in the turn that moves the clock, so
    /// the alarm cannot have run; then the alarm's turn starts the run.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: the invariant check accepts a pending run whose gate the clock opened before the alarm's turn starts it", .timeLimit(.minutes(1)), arguments: TimedGate.allCases)
    func clockOpenedGateWaitsForTheAlarm(gate: TimedGate) async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(1)
        await harness.scriptTransfers(catalog)
        let manifest = FakeManifestResponse.fetched(EngineFixture.manifestData(catalog.map(\.0)), etag: EngineFixture.etag("v1"))
        let engine = harness.engine
        let pendingGate: PendingRunGate
        let deadline: DeadlineReason
        switch gate {
        case .throttle:
            await harness.source.scriptManifest([.fail(.transient(.throttled, retryAfter: .seconds(20))), manifest])
            try await harness.start()
            pendingGate = .throttle
            deadline = .pendingRun
        case .breaker:
            await harness.source.scriptManifest([manifest])
            try await harness.start()
            _ = await engine.sync(.force)
            let evidence = EngineFailurePathTests.evidence(.manifest, xml: false, bytes: 0)
            await harness.source.scriptManifest([.fail(.authentication(.forbiddenAmbiguous(evidence))), manifest])
            guard case .blocked(.circuitOpen, _) = await engine.sync(.force) else {
                Issue.record("setup: the run was not blocked by the breaker")
                return
            }
            pendingGate = .breaker
            deadline = .breaker(harness.source.originID)
        }
        // The blocked run has ended; its pending run waits for the deadline that opens its gate.
        await engine.awaitCondition { engine in
            engine.state.run == nil && engine.state.pendingRun?.gate == pendingGate && engine.state.heap.deadline(for: deadline) != nil
        }
        let time = harness.time
        let violations = await engine.readForTests { engine -> [String] in
            guard let at = engine.state.heap.deadline(for: deadline) else {
                return ["setup: no deadline opens the gate"]
            }
            // The clock reaches the deadline in this turn: the alarm, resumed by the move, has not fired it yet.
            time.advance(to: at)
            #expect(engine.pendingRunGate(engine.state.pendingRun ?? PendingRun(gate: pendingGate, trigger: .explicit)) == .open, "setup: the gate is open")
            return engine.invariantViolations()
        }
        #expect(violations.isEmpty, "\(gate): \(violations)")
        // The alarm's turn starts the pending run.
        await engine.awaitCondition { engine in
            engine.state.pendingRun == nil
        }
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }
}
