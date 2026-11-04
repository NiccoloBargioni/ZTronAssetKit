import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// No follow starts once the engine stopped running (Stage 3 close-out cycle 20, ruling S3-R25 item 7; the cycle-19
/// requirements verifier's reqs #4). Shutdown's first turn drops every owed follow with the job table
/// (`drainEverything`), and a follow-up turn scheduled before finds the engine shutting down and returns
/// (`followFollowUp`), so a shutdown that lands between a follow's turns ends the follow there. An unknown-id
/// admission's store calls were the one path that started a follow after shutdown began: they followed the store view
/// they read without re-reading the lifecycle, where an apply's end and a catch-up re-read it first.
extension EngineFollowBarrierTests {
    /// Y's resolve fetches v2, which lists Y where the applied copy does not, so Y is admitted (`store.admit`), held at
    /// the store's metadata executor. Shutdown begins meanwhile, and its first turn answers Y's waiter. The admission
    /// then commits and reads the store's view, whose applied manifest (the admitted one) differs from the engine's
    /// copy. The view is not followed: the copy stays, no `snapshotChanged` is announced and no follow starts, which a
    /// shutting-down engine could not continue (`spawn` refuses every task then).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: an unknown-id admission whose store calls straddle shutdown's start follows no store view and starts no follow (F-28)", .timeLimit(.minutes(1)))
    func admissionStraddlingShutdownFollowsNothing() async throws {
        let base = FakeRemoteSource()
        let metadata = UnitHoldingGate()
        let harness = EngineHarness.make(source: base, metadata: metadata)
        let b = EngineHarness.onDemand("b", EngineFixture.bytes(2_020_701))
        let y = EngineHarness.onDemand("y", EngineFixture.bytes(2_020_702))
        await harness.serveManifest([b])
        let engine = harness.engine
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        let probe = EventProbe(stream: try await engine.subscribe().get())
        await harness.serveManifest([b, y], etag: "v2")
        // Y's admission is held at its first metadata unit, inside the admission's reads (`presenceReaders`).
        await metadata.holdNext()
        let resolveY = Task { await engine.awaitAsset(y.identifier, lane: .userInitiated) }
        var unitHolds = metadata.holds.makeAsyncIterator()
        _ = await unitHolds.next()
        let before = await engine.readForTests { e in
            (readers: e.state.presenceReaders, applies: e.state.appliesFollowed, follows: e.state.followsEnded, digest: e.state.applied.digest, generation: e.state.generation)
        }
        try #require(before.readers == 1, "setup: Y's admission is held inside the admission's reads: \(before.readers)")
        let shutdown = Task { await engine.shutdown() }
        await engine.awaitCondition { $0.isShuttingDown }
        await metadata.release()
        await shutdown.value
        _ = await probe.next { $0 == .clientShutDown }
        let received = await probe.received
        await probe.stop()
        let after = await engine.readForTests { e in
            (applies: e.state.appliesFollowed, follows: e.state.followsEnded, digest: e.state.applied.digest, owed: e.followOwed, scheduled: e.state.followFollowUpScheduled)
        }
        // A subscription first replays the current generation; a followed view would announce a later one.
        let announced = received.filter { if case .snapshotChanged(let generation) = $0 { generation > before.generation } else { false } }
        #expect(announced.isEmpty, "no store view is followed once shutdown began: \(received)")
        #expect(after.applies == before.applies && after.follows == before.follows, "no follow starts once shutdown began: \(before) -> \(after)")
        #expect(after.digest == before.digest, "the engine's copy stays the one it had when shutdown began")
        #expect(!after.owed && !after.scheduled, "no follow and no follow-up turn is left owed: \(after)")
        #expect(await resolveY.value == .failure(.shutDown), "shutdown answers Y's waiter")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations)")
        // The assumption the follow-up's unspawnable branch guarded is an invariant (`followBarrierViolations`).
        let forced = await engine.violations { $0.followOrder = [b.transferID] }
        #expect(forced == ["a follow is owed while the engine is shutDown"], "\(forced)")
    }

    /// F-K4 (Stage 3 close-out cycle 21, ruling S3-R26 item 6; `integrate-c21.md` A11 and K4): only a running engine
    /// drains, so no event waits for a follow once the engine stops running. `scheduleDrainFollowUp`'s branch for a
    /// refused spawn, which cleared the waiting events and the follow's tables, could not run (shutdown's first turn
    /// clears them, `drainEverything`), and the invariant checks the assumption instead. A running engine with an event
    /// waiting and its drain scheduled reports nothing; the same event after shutdown reports exactly K4.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: an event that waits for a follow once the engine stopped running is reported (F-28)", .timeLimit(.minutes(1)))
    func invariantsReportAnEventWaitingOnceShutDown() async throws {
        let harness = EngineHarness.make()
        let b = EngineHarness.onDemand("b", EngineFixture.bytes(2_022_801))
        await harness.serveManifest([b])
        let engine = harness.engine
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        let view = WorldView(throttle: nil, breaker: nil, conditions: ConditionsSnapshot(conditions: nil, pausedForThermal: false), edgeSerial: 0)
        let waiting: @Sendable (inout EngineState) -> Void = { state in
            state.eventsAfterFollow = [.throttleAnswers]
            state.eventStamps = [WorldStamp(at: .zero, view: 0)]
            state.worldHistory = [view]
        }
        let running = await engine.violations { state in
            waiting(&state)
            state.drainFollowUpScheduled = true
        }
        #expect(running.isEmpty, "a running engine's waiting event, its drain scheduled, is consistent: \(running)")
        await engine.shutdown()
        let settled = await engine.invariantViolations()
        #expect(settled.isEmpty, "\(settled)")
        let forced = await engine.violations(after: waiting)
        #expect(forced == ["1 events wait for a follow while the engine is shutDown"], "\(forced)")
    }
}
