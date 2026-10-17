import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The engine over the store's availability, space, scope, cleanup and reports (R-SYN-10, R-SYN-11, R-SYN-16,
/// R-CAR-5, R-CLN-5, R-CLN-8, R-CLN-9, R-CLN-10).
@Suite("Engine and store")
struct EngineStoreTests {
    static let packSource = RemoteSourceCapabilities(tier: .appleHosted, supportsPriority: false, supportsResume: false, supportsBackground: false, keepsSourceCopies: true)

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: availability counts present, missing, stale and failed without any network request", .timeLimit(.minutes(1)))
    func availabilityCounts() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(4)
        let gone = catalog[3].0
        await harness.source.script(gone.transferID, [.fail(.permanentMissing(httpStatus: 404))])
        await harness.serve(catalog)
        try await harness.start()
        _ = await harness.engine.sync(.force)
        var changed = catalog[0].0
        changed.checksum = ContentHash.sha256(of: EngineFixture.bytes(77))
        let added = EngineFixture.entry("added", EngineFixture.bytes(78))
        await harness.serveManifest([changed, catalog[1].0, catalog[2].0, gone, added], etag: "v2")
        await harness.source.script(changed.transferID, [.fail(.offline(.noConnection))])
        await harness.source.script(added.transferID, [.fail(.offline(.noConnection))])
        _ = await harness.engine.sync(.force)
        let requests = await harness.source.manifestRequests.count
        let starts = await harness.source.starts.count
        let report = try await harness.engine.availability(scope: .all).get()
        #expect(report.total == 5)
        #expect(report.present == 2)
        #expect(report.stale == 1)
        #expect(report.missing == 1)
        #expect(report.failed == 1)
        #expect(!report.isComplete)
        #expect(!report.manifestFresh)
        #expect(await harness.source.manifestRequests.count == requests)
        #expect(await harness.source.starts.count == starts)
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a plan that cannot fit even after eviction fails with insufficientSpace and leaves index, blobs and staging byte-identical", .timeLimit(.minutes(1)))
    func insufficientSpaceHasNoSideEffect() async throws {
        let storage = StoragePolicy(budget: .bytes(1_000), reserveFreeBytes: 0)
        let harness = EngineHarness.make(storage: storage)
        let small = EngineFixture.bytes(51, count: 300)
        let first = EngineFixture.entry("small", small)
        await harness.serve([(first, small)])
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        try await harness.settle()
        let large = EngineFixture.bytes(52, count: 2_000)
        let second = EngineFixture.entry("large", large)
        await harness.serve([(first, small), (second, large)], etag: "v2")
        let before = harness.fileSystem.survivingDisk().digest()
        let mutations = harness.fileSystem.mutationCount
        let outcome = await harness.engine.sync(.force)
        guard case .failed(.insufficientSpace(let required, _)) = outcome else {
            Issue.record("expected insufficientSpace, got \(outcome)")
            return
        }
        #expect(required == 2_000)
        #expect(harness.fileSystem.survivingDisk().digest() == before)
        #expect(harness.fileSystem.mutationCount == mutations, "no mutating call at all")
        #expect(await harness.source.starts.map(\.id) == [first.transferID])
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: with eviction not permitted a run that does not fit evicts nothing", .timeLimit(.minutes(1)))
    func evictionNotPermitted() async throws {
        func run(permitted: Bool) async throws -> (SyncOutcome, StorePlanningView) {
            let storage = StoragePolicy(budget: .bytes(1_000), reserveFreeBytes: 0, minimumResidency: 0, admitLargestFittingPrefix: false, evictionPermitted: permitted)
            let harness = EngineHarness.make(storage: storage)
            let oldBytes = EngineFixture.bytes(53, count: 600)
            let old = EngineFixture.entry("old", oldBytes)
            await harness.serve([(old, oldBytes)])
            try await harness.start()
            _ = try #require(await harness.engine.sync(.force).completeReport)
            harness.time.advance(by: 120)
            let newBytes = EngineFixture.bytes(54, count: 600)
            let new = EngineFixture.entry("new", newBytes)
            await harness.serve([(old, oldBytes), (new, newBytes)], etag: "v2")
            let outcome = await harness.engine.sync(.force)
            let view = try await harness.view()
            await harness.engine.shutdown()
            return (outcome, view)
        }
        let (refused, kept) = try await run(permitted: false)
        guard case .failed(.insufficientSpace) = refused else {
            Issue.record("expected insufficientSpace, got \(refused)")
            return
        }
        #expect(kept.records["old"]?.referencedBlob != nil, "nothing was evicted")
        let (allowed, evicted) = try await run(permitted: true)
        #expect(allowed.completeReport?.evicted == 1, "the same run evicts when permitted: \(allowed)")
        #expect(evicted.records["old"]?.residency == .absent(.evicted))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-5: identifier, tag and prefix scopes select the same entries in planning and availability", .timeLimit(.minutes(1)))
    func scopesAgree() async throws {
        let harness = EngineHarness.make(retentionScope: .identifiers([]))
        let entries = [
            EngineFixture.entry("bo7.ri.one", EngineFixture.bytes(61), tags: ["x"]),
            EngineFixture.entry("bo7.ri.two", EngineFixture.bytes(62), tags: ["y"]),
            EngineFixture.entry("bo6.one", EngineFixture.bytes(63), tags: ["x", "z"]),
            EngineFixture.entry("other", EngineFixture.bytes(64)),
        ]
        await harness.serveManifest(entries)
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        #expect(await harness.source.starts.isEmpty, "an empty retention scope fetches nothing")
        let view = try await harness.view()
        let space = PlanFixture.space()
        for scope: AssetScope in [.identifiers(["bo7.ri.two", "other"]), .tags(["x"]), .prefix("bo7.ri."), .all] {
            let report = try await harness.engine.availability(scope: scope).get()
            let plan = SyncPlanner.plan(manifest: view.appliedManifest, snapshot: view, scope: scope, policy: PlanFixture.policy(onDemand: scope.isExplicit), freeSpace: space)
            let selected = entries.filter { scope.contains($0) }.map(\.identifier)
            #expect(report.total == selected.count, "\(scope)")
            #expect(report.missing == selected.count, "\(scope)")
            #expect(plan.fetches.map(\.id) == selected, "\(scope)")
        }
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-5: the retention scope bounds bulk runs and evicts excluded entries first without deleting anything by itself", .timeLimit(.minutes(1)))
    func retentionScopeBoundsRunsAndEviction() async throws {
        let time = ManualTimeSource()
        let kept = (0..<2).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(UInt64(70 + index), count: 100)
            return (EngineFixture.entry("k\(index)", bytes, tags: ["kept"]), bytes)
        }
        let other = (0..<2).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(UInt64(80 + index), count: 100)
            return (EngineFixture.entry("x\(index)", bytes), bytes)
        }
        let first = EngineHarness.make(time: time, retentionScope: .tags(["kept"]))
        await first.serve(kept + other)
        try await first.start()
        _ = try #require(await first.engine.sync(.force).completeReport)
        // Compared as a set: the fake records each start when the attempt's driver task reaches it, and the run's two
        // drivers race there (no order is asserted by this requirement).
        let keptStarts = await first.source.starts.map(\.id)
        #expect(keptStarts.count == kept.count && Set(keptStarts) == Set(kept.map(\.0.transferID)), "bulk runs stay inside the retention scope: \(keptStarts)")
        try await first.engine.setRetentionScope(.all).get()
        _ = try #require(await first.engine.sync(.force).completeReport)
        #expect(await first.source.starts.count == 4)
        await first.engine.shutdown()

        time.advance(by: 3_600)
        let storage = StoragePolicy(budget: .bytes(300), reserveFreeBytes: 0, minimumResidency: 0)
        let second = EngineHarness.make(disk: first.fileSystem.survivingDisk(), time: time, storage: storage)
        try await second.start()
        let digest = second.fileSystem.survivingDisk().digest()
        try await second.engine.setRetentionScope(.tags(["kept"])).get()
        #expect(second.fileSystem.survivingDisk().digest() == digest, "setting the scope deletes nothing")
        #expect(await second.source.starts.isEmpty, "and fetches nothing")
        let report = try await second.engine.performMaintenance(timeBudget: 10).get()
        #expect(report.evictedBytes == 200)
        let view = try await second.view()
        #expect(view.records["x0"]?.residency == .absent(.evicted) && view.records["x1"]?.residency == .absent(.evicted))
        #expect(view.records["k0"]?.referencedBlob != nil && view.records["k1"]?.referencedBlob != nil)
        await second.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-5: every URL handed out stays readable for at least the grace window", .timeLimit(.minutes(1)))
    func urlsOutliveTheirGrace() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(2)
        await harness.serve(catalog)
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        let location = try await harness.engine.awaitAsset("a0", lane: .userInitiated).get()
        await harness.serveManifest([catalog[1].0], etag: "v2")
        _ = try #require(await harness.engine.sync(.force).completeReport)
        let grace = harness.configuration.storage.deletionGrace
        var elapsed: TimeInterval = 0
        while elapsed + 1 < grace {
            harness.time.advance(by: 1)
            elapsed += 1
            await harness.engine.waitUntil { $0.jobsByState.isEmpty }
            #expect(try harness.fileSystem.itemInfo(at: location.url) != nil, "readable \(elapsed) s after the prune")
        }
        try await harness.settle()
        #expect(try harness.fileSystem.itemInfo(at: location.url) == nil, "deleted once the grace passed")
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-8: the engine re-downloads an asset reportUnreadable quarantined", .timeLimit(.minutes(1)))
    func healsAfterQuarantine() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(91)
        let entry = EngineFixture.entry("broken", bytes)
        await harness.serve([(entry, bytes)])
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        await harness.source.script(entry.transferID, [.stage(bytes)])
        try await harness.engine.reportUnreadable("broken").get()
        guard case .quarantined? = try await harness.view().records["broken"]?.residency else {
            Issue.record("expected a quarantined record")
            return
        }
        #expect(await harness.engine.awaitAsset("broken", lane: .userInitiated) == .failure(.integrityFailure), "never fetched before the quarantine ends")
        #expect(await harness.source.starts.count == 1)
        try await harness.settle()
        #expect(await harness.source.starts.count == 2, "re-downloaded once the quarantine ended")
        #expect(try await harness.view().records["broken"]?.referencedBlob != nil)
        #expect(try await harness.engine.awaitAsset("broken", lane: .userInitiated).get().byteSize == Int64(bytes.count))
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-9: storageReport counts bytes the OS still holds in adopted packs", .timeLimit(.minutes(1)))
    func storageReportAddsSourceCopies() async throws {
        let source = FakeRemoteSource(originID: "apple-hosted", capabilities: EngineStoreTests.packSource)
        let harness = EngineHarness.make(source: source)
        await harness.serve(EngineSyncTests.catalog(2))
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        await source.setSourceCopyBytes(4_096)
        let report = try await harness.engine.storageReport().get()
        let stored = await harness.store.storageReport()
        #expect(report.sourceCopyBytes == 4_096)
        #expect(stored.sourceCopyBytes == 0)
        #expect(report.bytesByState == stored.bytesByState)
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-9: after a relaunch the engine reclaims source copies before its first storageReport, so a fresh source counts the bytes of adopted packs", .timeLimit(.minutes(1)))
    func relaunchReclaimsBeforeReport() async throws {
        let time = ManualTimeSource()
        let first = FakeRemoteSource(originID: "apple-hosted", capabilities: EngineStoreTests.packSource)
        let harness = EngineHarness.make(time: time, source: first)
        let catalog = EngineSyncTests.catalog(2)
        await harness.serve(catalog)
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        await harness.engine.shutdown()

        let fresh = FakeRemoteSource(originID: "apple-hosted", capabilities: EngineStoreTests.packSource)
        await fresh.setSourceCopyBytes(777)
        let relaunched = EngineHarness.make(disk: harness.fileSystem.survivingDisk(), time: time, source: fresh)
        try await relaunched.start()
        let reports = await fresh.reclaimReports
        #expect(reports.count == 1, "reclaimed during start, before any report")
        #expect(reports.first?.adoptedRemotePaths == Set(catalog.map(\.0.remotePath)))
        #expect(try await relaunched.engine.storageReport().get().sourceCopyBytes == 777)
        await relaunched.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-10: entries outside the retention scope never block a pack release", .timeLimit(.minutes(1)))
    func excludedEntriesNeverBlockRelease() async throws {
        let source = FakeRemoteSource(originID: "apple-hosted", capabilities: EngineStoreTests.packSource)
        let harness = EngineHarness.make(source: source, retentionScope: .tags(["kept"]))
        let keptBytes = EngineFixture.bytes(92)
        let kept = EngineFixture.entry("kept", keptBytes, tags: ["kept"])
        let excluded = EngineFixture.entry("excluded", EngineFixture.bytes(93))
        await harness.serve([(kept, keptBytes), (excluded, EngineFixture.bytes(93))])
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        try await harness.settle()
        let report = try #require(await source.reclaimReports.last)
        #expect(report.adoptedRemotePaths == [kept.remotePath])
        #expect(report.excludedRemotePaths == [excluded.remotePath])
        #expect(report.manifestRemotePaths.sorted() == [excluded.remotePath, kept.remotePath].sorted())
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-16: maintenance stops at its time budget on ManualTimeSource and resumes verification where it stopped", .timeLimit(.minutes(1)))
    func maintenanceResumesVerification() async throws {
        let harness = EngineHarness.make()
        let catalog = (0..<5).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(UInt64(120 + index), count: 300)
            return (EngineFixture.entry("m\(index)", bytes), bytes)
        }
        await harness.serve(catalog)
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        // A budget worth 700 bytes of hashing: each slice verifies two 300-byte blobs.
        let budget = 700 / MaintenanceBudget.verificationBytesPerSecond
        let first = try await harness.engine.performMaintenance(timeBudget: budget).get()
        #expect(first.verifiedBytes == 600)
        #expect(first.budgetExhausted)
        let second = try await harness.engine.performMaintenance(timeBudget: budget).get()
        #expect(second.verifiedBytes == 600)
        #expect(second.budgetExhausted)
        let third = try await harness.engine.performMaintenance(timeBudget: budget).get()
        #expect(third.verifiedBytes == 300, "the pass resumed where it stopped and verified the last blob")
        #expect(!third.budgetExhausted)
        #expect(third.corruptFound == 0)
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-16: maintenance stops between steps once its deadline passed", .timeLimit(.minutes(1)))
    func maintenanceStopsAtDeadline() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(metadata: metadata)
        await harness.serve(EngineSyncTests.catalog(2))
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        try await harness.settle()
        await metadata.setHolding(true)
        let engine = harness.engine
        let maintenance = Task { await engine.performMaintenance(timeBudget: 5) }
        try await metadata.requireHeldUnits(atLeast: 1)
        harness.time.advance(by: 6)
        await metadata.setHolding(false)
        await metadata.releaseAll()
        let report = try await maintenance.value.get()
        #expect(report.budgetExhausted)
        #expect(report.verifiedBytes == 0, "verification never started after the deadline")
        await engine.shutdown()
    }
}
