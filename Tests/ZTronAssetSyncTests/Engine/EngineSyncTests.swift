import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Runs end to end over the real store (R-NET-1, R-SYN-6, R-SYN-8, R-SYN-9, R-NET-6).
@Suite("Engine runs")
struct EngineSyncTests {
    @available(macOS 15.0, iOS 18.0, *)
    static func catalog(_ count: Int, prefix: String = "a", seed: UInt64 = 1) -> [(ManifestEntry, Data)] {
        (0..<count).map { index in
            let bytes = EngineFixture.bytes(seed &+ UInt64(index), count: 64 + index % 7)
            return (EngineFixture.entry("\(prefix)\(index)", bytes), bytes)
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-1: the engine completes a sync against FakeRemoteSource with no network", .timeLimit(.minutes(1)))
    func completesAgainstFakeSource() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(3)
        await harness.serve(catalog)
        // The launch run's own outcome, whether or not a `sync` call would have joined it (L4-R17).
        let outcome = try await harness.startAndAwaitLaunchRun()
        guard case .complete(let report) = outcome else {
            Issue.record("expected complete, got \(outcome)")
            return
        }
        #expect(report.fetched == 3)
        #expect(report.manifestFresh)
        #expect(report.failures.isEmpty)
        for (entry, bytes) in catalog {
            let location = try await harness.engine.awaitAsset(entry.identifier, lane: .userInitiated).get()
            #expect(location.url.path.contains("/blobs/"))
            #expect(location.byteSize == Int64(bytes.count))
        }
        #expect(await harness.source.starts.count == 3)
        #expect(try await harness.engine.metrics().get().illegalTransitions == 0)
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-8: reconcile is committed before the first transfer starts", .timeLimit(.minutes(1)))
    func reconcileBeforeTransfer() async throws {
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: 64 << 30, opportunisticCapacity: 64 << 30)
        )
        let base = FakeRemoteSource()
        // The source stamps each transfer's start with the file-system operation count at that moment.
        let stamping = OperationStampingSource(base: base, fileSystem: fileSystem)
        let bulk = NextUnitGate()
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(time: time, source: base, metadata: metadata, bulk: bulk, fileSystem: fileSystem, remote: stamping)
        let kept = EngineSyncTests.catalog(2)
        await harness.serve(kept)
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        // A directory change for one asset, and one new asset whose transfer is held.
        var moved = kept[0].0
        moved.localPathComponents = ["elsewhere"]
        let added = EngineFixture.entry("new", EngineFixture.bytes(99))
        let manifest = [moved, kept[1].0, added]
        await harness.serveManifest(manifest, etag: "v2")
        await harness.source.script(added.transferID, [.hold])
        let before = fileSystem.operations.count
        // The run's apply is held inside the store, first at its planning unit (after the manifest's decode on the same
        // executor), then at its commit: while it is held, nothing may start, whatever the scheduling (a mutant that
        // dispatches before `apply` fails here every time).
        await bulk.holdNext(skipping: 1)
        let run = Task { await harness.engine.sync(.force) }
        await bulk.waitForHold()
        await metadata.setHolding(true)
        await bulk.release()
        try await metadata.requireHeldUnits(atLeast: 1)
        #expect(await stamping.stamps[added.transferID] == nil, "a transfer started while the store applied the manifest")
        #expect(await harness.source.starts.count == 2, "only the first sync's transfers have started")
        await metadata.setHolding(false)
        await metadata.releaseAll()
        await harness.engine.waitUntil { $0.running == 1 }
        await harness.engine.waitForHandle(added.transferID)
        // The order itself: the index generation holding v2 was renamed into place before the transfer started.
        let started = try #require(await stamping.stamps[added.transferID])
        let operations = fileSystem.operations
        #expect(started > before)
        let commits = operations[before..<max(before, started)].filter { $0.kind == .rename && $0.destination?.lastPathComponent == "index.bin" }
        #expect(!commits.isEmpty, "no index commit lies between the run's start and the first transfer's start")
        let view = try await harness.view()
        #expect(view.appliedManifest.entries == manifest, "the new manifest is committed while the first transfer runs")
        #expect(view.records["a0"]?.entry.localPathComponents == ["elsewhere"])
        let starts = await harness.source.starts.map(\.id)
        #expect(Set(starts.prefix(2)) == Set(kept.map(\.0.transferID)))
        #expect(starts.last == added.transferID && starts.count == 3)
        await harness.source.release(added.transferID, with: .failed(.offline(.noConnection)))
        _ = await run.value
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-8: a metadata-only manifest change completes the run and writes the stamp", .timeLimit(.minutes(1)))
    func metadataOnlyRunCompletes() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(4)
        await harness.serve(catalog)
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        let starts = await harness.source.starts.count
        let moved = catalog.map { pair -> ManifestEntry in
            var entry = pair.0
            entry.localPathComponents = ["v2", "dir"]
            entry.localFileName = "renamed"
            return entry
        }
        await harness.serveManifest(moved, etag: "v2")
        let report = try #require(await harness.engine.sync(.force).completeReport)
        #expect(report.relocated == 4)
        #expect(report.fetched == 0)
        #expect(await harness.source.starts.count == starts, "zero downloads")
        let view = try await harness.view()
        #expect(view.stamp?.manifestDigest == view.appliedManifest.digest)
        #expect(view.stamp?.manifestETag == EngineFixture.etag("v2"))
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-9: the stamp is stored in the index and written only after a complete run", .timeLimit(.minutes(1)))
    func stampOnlyAfterCompleteRun() async throws {
        let time = ManualTimeSource()
        let harness = EngineHarness.make(time: time)
        let good = EngineSyncTests.catalog(2)
        let missing = EngineFixture.entry("missing", EngineFixture.bytes(42))
        await harness.scriptTransfers(good)
        await harness.source.script(missing.transferID, [.fail(.permanentMissing(httpStatus: 404))])
        await harness.serveManifest(good.map(\.0) + [missing])
        try await harness.start()
        let first = await harness.engine.sync(.force)
        guard case .completeWithFailures = first else {
            Issue.record("expected completeWithFailures, got \(first)")
            return
        }
        #expect(try await harness.engine.lastSyncedAt().get() == nil)
        #expect(try await harness.engine.isSyncDue().get())
        await harness.serveManifest(good.map(\.0), etag: "v2")
        _ = try #require(await harness.engine.sync(.force).completeReport)
        #expect(try await harness.engine.lastSyncedAt().get() == time.now())
        #expect(try await harness.engine.isSyncDue().get() == false)
        await harness.engine.shutdown()
        // The stamp lives in the index: a relaunch on the same disk reads it back.
        let relaunched = EngineHarness.make(disk: harness.fileSystem.survivingDisk(), time: time)
        let report = try await relaunched.start()
        #expect(report.stamp?.completedAt == time.now())
        #expect(try await relaunched.engine.isSyncDue().get() == false)
        await relaunched.engine.shutdown()
    }

    /// One asset of 100 fails; the run completes and lists it. Hang guard (S3-R4): under TSan in the whole Sync bundle it
    /// took 24.6 s alone and 35.7 to 37.5 s beside a second TSan process at a load of 16 to 26 (Stage 3 close-out cycle
    /// 4), over half its 60 s, so the guard is `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: one failing asset among 100 never aborts the sync and is listed in the report", .timeLimit(.minutes(3)))
    func oneFailureNeverAbortsTheRun() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(100)
        let failing = catalog[37].0
        // The failing asset's first attempt answers 404 (its later stage step is never consumed).
        await harness.source.script(failing.transferID, [.fail(.permanentMissing(httpStatus: 404))])
        await harness.serve(catalog)
        // The launch run's own outcome, whether or not a `sync` call would have joined it (L4-R17).
        let outcome = try await harness.startAndAwaitLaunchRun()
        guard case .completeWithFailures(let report) = outcome else {
            Issue.record("expected completeWithFailures, got \(outcome)")
            return
        }
        #expect(report.failedCount == 1)
        #expect(report.failures.map(\.id) == [failing.identifier])
        #expect(report.failures.first?.error == .notFound)
        #expect(report.fetched == 99)
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-6: a 404 is not requested again until its manifest entry changes, across a relaunch", .timeLimit(.minutes(1)))
    func notFoundPersistsAcrossRelaunch() async throws {
        let time = ManualTimeSource()
        let harness = EngineHarness.make(time: time)
        let gone = EngineFixture.entry("gone", EngineFixture.bytes(7))
        await harness.serveManifest([gone])
        await harness.source.script(gone.transferID, [.fail(.permanentMissing(httpStatus: 404))])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        #expect(await harness.source.starts.filter { $0.id == gone.transferID }.count == 1)
        await harness.engine.shutdown()

        let source = FakeRemoteSource()
        let relaunched = EngineHarness.make(disk: harness.fileSystem.survivingDisk(), time: time, source: source)
        try await relaunched.start()
        let again = await relaunched.engine.sync(.force)
        guard case .completeWithFailures(let report) = again else {
            Issue.record("expected completeWithFailures, got \(again)")
            return
        }
        #expect(report.failures.map(\.error) == [.notFound])
        #expect(await relaunched.engine.awaitAsset("gone", lane: .userInitiated) == .failure(.notFound))
        #expect(await source.starts.isEmpty, "no request for the failed entry")
        // A changed entry is requested again.
        let changed = EngineFixture.entry("gone", EngineFixture.bytes(8))
        await relaunched.serve([(changed, EngineFixture.bytes(8))], etag: "v2")
        _ = try #require(await relaunched.engine.sync(.force).completeReport)
        #expect(await source.starts.map(\.id) == [changed.transferID])
        await relaunched.engine.shutdown()
    }
}

extension SyncOutcome {
    /// The report of a complete run.
    var completeReport: SyncReport? {
        if case .complete(let report) = self {
            return report
        }
        return nil
    }
}
