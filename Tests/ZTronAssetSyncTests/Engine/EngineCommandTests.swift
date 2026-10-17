import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Records values handed to a closure, in order, and lets a test wait for a count (an actor: no lock).
actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func append(_ value: Value) {
        self.values.append(value)
        let ready = self.waiters.filter { $0.0 <= self.values.count }
        self.waiters.removeAll { $0.0 <= self.values.count }
        for waiter in ready {
            waiter.1.resume()
        }
    }

    /// Suspends until at least `count` values were recorded.
    func wait(for count: Int) async {
        guard self.values.count < count else {
            return
        }
        // REENTRANCY: test recorder — nothing: resumed once by the append that reaches `count`.
        await withCheckedContinuation { self.waiters.append((count, $0)) }
    }
}

/// The engine's commands: refresh, availability, leases, pins, purge, memory pressure, background events and
/// diagnostics (R-SYN-9, R-SYN-10, R-CAR-8, R-CLN-4, R-CLN-6, R-CLN-11, R-NET-3, R-OBS-2, R-OBS-3).
@Suite("Engine commands")
struct EngineCommandTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-9: a launch run starts only when the stamp is missing or the app version changed", .timeLimit(.minutes(1)))
    func launchRunFollowsRefreshPolicy() async throws {
        let isLaunch: @Sendable (AssetEvent) -> Bool = { event in
            if case .syncStarted(_, .launch) = event {
                return true
            }
            return false
        }
        let time = ManualTimeSource()
        let first = EngineHarness.make(time: time)
        await first.serve(EngineSyncTests.catalog(2))
        let firstProbe = EventProbe(stream: try await first.engine.subscribe().get())
        try await first.start()
        #expect(await firstProbe.next(where: isLaunch) != nil, "no stamp: the launch run started")
        _ = try #require(await first.engine.sync(.force).completeReport)
        if case .notDue(let at) = await first.engine.sync(.ifDue) {
            #expect(at == time.now())
        } else {
            Issue.record("expected notDue after a complete run")
        }
        await firstProbe.stop()
        await first.engine.shutdown()
        let same = EngineHarness.make(disk: first.fileSystem.survivingDisk(), time: time)
        try await same.start()
        #expect(try await same.engine.isSyncDue().get() == false, "same app version: not due")
        #expect(await same.engine.introspect().groups == 0, "so no launch run")
        await same.engine.shutdown()
        let upgraded = EngineHarness.make(disk: same.fileSystem.survivingDisk(), time: time, appVersion: "2.0+1")
        let upgradedProbe = EventProbe(stream: try await upgraded.engine.subscribe().get())
        try await upgraded.start()
        #expect(await upgradedProbe.next(where: isLaunch) != nil, "an app-version change always syncs")
        await upgradedProbe.stop()
        await upgraded.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: ensureAvailable fetches missing in-scope assets at userInitiated priority", .timeLimit(.minutes(1)))
    func ensureAvailableFetches() async throws {
        let harness = EngineHarness.make()
        let catalog = (0..<3).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(UInt64(210 + index))
            return (EngineHarness.onDemand("e\(index)", bytes), bytes)
        }
        await harness.serveManifest(catalog.map(\.0))
        await harness.scriptTransfers(catalog)
        try await harness.start()
        _ = await harness.engine.sync(.force)
        await harness.serveManifest(catalog.map(\.0), etag: "v2")
        let report = try await harness.engine.ensureAvailable(scope: .identifiers(["e0", "e2"])).get()
        #expect(report.total == 2 && report.present == 2 && report.isComplete)
        #expect(report.manifestFresh)
        let starts = await harness.source.starts
        #expect(Set(starts.map(\.id)) == [catalog[0].0.transferID, catalog[2].0.transferID])
        #expect(starts.allSatisfy { $0.priority == .userInitiated && $0.access == .unrestricted })
        #expect(await harness.engine.introspect().groups == 0)
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: ensureAvailable offline returns a complete report from the applied manifest or throws offline", .timeLimit(.minutes(1)))
    func ensureAvailableOffline() async throws {
        let harness = EngineHarness.make()
        let present = EngineFixture.bytes(220)
        let presentEntry = EngineFixture.entry("present", present)
        let missing = EngineHarness.onDemand("missing", EngineFixture.bytes(221))
        await harness.serveManifest([presentEntry, missing])
        await harness.source.script(presentEntry.transferID, [.stage(present)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        await harness.source.scriptManifest([.fail(.offline(.noConnection)), .fail(.offline(.noConnection))])
        let complete = try await harness.engine.ensureAvailable(scope: .identifiers(["present"])).get()
        #expect(complete.isComplete && !complete.manifestFresh)
        #expect(await harness.engine.ensureAvailable(scope: .identifiers(["present", "missing"])) == .failure(.offline))
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: cancelling ensureAvailable cancels transfers wanted by nobody else and throws cancelled", .timeLimit(.minutes(1)))
    func ensureAvailableCancelled() async throws {
        let harness = EngineHarness.make()
        let alone = EngineHarness.onDemand("alone", EngineFixture.bytes(230))
        let shared = EngineHarness.onDemand("shared", EngineFixture.bytes(231))
        await harness.serveManifest([alone, shared])
        await harness.source.script(alone.transferID, [.hold])
        await harness.source.script(shared.transferID, [.hold])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let group = try await engine.registerGroup(["shared"], lane: .prefetch).get()
        let caller = Task { await engine.ensureAvailable(scope: .identifiers(["alone", "shared"])) }
        await engine.waitUntil { $0.running == 2 && $0.groups == 2 }
        // Both drivers hold their handles, so a withdrawal cancels in the turn that retires the job (a handle still on
        // its way is cancelled by its driver later, which the control log would see only by timing).
        await engine.waitForAllHandles()
        caller.cancel()
        #expect(await caller.value == .failure(.cancelled))
        await engine.waitUntil { $0.groups == 1 && $0.running == 1 }
        let controls = await harness.source.controlLog
        #expect(controls.contains(FakeControlRecord(transfer: alone.transferID, control: .cancel)))
        #expect(!controls.contains(FakeControlRecord(transfer: shared.transferID, control: .cancel)), "the prefetch handle keeps it")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-8: a leased asset survives eviction and purge until the lease ends", .timeLimit(.minutes(1)))
    func leaseSurvivesPurge() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(240)
        let entry = EngineFixture.entry("leased", bytes)
        await harness.serve([(entry, bytes)])
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        let lease = try await harness.engine.acquireLease("leased").get()
        // A purge waits for its grace window in its own task: the clock moves meanwhile.
        let engine = harness.engine
        let purged = try await harness.withClock { try await engine.purge(.all).get() }
        #expect(purged.assetsRemoved == 1)
        #expect(purged.bytesDeferred == Int64(bytes.count), "the leased blob is deferred")
        try await harness.settle()
        #expect(try harness.fileSystem.itemInfo(at: lease.url) != nil, "still readable while leased")
        await harness.engine.releaseLease(lease)
        try await harness.settle()
        #expect(try harness.fileSystem.itemInfo(at: lease.url) == nil, "deleted once the lease ended")
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-8: acquiring a lease on an absent asset resolves it first", .timeLimit(.minutes(1)))
    func leaseResolvesFirst() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(241)
        let entry = EngineHarness.onDemand("later", bytes)
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.stage(bytes)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let lease = try await harness.engine.acquireLease("later").get()
        #expect(lease.id == "later")
        #expect(await harness.source.starts.count == 1)
        #expect(try harness.fileSystem.itemInfo(at: lease.url) != nil)
        await harness.engine.releaseLease(lease)
        #expect(await harness.engine.acquireLease("unknown") == .failure(.notFound))
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: purge(.evictable) makes isSyncDue true and clears lastSyncedAt", .timeLimit(.minutes(1)))
    func purgeMakesSyncDue() async throws {
        let harness = EngineHarness.make()
        await harness.serve(EngineSyncTests.catalog(3))
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        #expect(try await harness.engine.isSyncDue().get() == false)
        #expect(try await harness.engine.lastSyncedAt().get() != nil)
        let engine = harness.engine
        let result = try await harness.withClock { try await engine.purge(.evictable).get() }
        #expect(result.assetsRemoved == 3)
        #expect(try await harness.engine.isSyncDue().get())
        #expect(try await harness.engine.lastSyncedAt().get() == nil)
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: purge ends the active run with failed(cancelled)", .timeLimit(.minutes(1)))
    func purgeEndsRun() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(2)
        await harness.serveManifest(catalog.map(\.0))
        for (entry, _) in catalog {
            await harness.source.script(entry.transferID, [.hold])
        }
        try await harness.start()
        let engine = harness.engine
        let run = Task { await engine.sync(.force) }
        await engine.waitUntil { $0.running == 2 }
        // Both drivers hold their handles, so the purge's withdrawal cancels in the turn that retires each job.
        await engine.waitForAllHandles()
        _ = try await harness.withClock { try await engine.purge(.all).get() }
        #expect(await run.value == .failed(.cancelled))
        await engine.waitUntil { $0.jobsByState.isEmpty }
        #expect(await harness.source.controlLog.filter { $0.control == .cancel }.count == 2, "the run's transfers were withdrawn")
        #expect(try await engine.isSyncDue().get())
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-11: the memory-pressure observer runs only while a handler is set, applies only the newest epoch and stops at shutdown", .timeLimit(.minutes(1)))
    func memoryPressureObserver() async throws {
        let harness = EngineHarness.make()
        try await harness.start()
        let engine = harness.engine
        let levels = Recorder<MemoryPressureLevel>()
        try await engine.observeMemoryPressure(epoch: 2, handler: { level in await levels.append(level) }).get()
        try await harness.pressure.requireObservers(equalTo: 1)
        #expect(await engine.introspect().memoryPressureObserverActive)
        #expect(await engine.introspect().isIdleSilent == false, "the observer is work")
        await harness.pressure.send(.warning)
        await levels.wait(for: 1)
        // A stale epoch is ignored: the observer keeps running.
        try await engine.observeMemoryPressure(epoch: 1, handler: nil).get()
        await harness.pressure.send(.critical)
        await levels.wait(for: 2)
        #expect(await levels.values == [.warning, .critical])
        try await engine.observeMemoryPressure(epoch: 3, handler: nil).get()
        try await harness.pressure.requireObservers(equalTo: 0)
        await engine.waitUntil { !$0.memoryPressureObserverActive }
        try await engine.observeMemoryPressure(epoch: 4, handler: { level in await levels.append(level) }).get()
        try await harness.pressure.requireObservers(equalTo: 1)
        await engine.shutdown()
        try await harness.pressure.requireObservers(equalTo: 0)
        #expect(await engine.introspect().memoryPressureObserverActive == false)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: background-session events reach the source and are answered at once after shutdown", .timeLimit(.minutes(1)))
    func backgroundEvents() async throws {
        let harness = EngineHarness.make()
        try await harness.start()
        try await harness.engine.backgroundSessionEventsPending(identifier: "com.example.assets").get()
        #expect(await harness.source.backgroundEventIdentifiers == ["com.example.assets"])
        await harness.engine.shutdown()
        #expect(await harness.engine.backgroundSessionEventsPending(identifier: "com.example.assets").isShutDown)
        #expect(await harness.source.backgroundEventIdentifiers.count == 1)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-4: pins reach the store and a pinned asset is never evicted", .timeLimit(.minutes(1)))
    func pinsSurviveEviction() async throws {
        let time = ManualTimeSource()
        let first = EngineHarness.make(time: time)
        let catalog = (0..<3).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(UInt64(250 + index), count: 100)
            return (EngineFixture.entry("p\(index)", bytes), bytes)
        }
        await first.serve(catalog)
        try await first.start()
        _ = try #require(await first.engine.sync(.force).completeReport)
        try await first.engine.setPinned(["p0", "p1"], pinned: true).get()
        #expect(try await first.view().records["p0"]?.pinned == true)
        await first.engine.shutdown()
        time.advance(by: 3_600)
        let second = EngineHarness.make(disk: first.fileSystem.survivingDisk(), time: time, storage: StoragePolicy(budget: .bytes(100), reserveFreeBytes: 0, minimumResidency: 0))
        try await second.start()
        _ = try await second.engine.performMaintenance(timeBudget: 10).get()
        let view = try await second.view()
        #expect(view.records["p0"]?.referencedBlob != nil && view.records["p1"]?.referencedBlob != nil, "pinned assets stay")
        #expect(view.records["p2"]?.residency == .absent(.evicted))
        try await second.engine.setPinned(["p0"], pinned: false).get()
        #expect(try await second.view().records["p0"]?.pinned == false)
        await second.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-OBS-3: diagnostics carry the counters, the recent errors, the launch facts and the store's generation and stamp", .timeLimit(.minutes(1)))
    func diagnosticsAndMetrics() async throws {
        let harness = EngineHarness.make(retentionScope: .tags(["x"]))
        let good = EngineFixture.bytes(260)
        let goodEntry = EngineFixture.entry("good", good, tags: ["x"])
        let gone = EngineFixture.entry("gone", EngineFixture.bytes(261), tags: ["x"])
        await harness.serveManifest([goodEntry, gone])
        await harness.source.script(goodEntry.transferID, [.stage(good)])
        await harness.source.script(gone.transferID, [.fail(.permanentMissing(httpStatus: 404))])
        let report = try await harness.start()
        _ = await harness.engine.sync(.force)
        // The store's own work after the run (the 404's bookkeeping commit) has run, so the generation diagnostics read
        // is the one the view below reads, not an earlier one (L4-R17: never two snapshots across pending store work).
        try await harness.settle()
        let diagnostics = try await harness.engine.diagnostics().get()
        #expect(diagnostics.appVersion == "1.0+1")
        #expect(diagnostics.launchEpoch == report.launchEpoch)
        #expect(diagnostics.retentionScope == .tags(["x"]))
        #expect(diagnostics.indexGeneration == (try await harness.view()).generation)
        #expect(diagnostics.recentErrors.contains { $0.failureClass == .notFound && $0.id == "gone" })
        #expect(diagnostics.introspection.lifecycle == .running)
        let metrics = try await harness.engine.metrics().get()
        #expect(metrics.failures.notFound == 1)
        #expect(metrics.transferRequests == 2)
        #expect(metrics.manifestRequests >= 1)
        #expect(metrics.bytesDownloaded == Int64(good.count))
        #expect(metrics.illegalTransitions == 0)
        await harness.engine.shutdown()
    }
}
