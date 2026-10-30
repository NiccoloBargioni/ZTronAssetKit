import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Network and power policy, offline recovery and throttling (R-SYN-5, R-SYN-7, R-SYN-13, R-APL-4).
@Suite("Engine conditions")
struct EngineConditionsTests {
    static let offline = DeviceConditions(
        network: NetworkConditions(satisfied: false, expensive: false, constrained: false),
        power: PowerConditions(lowPowerMode: false, thermal: .nominal)
    )

    static let lowData = DeviceConditions(
        network: NetworkConditions(satisfied: true, expensive: false, constrained: true),
        power: PowerConditions(lowPowerMode: false, thermal: .nominal)
    )

    static let appleSource = RemoteSourceCapabilities(tier: .appleHosted, supportsPriority: false, supportsResume: false, supportsBackground: false, keepsSourceCopies: true)

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-13: assets that failed offline are retried when the path becomes satisfied without any timer", .timeLimit(.minutes(1)))
    func offlineRetriedOnSatisfiedEdge() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(41)
        let entry = EngineHarness.onDemand("neighbour", bytes)
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.fail(.offline(.noConnection)), .stage(bytes)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        try await harness.settle()
        let engine = harness.engine
        let token = try await engine.registerGroup(["neighbour"], lane: .prefetch).get()
        await engine.waitUntil { $0.jobsByState[.failed] == 1 }
        let parked = await engine.introspect()
        #expect(parked.armedTimers == 0 && parked.scheduledDeadlines == 0, "no timer waits for the network")
        #expect(harness.time.pendingSleepers == 0)
        await harness.conditions.send(EngineConditionsTests.offline)
        await harness.conditions.send(.unrestricted)
        await engine.waitUntil { $0.jobsByState.isEmpty }
        #expect(await harness.source.starts.count == 2)
        #expect(try await harness.view().records["neighbour"]?.referencedBlob != nil)
        await engine.releaseGroup(token)
        await engine.shutdown()
    }

    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 35.9 to 36.7 s beside a second TSan process at a
    /// load of 20 to 35 (61 % of 60 s) and 16.0 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7), over half
    /// its 60 s, so the guard is `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-7: bulk pauses on Low Data Mode and resumes when it is turned off", .timeLimit(.minutes(3)))
    func lowDataModePausesBulk() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(3)
        await harness.serveManifest(catalog.map(\.0))
        for (entry, bytes) in catalog {
            await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        }
        try await harness.start()
        let engine = harness.engine
        let first = Task { await engine.sync(.force) }
        await engine.waitUntil { $0.running == 3 }
        await harness.conditions.send(EngineConditionsTests.lowData)
        let outcome = await first.value
        guard case .blocked(.policy(.constrainedNetwork), _) = outcome else {
            Issue.record("expected blocked by Low Data Mode, got \(outcome)")
            return
        }
        let paused = await harness.source.controlLog.filter { $0.control == .pause }
        #expect(paused.count == 3)
        // Turning Low Data Mode off starts the pending run after its debounce.
        let stream = try await engine.subscribe().get()
        let probe = EventProbe(stream: stream)
        await harness.conditions.send(.unrestricted)
        // The clock moves to the pending run's debounce once the engine armed it (L4-R17: that deadline, not any sleeper).
        await engine.awaitCondition { $0.state.heap.deadline(for: .pendingRun) != nil }
        let debounced = try #require(await engine.readForTests { $0.state.heap.deadline(for: .pendingRun) })
        harness.time.advance(to: debounced)
        let finished = await probe.next { event in
            if case .syncFinished = event {
                return true
            }
            return false
        }
        guard case .syncFinished(_, .complete(let report))? = finished else {
            Issue.record("expected a complete pending run, got \(String(describing: finished))")
            return
        }
        #expect(report.trigger == .conditionsChanged)
        #expect(report.fetched == 3)
        await probe.stop()
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-7: Apple-tier transfers and update-checking manifest fetches start only when the engine's DeviceConditions satisfy their NetworkAccess", .timeLimit(.minutes(1)))
    func appleTierGatedByConditions() async throws {
        let source = FakeRemoteSource(originID: "apple-hosted", capabilities: EngineConditionsTests.appleSource)
        let strict = NetworkPolicy(userInitiatedOverridesPolicy: false)
        let harness = EngineHarness.make(source: source, conditions: EngineConditionsTests.lowData, network: strict)
        let bytes = EngineFixture.bytes(42)
        let entry = EngineHarness.onDemand("pack-asset", bytes)
        await harness.serveManifest([entry])
        await source.script(entry.transferID, [.stage(bytes)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let first = try #require(await source.manifestRequests.first)
        #expect(first.allowsUpdateCheck == false, "Low Data Mode refuses the bulk lane's update check")
        let engine = harness.engine
        // A user request the policy does not override is not started under Low Data Mode on the Apple tier.
        let waiter = Task { await engine.awaitAsset("pack-asset", lane: .userInitiated) }
        await engine.waitUntil { $0.jobsByState[.blocked] == 1 }
        #expect(await source.starts.isEmpty)
        await harness.conditions.send(.unrestricted)
        #expect(try await waiter.value.get().id == "pack-asset")
        #expect(await source.starts.count == 1)
        _ = await engine.sync(.force)
        #expect(await source.manifestRequests.last?.allowsUpdateCheck == true)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-7: an Apple-tier request is not started offline while the HTTP tier attempts it", .timeLimit(.minutes(1)))
    func appleTierNeverStartsOffline() async throws {
        let apple = FakeRemoteSource(originID: "apple-hosted", capabilities: EngineConditionsTests.appleSource)
        let harness = EngineHarness.make(source: apple, conditions: EngineConditionsTests.offline)
        let entry = EngineHarness.onDemand("x", EngineFixture.bytes(43))
        try await harness.start()
        // The installed catalog is read without an update check while offline.
        await harness.serveManifest([entry])
        _ = await harness.engine.sync(.force)
        #expect(await harness.engine.awaitAsset("x", lane: .userInitiated) == .failure(.offline))
        #expect(await apple.starts.isEmpty)
        await harness.engine.shutdown()

        let http = EngineHarness.make(conditions: EngineConditionsTests.offline)
        await http.serveManifest([entry])
        await http.source.script(entry.transferID, [.fail(.offline(.noConnection))])
        try await http.start()
        _ = await http.engine.sync(.force)
        #expect(await http.engine.awaitAsset("x", lane: .userInitiated) == .failure(.offline))
        #expect(await http.source.starts.count == 1, "the HTTP tier lets the transport fail fast")
        await http.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-APL-4: a missing catalog pack while offline reports offline and leaves the applied manifest in force", .timeLimit(.minutes(1)))
    func offlineCatalogKeepsApplied() async throws {
        let source = FakeRemoteSource(originID: "apple-hosted", capabilities: EngineConditionsTests.appleSource)
        let harness = EngineHarness.make(source: source)
        let catalog = EngineSyncTests.catalog(2)
        await harness.serve(catalog)
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        let before = try await harness.view()
        await source.scriptManifest([.fail(.offline(.noConnection))])
        #expect(await harness.engine.sync(.force) == .failed(.offline))
        let after = try await harness.view()
        #expect(after.appliedManifest == before.appliedManifest)
        #expect(try await harness.engine.awaitAsset("a0", lane: .userInitiated).get().id == "a0")
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: no transfer starts before a 429's Retry-After elapses on ManualTimeSource", .timeLimit(.minutes(1)))
    func retryAfterHoldsTheOrigin() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 1))
        let first = EngineFixture.entry("first", EngineFixture.bytes(44))
        let second = EngineFixture.entry("second", EngineFixture.bytes(45))
        await harness.serveManifest([first, second])
        await harness.source.script(first.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(30))), .stage(EngineFixture.bytes(44))])
        await harness.source.script(second.transferID, [.stage(EngineFixture.bytes(45))])
        let engine = harness.engine
        // The clock does not move before the 429 arrives: its Retry-After counts from now.
        let delivered = harness.time.monotonicNow()
        // A throttle-only blocked run ends blocked and leaves a pending run at the throttle's end (sync-2 S2-03). The
        // launch run's own outcome, whether or not a `sync` call would have joined it (L4-R17).
        let throttled = try await harness.startAndAwaitLaunchRun()
        let stream = try await engine.subscribe().get()
        let probe = EventProbe(stream: stream)
        guard case .blocked(.throttled, _) = throttled else {
            Issue.record("expected a throttled run, got \(throttled)")
            return
        }
        try await harness.time.requireSleepers(atLeast: 1)
        #expect(harness.time.nextDeadline == delivered.adding(seconds: 30), "the origin is held until exactly Retry-After")
        #expect(await harness.source.starts.count == 1)
        let sleepers = harness.time.pendingSleepers
        harness.time.advance(by: 29)
        // Nothing was due before the throttle's end, so no sleeper woke: nothing in the engine could have run.
        #expect(harness.time.nextDeadline == delivered.adding(seconds: 30) && harness.time.pendingSleepers == sleepers)
        #expect(await harness.source.starts.count == 1, "nothing starts before Retry-After elapses")
        harness.time.advance(by: 1)
        let finished = await probe.next { event in
            if case .syncFinished(let id, _) = event {
                return id.rawValue == 2
            }
            return false
        }
        guard case .syncFinished(_, .complete(let report))? = finished else {
            Issue.record("expected the pending run to complete, got \(String(describing: finished))")
            return
        }
        #expect(report.fetched == 2)
        #expect(await harness.source.starts.count == 3)
        #expect(try await engine.metrics().get().retries[.throttled] == 1)
        await probe.stop()
        await engine.shutdown()
    }
}
