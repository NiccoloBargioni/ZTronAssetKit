import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The sync-2 regression tests ARCHITECTURE §12.4 names for S2-09, S2-10 and S2-01's `ensureAvailable` form (Stage 3,
/// S3-B-069).
extension EngineRegressionTests {
    /// The headroom ledger keeps the bytes committed since the last free-space read (sync-2 S2-09, §7.10): with 450 bytes
    /// of room above the reserve at the read, a 300-byte asset commits, and a second 300-byte asset is refused for lack
    /// of space (150 bytes left), although no transfer is in flight and the read itself showed room for it; admitting it
    /// would cross the reserve.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: committed bytes stay in the headroom ledger so the reserve is never crossed", .timeLimit(.minutes(1)))
    func committedBytesStayInTheLedger() async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 100_000, opportunisticCapacity: reserve + 100_000)
        )
        let harness = EngineHarness.make(time: time, fileSystem: fileSystem)
        let aBytes = EngineFixture.bytes(8_701, count: 300)
        let bBytes = EngineFixture.bytes(8_702, count: 300)
        let a = EngineHarness.onDemand("ledger-a", aBytes)
        let b = EngineHarness.onDemand("ledger-b", bBytes)
        try await EngineSingleFlightTests.applied([a, b], harness: harness)
        let engine = harness.engine
        try await harness.store.flush(.ordered)
        // 450 bytes of room above the reserve, read by the next run.
        let room = try await harness.store.freeSpace().volumeImportant - reserve
        try fileSystem.write(Data(repeating: 1, count: Int(room - 450)), to: EngineHarness.base.appendingPathComponent("ballast"), mode: .truncate)
        #expect(await engine.sync(.force).completeReport != nil)
        let read = await engine.readForTests { engine in engine.state.freeSpace.map { $0.volumeImportant - reserve } }
        #expect(read == 450, "the run read 450 bytes of room above the reserve: \(String(describing: read))")
        await harness.source.script(a.transferID, [.stage(aBytes)])
        await harness.source.script(b.transferID, [.stage(bBytes)])
        #expect((try? await engine.awaitAsset(a.identifier, lane: .userInitiated).get()) != nil, "a fits and commits")
        let committed = await engine.readForTests { ($0.state.committedSinceRead, $0.state.inFlightBytes.clamped) }
        #expect(committed.0 == Int64(aBytes.count) && committed.1 == 0, "a's bytes stay in the ledger with nothing in flight: \(committed)")
        let second = await engine.awaitAsset(b.identifier, lane: .userInitiated)
        guard case .failure(.insufficientSpace(let required, let available)) = second else {
            Issue.record("b is refused for lack of space beside a's committed bytes: \(second)")
            await engine.shutdown()
            return
        }
        #expect(required == Int64(bBytes.count), "the bytes b needs: \(required)")
        #expect(available <= 150, "the room the ledger leaves: \(available)")
        #expect(await harness.source.starts.map(\.id) == [a.transferID], "no transfer of b began")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// The pipeline cap gates non-user lanes only (sync-2 S2-10, §7.4): two bulk publications held at their first store
    /// unit fill a one-deep pipeline of two slots, so a third bulk job waits in the queue with both transfer slots free,
    /// while a user-initiated resolve starts its transfer at once.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a user-initiated job starts while bulk work fills the verify and commit pipeline", .timeLimit(.minutes(1)))
    func userJobStartsBesideAFullPipeline() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0, pipelineDepth: 1), bulk: bulk)
        let catalog = (0..<3).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(8_800 + UInt64(index))
            return (EngineFixture.entry("pipe-\(index)", bytes), bytes)
        }
        let uBytes = EngineFixture.bytes(8_810)
        let u = EngineHarness.onDemand("pipe-user", uBytes)
        await harness.serveManifest(catalog.map(\.0) + [u])
        for (entry, bytes) in catalog {
            await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        }
        await harness.source.script(u.transferID, [.stage(uBytes)])
        try await harness.start()
        let engine = harness.engine
        let run = Task { await engine.sync(.force) }
        let first = catalog[0].0.transferID
        let second = catalog[1].0.transferID
        let third = catalog[2].0.transferID
        await engine.awaitCondition { engine in
            engine.state.jobs[first]?.state == .downloading && engine.state.jobs[second]?.state == .downloading && engine.state.jobs[third]?.state == .queued
        }
        await engine.waitForAllHandles()
        // Both bulk transfers stage; their publications are held at their first store unit and fill the pipeline.
        await bulk.setHolding(true)
        await harness.source.release(first, with: .progress(received: 0, expected: nil))
        await harness.source.release(second, with: .progress(received: 0, expected: nil))
        await bulk.waitForHeldUnits(atLeast: 2)
        await engine.awaitCondition { $0.state.jobs[first]?.state == .verifying && $0.state.jobs[second]?.state == .verifying }
        #expect(await engine.readForTests { $0.state.jobs[third]?.state } == .queued, "the third bulk job waits for the pipeline")
        let waiter = Task { await engine.awaitAsset(u.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[u.transferID] != nil && $0.state.jobs[u.transferID]?.state != .queued }
        let starts = await harness.source.starts.map(\.id)
        #expect(starts.contains(u.transferID), "the user-initiated transfer started beside the full pipeline: \(starts)")
        #expect(!starts.contains(third), "the third bulk transfer did not")
        #expect(await engine.readForTests { $0.state.jobs[third]?.state } == .queued)
        await bulk.setHolding(false)
        await bulk.releaseAll()
        #expect((try? await EngineHarness.value(of: waiter).get()) != nil, "the user's asset is delivered")
        await harness.source.release(third, with: .progress(received: 0, expected: nil))
        let outcome = await EngineHarness.value(of: run)
        #expect(outcome.completeReport?.fetched == catalog.count, "\(outcome)")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// `ensureAvailable` completes after the breaker recovers from an abandoned probe (sync-2 S2-01; ADR-031's total probe
    /// resolution): an ambiguous 403 opens the authentication breaker; at the cooldown's end a prefetch member probes it
    /// and its group is released, which abandons the probe (`halfOpen(probe: nil)`, §7.7). An `ensureAvailable` then gets
    /// the next probe: its member stages, the breaker closes, and the ensure completes. A probe left in place after it was
    /// abandoned rejected the ensure's member until that probe's watchdog.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: ensureAvailable completes after a breaker recovers from an abandoned probe", .timeLimit(.minutes(1)))
    func ensureCompletesAfterAbandonedProbe() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(reservedInteractiveSlots: 0, breaker: CircuitBreakerPolicy(authDistinctAssets: 1)))
        let opener = EngineHarness.onDemand("abandon-opener", EngineFixture.bytes(8_901))
        let probe = EngineHarness.onDemand("abandon-probe", EngineFixture.bytes(8_902))
        let eBytes = EngineFixture.bytes(8_903)
        let ensured = EngineHarness.onDemand("abandon-ensured", eBytes)
        try await EngineSingleFlightTests.applied([opener, probe, ensured], harness: harness)
        let engine = harness.engine
        let origin = harness.source.originID
        await harness.source.script(opener.transferID, [.fail(EngineRegressionCycle20Tests.forbidden)])
        let openerGroup = try await engine.registerGroup([opener.identifier], lane: .prefetch).get()
        await engine.awaitCondition { engine in
            if case .open? = engine.state.breakers[origin]?.state {
                return engine.state.jobs[opener.transferID] == nil || engine.state.jobs[opener.transferID]?.state.kind == .failed
            }
            return false
        }
        guard case .open(_, let cooldownEnd, _)? = await engine.readForTests({ $0.state.breakers[origin]?.state }) else {
            Issue.record("setup: the 403 opened the breaker")
            await engine.shutdown()
            return
        }
        Self.land(harness.time, on: cooldownEnd)
        // The probe member's transfer takes the half-open probe and waits unanswered.
        let probeGroup = try await engine.registerGroup([probe.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.breakers[origin]?.probe == probe.transferID }
        await engine.waitForHandle(probe.transferID)
        // Its group is released: the probe is abandoned and the breaker admits the next transfer as its probe.
        await engine.releaseGroup(probeGroup)
        await engine.awaitCondition { engine in
            if case .halfOpen(_, _, nil, _)? = engine.state.breakers[origin]?.state {
                return engine.state.jobs[probe.transferID] == nil
            }
            return false
        }
        await harness.source.script(ensured.transferID, [.stage(eBytes)])
        let result = await engine.ensureAvailable(scope: .identifiers([ensured.identifier]))
        guard case .success(let report) = result else {
            Issue.record("the ensure completes after the abandoned probe: \(result)")
            await engine.shutdown()
            return
        }
        #expect(report.isComplete && report.present == 1, "\(report)")
        #expect(await engine.readForTests { $0.state.breakers[origin]?.state } == .closed, "the ensure's member was the probe and closed the breaker")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.releaseGroup(openerGroup)
        await engine.shutdown()
    }
}
