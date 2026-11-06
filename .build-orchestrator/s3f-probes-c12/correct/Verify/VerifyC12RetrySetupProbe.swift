import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// A gate armed by the probe: the next observation the engine starts waits for `release()`.
@available(macOS 15.0, iOS 18.0, *)
actor VerifyC12ArmedGate {
    private var armed = false
    private var gate: CheckedContinuation<Void, Never>?
    func arm() { self.armed = true }
    var holding: Bool { self.gate != nil }
    func pass() async {
        guard self.armed else { return }
        self.armed = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in self.gate = continuation }
    }
    func release() { self.gate?.resume(); self.gate = nil }
}

@available(macOS 15.0, iOS 18.0, *)
struct VerifyC12GatedConditions: DeviceConditionsSource {
    let base: FakeDeviceConditionsSource
    let gate: VerifyC12ArmedGate
    func conditions() async -> AsyncStream<DeviceConditions> {
        await self.gate.pass()
        return await self.base.conditions()
    }
}

@Suite("VerifyC12RetrySetupProbe", .serialized)
struct VerifyC12RetrySetupProbe {
    /// PROBE-C12-RETRY-SETUP-RACE: `barrierRetriesBehindTheOwedVisitsPlaces`'s own setup (30c2a39), with the watcher's
    /// first reading delivered after R's 500 instead of before it (an interleaving the full bundle produced under load:
    /// the test timed out 180 s in both orders, then `#require(backoffEnd)` failed at ReplayTests:141). A satisfied first
    /// reading is an edge (S3-CONC-04): it re-queues R's transient failure, R starts again on its `.hold` step and keeps
    /// the one slot, so the test's next wait (H downloading) can never hold.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C12-RETRY-SETUP-RACE", .timeLimit(.minutes(1)))
    func retrySetupRace() async throws {
        let gate = VerifyC12ArmedGate()
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let harness = EngineHarness.make(
            time: time, tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0),
            storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem,
            conditionsWrapper: { VerifyC12GatedConditions(base: $0, gate: gate) }
        )
        let qBytes = EngineFixture.bytes(992_402, count: 300)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([q])
        await harness.scriptTransfers([(q, qBytes)])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let rBytes = EngineFixture.bytes(992_410, count: 16)
        let hBytes = EngineFixture.bytes(992_411, count: 16)
        let r = EngineHarness.onDemand("zz-r", rBytes)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        await harness.serveManifest([q, h, r], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        await harness.source.script(r.transferID, [.fail(.transient(.serverError(httpStatus: 500), retryAfter: nil)), .hold, .stage(rBytes)])
        await harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        // Idle: no watcher, no reading. The next observation waits for the gate.
        await engine.awaitCondition { $0.state.watcher == nil && $0.state.conditions == nil }
        await gate.arm()
        let rWaiter = Task { await engine.awaitAsset(r.identifier, lane: .userInitiated) }
        await engine.awaitCondition { e in
            if case .failed(.at) = e.state.jobs[r.transferID]?.state { return true }
            return false
        }
        let before = await engine.readForTests { e in (r: e.state.jobs[r.transferID]?.state, conditions: e.state.conditions != nil) }
        print("PROBE-C12-RETRY-SETUP-RACE before the reading: \(before)")
        // The first reading arrives after R's failure.
        await gate.release()
        await engine.awaitCondition { $0.state.conditions != nil }
        await engine.awaitCondition { $0.state.jobs[r.transferID]?.state != .queued }
        let after = await engine.readForTests { e in e.state.jobs[r.transferID]?.state }
        print("PROBE-C12-RETRY-SETUP-RACE after the reading: R=\(String(describing: after))")
        var stillAt = false
        if case .failed(.at)? = after { stillAt = true }
        #expect(stillAt, "the test's setup assumes R keeps waiting for its backoff; the first reading's edge re-queued it: \(String(describing: after))")
        let hWaiter = Task { await engine.awaitAsset(h.identifier, lane: .userInitiated) }
        // The test's next wait, bounded here by the probe's own 1-minute limit.
        await engine.awaitCondition { $0.state.jobs[h.transferID]?.state == .downloading }
        await harness.source.release(r.transferID, with: .progress(received: 0, expected: nil))
        await harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: rWaiter) }
        _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: hWaiter) }
        await engine.shutdown()
    }
}
