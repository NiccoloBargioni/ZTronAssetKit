import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

extension EngineConditionsTests {
    /// The Apple tier decides `allowsUpdateCheck` from the bulk lane's access (`appleAccessBlock`): an expensive network
    /// the bulk policy forbids refuses the catalog update check, not only Low Data Mode does; on an unrestricted network
    /// the check is allowed again (R-SYN-7, R-APL-4; Stage 3, S3-CONF-02: a mutant that let the expensive branch through
    /// unless the network was also constrained passed every other test).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-7: an Apple-tier catalog update check is refused on an expensive network the bulk policy forbids", .timeLimit(.minutes(1)))
    func appleUpdateCheckRefusedOnExpensive() async throws {
        let source = FakeRemoteSource(originID: "apple-hosted", capabilities: EngineConditionsTests.appleSource)
        let cellular = DeviceConditions(
            network: NetworkConditions(satisfied: true, expensive: true, constrained: false),
            power: PowerConditions(lowPowerMode: false, thermal: .nominal)
        )
        let noBulkOnCellular = NetworkPolicy(bulkOnExpensive: false, prefetchOnExpensive: false, userInitiatedOverridesPolicy: false)
        let harness = EngineHarness.make(source: source, conditions: cellular, network: noBulkOnCellular)
        let entry = EngineHarness.onDemand("pack-asset", EngineFixture.bytes(4_201))
        await harness.serveManifest([entry])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let request = try #require(await source.manifestRequests.last)
        #expect(request.allowsUpdateCheck == false, "the bulk lane may not use an expensive network: no catalog update check")
        await harness.conditions.send(.unrestricted)
        _ = await harness.engine.sync(.force)
        #expect(await source.manifestRequests.last?.allowsUpdateCheck == true, "an unrestricted network allows the check")
        await harness.engine.shutdown()
    }

    static let critical = DeviceConditions(
        network: NetworkConditions(satisfied: true, expensive: false, constrained: false),
        power: PowerConditions(lowPowerMode: false, thermal: .critical)
    )

    /// With the conditions known at a critical thermal state, user-initiated work runs at most
    /// `interactiveConcurrencyAtCritical` transfers at once (ADR-036, `userCap`); the others wait in the user queue
    /// (R-SYN-7; Stage 3, S3-CONF-04 (a): a mutant that ignored the cap passed every other test).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-7: at a critical thermal state user-initiated transfers are capped at interactiveConcurrencyAtCritical once the conditions are known", .timeLimit(.minutes(1)))
    func criticalThermalCapsUserWork() async throws {
        let harness = EngineHarness.make(conditions: EngineConditionsTests.critical, tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 0))
        let assets = (0..<3).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(UInt64(4_400 + index))
            return (EngineHarness.onDemand("hot\(index)", bytes), bytes)
        }
        await harness.serveManifest(assets.map(\.0))
        for (entry, bytes) in assets {
            await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        }
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let entries = assets.map(\.0)
        let first = Task { await engine.awaitAsset(entries[0].identifier, lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.awaitCondition { $0.state.conditions != nil }
        let others = entries.dropFirst().map { entry in
            Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) }
        }
        await engine.waitUntil { $0.running + ($0.queued[.userInitiated] ?? 0) == 3 }
        await engine.waitForAllHandles()
        let state = await engine.introspect()
        let cap = harness.configuration.power.interactiveConcurrencyAtCritical
        #expect(cap < 3, "premise: the cap is below the three requests: \(cap)")
        #expect(state.running == cap, "running: \(state.running)")
        #expect(await harness.source.starts.count == cap)
        first.cancel()
        for waiter in others {
            waiter.cancel()
        }
        await engine.shutdown()
    }
}

extension EngineFailurePathTests {
    /// `ensureAvailable` over a scope with missing assets while the auth breaker is open throws `authRejected`, the
    /// UI-mappable error a rejected key needs, not `serverUnavailable`, and starts no transfer (R-CAR-7, R-NET-6;
    /// `unreachableError`; Stage 3, S3-CONF-05: a mutant that answered `serverUnavailable` passed every other test).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-7: ensureAvailable while the auth breaker is open throws authRejected for a scope with missing assets", .timeLimit(.minutes(1)))
    func ensureAvailableUnderAuthBreaker() async throws {
        let harness = EngineHarness.make()
        let entry = EngineHarness.onDemand("x", EngineFixture.bytes(4_501))
        await harness.serveManifest([entry])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        await harness.source.scriptManifest([.fail(.authentication(.forbiddenAmbiguous(EngineFailurePathTests.evidence(.manifest, xml: false, bytes: 0))))])
        let blocked = await harness.engine.sync(.force)
        guard case .blocked(.circuitOpen(.authentication), _) = blocked else {
            Issue.record("setup: expected the auth breaker open, got \(blocked)")
            await harness.engine.shutdown()
            return
        }
        let result = await harness.engine.ensureAvailable(scope: .identifiers(["x"]))
        #expect(result == .failure(.authRejected(.confirmed)), "\(result)")
        #expect(await harness.source.starts.isEmpty)
        await harness.engine.shutdown()
    }
}
