import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Regressions the level-4 close-out verifiers found in WP-F (cycle 1 of the close-out). Each regression test failed
/// before its fix (`docs/adr-drafts/f.md`, F-22).
@Suite("Engine regressions, close-out")
struct EngineRegressionCloseOutTests {
    // MARK: The binding ledger after a store mutation that throws (L4-R5, L4-R10, ADR-050)

    /// A run holding `h` mid-transfer keeps the engine's binding ledger whole after it committed `z`; the volume is then
    /// filled so that `w` (500 bytes) needs `z` (300 bytes) evicted. Returns the harness, the run, the entries and their
    /// bytes. `minimumResidency: 0` makes a freshly bound asset an eviction victim at once.
    @available(macOS 15.0, iOS 18.0, *)
    static func boundThenCrowded(
        _ seed: UInt64
    ) async throws -> (harness: EngineHarness, run: Task<SyncOutcome, Never>, z: ManifestEntry, h: ManifestEntry, zBytes: Data) {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 100_000, opportunisticCapacity: reserve + 100_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 0), fileSystem: fileSystem)
        let zBytes = EngineFixture.bytes(seed, count: 300)
        let hBytes = EngineFixture.bytes(seed + 1, count: 300)
        let wBytes = EngineFixture.bytes(seed + 2, count: 500)
        let z = EngineFixture.entry("z", zBytes)
        let h = EngineFixture.entry("h", hBytes)
        let w = EngineHarness.onDemand("w", wBytes)
        await harness.serveManifest([z, h, w])
        await harness.source.script(z.transferID, [.stage(zBytes), .stage(zBytes)])
        await harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        await harness.source.script(w.transferID, [.stage(wBytes)])
        try await harness.start()
        let engine = harness.engine
        let run = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.boundContent["z"] != nil && $0.state.run?.transferring == true }
        await engine.waitForHandle(h.transferID)
        try await harness.store.flush(.ordered)
        // 450 bytes of room above the reserve: w (500) needs z (300) evicted.
        let room = try await harness.store.freeSpace().volumeImportant - reserve
        try fileSystem.write(Data(repeating: 1, count: Int(room - 450)), to: EngineHarness.base.appendingPathComponent("ballast"), mode: .truncate)
        return (harness, run, z, h, zBytes)
    }

    /// Review of close-out cycle 1 (PROBE-C1-N1): the store's `apply` evicted `z` in memory and then threw (its index
    /// commit failed, ADR-050), so the engine never saw the eviction; its ledger, kept whole by the run, still bound `z`,
    /// and a later `ensureAvailable([z])` counted `z` done without a job while the store held it absent.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: ensureAvailable downloads a member that an apply evicted before it threw", .timeLimit(.minutes(1)))
    func ensureAfterFailedEvictingApply() async throws {
        let (harness, run, z, h, zBytes) = try await EngineRegressionCloseOutTests.boundThenCrowded(9_501)
        let engine = harness.engine
        // The index commit of the ensure's apply fails once, after the apply's in-memory writes (the eviction included).
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .io))
        let first = await engine.ensureAvailable(scope: .identifiers(["w"]))
        guard case .failure(.storageUnavailable) = first else {
            Issue.record("the apply's failed index commit fails the ensure: \(first)")
            await harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
            _ = await run.value
            await engine.shutdown()
            return
        }
        let evicted = try #require(try await harness.view().records["z"])
        #expect(evicted.referencedBlob == nil, "the store evicted z in memory: \(evicted.residency)")
        let second = await harness.withClock { await engine.ensureAvailable(scope: .identifiers(["z"])) }
        #expect((try? second.get())?.present == 1, "z is downloaded again: \(second)")
        #expect(await harness.source.starts.filter { $0.id == z.transferID }.count == 2, "the run's download and the ensure's")
        let record = try #require(try await harness.view().records["z"])
        #expect(record.referencedBlob != nil, "z is present: \(record.residency)")
        let location = try #require(await harness.store.location(for: "z", extensions: [], recordingAccess: false))
        #expect(try harness.fileSystem.read(from: location.url, offset: 0, maxLength: zBytes.count + 1) == zBytes)
        #expect(await engine.invariantViolations().isEmpty)
        await harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        _ = await run.value
        await engine.shutdown()
    }

    /// Found while fixing PROBE-C1-N1: a run's `apply` that wrote its manifest in memory and then threw left the engine's
    /// copy behind the store's until some later publication was superseded, so the ids it pruned were never announced
    /// (a re-apply of the same manifest prunes nothing). The engine now re-reads the store once no `apply` is in flight.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: after a run's apply throws past its in-memory writes, the engine follows the store and announces its prunes", .timeLimit(.minutes(1)))
    func failedApplyIsFollowed() async throws {
        let harness = EngineHarness.make()
        let xBytes = EngineFixture.bytes(9_601)
        let zBytes = EngineFixture.bytes(9_602)
        let x = EngineFixture.entry("x", xBytes)
        let z = EngineFixture.entry("z", zBytes)
        await harness.serveManifest([x, z])
        await harness.scriptTransfers([(x, xBytes), (z, zBytes)])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        let probe = EventProbe(stream: try await engine.subscribe().get())
        // v2 drops z; the index commit of its apply fails once, after the store's in-memory writes.
        await harness.serveManifest([x])
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .io))
        let outcome = await engine.sync(.force)
        guard case .failed(.storageUnavailable) = outcome else {
            Issue.record("the failed index commit fails the run: \(outcome)")
            await probe.stop()
            await engine.shutdown()
            return
        }
        let view = try await harness.view()
        #expect(view.appliedManifest.entry(for: "z") == nil, "the store applied v2 in memory")
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.catchUpAfterFailedApply }
        #expect(await engine.appliedEntryForTests("z") == nil, "the engine follows the store's manifest")
        await engine.shutdown()
        _ = await probe.next { $0 == .clientShutDown }
        let received = await probe.received
        let removal = received.firstIndex(of: .assetRemoved("z", .pruned))
        #expect(removal != nil, "z left the manifest the engine follows: \(received)")
        #expect(received.contains(.snapshotChanged(generation: view.generation)), "the store's generation is announced: \(received)")
        await probe.stop()
    }

    // MARK: Diagnostics while the store cannot answer (L4-R9)

    /// Review of close-out cycle 1 (by reading): the last-known generation was taken only from the open report and from
    /// views diagnostics read, so after the engine applied manifests a store that could not answer made diagnostics
    /// report a generation older than the one subscribers had already seen.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-OBS-3: diagnostics never report a generation older than the engine announced when the store cannot answer", .timeLimit(.minutes(1)))
    func diagnosticsGenerationNeverLags() async throws {
        let harness = EngineHarness.make()
        let xBytes = EngineFixture.bytes(9_701)
        let x = EngineFixture.entry("x", xBytes)
        await harness.serveManifest([x])
        await harness.scriptTransfers([(x, xBytes)])
        try await harness.start()
        let engine = harness.engine
        let probe = EventProbe(stream: try await engine.subscribe().get())
        _ = try #require(await engine.sync(.force).completeReport)
        // Events arrive in order: once the run's finish is received, so is every generation its apply announced.
        _ = await probe.next { event in
            if case .syncFinished = event {
                return true
            }
            return false
        }
        let announced = await probe.received.compactMap { event -> UInt64? in
            if case .snapshotChanged(let generation) = event {
                return generation
            }
            return nil
        }.max()
        let newest = try #require(announced, "the run's apply announced a generation")
        // The store stops answering (its planning view throws): diagnostics fall back to the last-known figures.
        await harness.store.close()
        let report = try await engine.diagnostics().get()
        #expect(report.indexGeneration >= newest, "announced \(newest), diagnosed \(report.indexGeneration)")
        await probe.stop()
        await engine.shutdown()
    }
}

extension SyncEngine {
    /// Test seam: the engine's copy of the applied manifest's entry for `id`.
    func appliedEntryForTests(_ id: AssetID) -> ManifestEntry? {
        self.state.applied.entry(for: id)
    }
}
