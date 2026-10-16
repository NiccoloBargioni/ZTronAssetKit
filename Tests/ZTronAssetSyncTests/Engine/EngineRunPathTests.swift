import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Run, manifest, start and retry paths: legacy migration before the launch run, unusable and throttled manifests,
/// point admission and the negative cache, joiners and their cancellation, user requests over backoffs and
/// throttles, breaker-blocked runs, offline runs, over-budget catalogs and the error ring (R-SYN-5, R-SYN-6,
/// R-SYN-11, R-STO-11, R-CAR-1, R-CAR-2, R-MAN-2, R-OBS-3, R-APL-4, R-NET-3).
@Suite("Engine run paths")
struct EngineRunPathTests {
    static let legacyRoot = URL(fileURLWithPath: "/fake-volume/Library/Caches/CDNAssets", isDirectory: true)

    /// A disk holding the prior art's legacy tree for `entries` (`manifest.json` and the files).
    @available(macOS 15.0, iOS 18.0, *)
    static func legacyDisk(_ entries: [(ManifestEntry, Data)], time: ManualTimeSource) throws -> DiskImage {
        struct Legacy: Encodable {
            let identifier: String
            let fileExtension: String
            let remotePath: String
            let localPathComponents: [String]
            let checksum: String?
        }
        let fileSystem = FakeFileSystem(time: time)
        func makeDirectories(_ directory: URL) throws {
            var missing: [URL] = []
            var current = directory
            while try fileSystem.itemInfo(at: current) == nil {
                missing.append(current)
                current = current.deletingLastPathComponent()
            }
            for url in missing.reversed() {
                try fileSystem.createDirectory(at: url)
            }
        }
        try makeDirectories(EngineRunPathTests.legacyRoot)
        let manifest = try JSONEncoder().encode(entries.map {
            Legacy(identifier: $0.0.identifier.rawValue, fileExtension: $0.0.fileExtension, remotePath: $0.0.remotePath, localPathComponents: $0.0.localPathComponents, checksum: $0.0.checksum?.hex)
        })
        try fileSystem.write(manifest, to: EngineRunPathTests.legacyRoot.appendingPathComponent("manifest.json"), mode: .truncate)
        for (entry, bytes) in entries {
            let directory = entry.localPathComponents.reduce(EngineRunPathTests.legacyRoot) { $0.appendingPathComponent($1, isDirectory: true) }
            try makeDirectories(directory)
            try fileSystem.write(bytes, to: directory.appendingPathComponent("\(entry.resolvedFileName).\(entry.fileExtension)"), mode: .truncate)
        }
        var disk = fileSystem.survivingDisk()
        disk.makeDurable()
        return disk
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-11: the launch run waits for legacy migration and downloads nothing it adopted", .timeLimit(.minutes(1)))
    func launchRunAfterMigration() async throws {
        let time = ManualTimeSource()
        let catalog = (0..<3).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(UInt64(400 + index))
            return (EngineFixture.entry("legacy\(index)", bytes), bytes)
        }
        let disk = try EngineRunPathTests.legacyDisk(catalog, time: time)
        let harness = EngineHarness.make(disk: disk, time: time, legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot))
        await harness.serveManifest(catalog.map(\.0))
        let probe = EventProbe(stream: try await harness.engine.subscribe().get())
        let report = try await harness.start()
        #expect(report.legacyMigrationPending)
        let finished = await probe.next { event in
            if case .syncFinished = event {
                return true
            }
            return false
        }
        await probe.stop()
        guard case .syncFinished(_, .complete(let launch))? = finished else {
            Issue.record("expected a complete launch run, got \(String(describing: finished))")
            return
        }
        #expect(launch.trigger == .launch && launch.fetched == 0)
        let view = try await harness.view()
        #expect(catalog.allSatisfy { view.records[$0.0.identifier]?.referencedBlob != nil }, "every legacy file was adopted")
        #expect(await harness.source.starts.isEmpty, "nothing adopted was downloaded")
        #expect(try await harness.engine.awaitAsset("legacy1", lane: .userInitiated).get().byteSize == Int64(catalog[1].1.count))
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-MAN-2: an undecodable manifest fails the run with serverUnavailable and leaves the applied manifest in force", .timeLimit(.minutes(1)))
    func undecodableManifest() async throws {
        let harness = EngineHarness.make()
        await harness.serve(EngineSyncTests.catalog(2))
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        let applied = try await harness.view().appliedManifest
        await harness.source.scriptManifest([.fetched(Data("{\"assets\": 7".utf8), etag: EngineFixture.etag("bad")), .fetched(Data("[".utf8), etag: EngineFixture.etag("bad2"))])
        #expect(await harness.engine.sync(.force) == .failed(.serverUnavailable(retryAfter: nil)))
        #expect(try await harness.view().appliedManifest == applied)
        // An unknown identifier asked while the manifest is unusable is answered with the same error.
        #expect(await harness.engine.awaitAsset("never-listed", lane: .userInitiated) == .failure(.serverUnavailable(retryAfter: nil)))
        #expect(try await harness.engine.diagnostics().get().recentErrors.contains { $0.failureClass == .rejected })
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a run whose manifest fetch is throttled ends blocked and a new run starts when the throttle ends", .timeLimit(.minutes(1)))
    func throttledManifest() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(1)
        await harness.scriptTransfers(catalog)
        await harness.source.scriptManifest([.fail(.transient(.throttled, retryAfter: .seconds(20))), .fetched(EngineFixture.manifestData(catalog.map(\.0)), etag: EngineFixture.etag("v1"))])
        let probe = EventProbe(stream: try await harness.engine.subscribe().get())
        try await harness.start()
        let first = await probe.next { event in
            if case .syncFinished = event {
                return true
            }
            return false
        }
        guard case .syncFinished(_, .blocked(.throttled, _))? = first else {
            Issue.record("expected a throttled run, got \(String(describing: first))")
            return
        }
        // The unknown identifier is answered from the throttle at once.
        let unknown = await harness.engine.awaitAsset("a0", lane: .userInitiated)
        guard case .failure(.serverUnavailable(let after?)) = unknown else {
            Issue.record("expected serverUnavailable with a retry hint, got \(unknown)")
            return
        }
        #expect(after > 0)
        try await harness.drive { $0.groups == 0 && $0.scheduledDeadlines == 0 && $0.jobsByState.isEmpty && $0.ownedTasks <= 1 }
        let second = await probe.next { event in
            if case .syncFinished(_, .complete) = event {
                return true
            }
            return false
        }
        #expect(second != nil, "the pending run completed once the throttle ended")
        await probe.stop()
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: misspelt identifiers trigger at most one manifest fetch per refetch interval", .timeLimit(.minutes(1)))
    func negativeCacheLimitsFetches() async throws {
        let harness = EngineHarness.make()
        await harness.serve(EngineSyncTests.catalog(1))
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let requests = await harness.source.manifestRequests.count
        for _ in 0..<5 {
            #expect(await harness.engine.awaitAsset("misspelt", lane: .userInitiated) == .failure(.notFound))
        }
        #expect(await harness.source.manifestRequests.count == requests + 1)
        harness.time.advance(by: harness.configuration.tuning.unknownIDRefetchInterval + 1)
        #expect(await harness.engine.awaitAsset("misspelt", lane: .userInitiated) == .failure(.notFound))
        #expect(await harness.source.manifestRequests.count == requests + 2)
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: an identifier a fresh manifest lists is admitted and fetched without a run", .timeLimit(.minutes(1)))
    func pointAdmission() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(1)
        await harness.serve(catalog)
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        let newBytes = EngineFixture.bytes(410)
        let fresh = EngineFixture.entry("fresh", newBytes)
        await harness.serve(catalog + [(fresh, newBytes)], etag: "v2")
        let location = try await harness.engine.awaitAsset("fresh", lane: .userInitiated).get()
        #expect(location.byteSize == Int64(newBytes.count))
        let view = try await harness.view()
        #expect(view.appliedManifest.contains("fresh"), "point-admitted")
        #expect(view.stamp?.manifestETag == EngineFixture.etag("v1"), "admission never stores the fetched ETag")
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: cancelling one caller of a shared run neither cancels nor waits for the others", .timeLimit(.minutes(1)))
    func sharedRunCancellation() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(1)
        await harness.serveManifest(catalog.map(\.0))
        await harness.source.script(catalog[0].0.transferID, [.hold, .stage(catalog[0].1)])
        try await harness.start()
        let engine = harness.engine
        let first = Task { await engine.sync(.force) }
        let second = Task { await engine.sync(.force) }
        await engine.waitUntil { $0.running == 1 }
        first.cancel()
        #expect(await first.value == .failed(.cancelled))
        await harness.source.release(catalog[0].0.transferID, with: .progress(received: 0, expected: nil))
        #expect(await second.value.completeReport?.fetched == 1)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-1: concurrent start calls share one start and a cancelled caller withdraws only itself", .timeLimit(.minutes(1)))
    func sharedStart() async throws {
        let metadata = SteppedBlockingExecutor(holding: true)
        let harness = EngineHarness.make(metadata: metadata)
        let engine = harness.engine
        let first = Task { await engine.start() }
        let second = Task { await engine.start() }
        try await metadata.requireHeldUnits(atLeast: 1)
        second.cancel()
        #expect(await second.value == .failure(.cancelled))
        await metadata.setHolding(false)
        await metadata.releaseAll()
        let report = try await first.value.get()
        #expect(await engine.start() == .success(report), "a later caller gets the same report")
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: shutdown during start answers shutDown and leaves the store closed", .timeLimit(.minutes(1)))
    func shutdownDuringStart() async throws {
        let metadata = SteppedBlockingExecutor(holding: true)
        let harness = EngineHarness.make(metadata: metadata)
        let engine = harness.engine
        let start = Task { await engine.start() }
        try await metadata.requireHeldUnits(atLeast: 1)
        let shutdown = Task { await engine.shutdown() }
        await engine.waitUntil { $0.lifecycle == .shuttingDown }
        await metadata.setHolding(false)
        await metadata.releaseAll()
        await shutdown.value
        #expect(await start.value == .failure(.shutDown))
        // The lock was released: another store opens the same root.
        let other = EngineHarness.make(time: harness.time, fileSystem: harness.fileSystem)
        try await other.start()
        await other.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a user request for an asset in backoff skips the wait", .timeLimit(.minutes(1)))
    func userSkipsBackoff() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(411)
        let entry = EngineHarness.onDemand("backoff", bytes)
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.fail(.transient(.serverError(httpStatus: 503), retryAfter: nil)), .stage(bytes)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let group = try await engine.registerGroup(["backoff"], lane: .prefetch).get()
        await engine.waitUntil { $0.jobsByState[.failed] == 1 }
        let location = try await engine.awaitAsset("backoff", lane: .userInitiated).get()
        #expect(location.byteSize == Int64(bytes.count))
        #expect(await harness.source.starts.count == 2)
        #expect(harness.time.pendingSleepers <= 1, "the retry did not wait for its backoff")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a user request waits for a short origin throttle and fails fast on a long one", .timeLimit(.minutes(1)))
    func userAndThrottle() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 1))
        let first = EngineHarness.onDemand("first", EngineFixture.bytes(412))
        let long = EngineHarness.onDemand("long", EngineFixture.bytes(413))
        await harness.serveManifest([first, long])
        await harness.source.script(first.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(120)))])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let throttled = await harness.engine.awaitAsset("first", lane: .userInitiated)
        guard case .failure(.serverUnavailable(let after?)) = throttled else {
            Issue.record("expected serverUnavailable, got \(throttled)")
            return
        }
        #expect(after >= 119)
        #expect(await harness.engine.awaitAsset("long", lane: .userInitiated) == .failure(.serverUnavailable(retryAfter: 120)), "no request while the origin is throttled")
        #expect(await harness.source.starts.count == 1)
        await harness.engine.shutdown()
    }

    /// When the origin's open breaker half-opens, if it is open.
    static func cooldownEnd(of engine: isolated SyncEngine) -> MonotonicInstant? {
        for breaker in engine.state.breakers.values {
            if case .open(_, let until, _) = breaker.state {
                return until
            }
        }
        return nil
    }

    /// The launch run's transfers each answer 500 once: the breaker opens. The run must settle blocked by it before its
    /// cooldown ends, so the clock is driven only to the retry deadlines until it has: driven blindly, it passed the
    /// cooldown while attempts whose 500 the engine had not yet received still ran (under load, captured in close-out
    /// cycle 9: two attempts still running at the cooldown's end, the breaker reopened, then closed by a probe, and the
    /// run completed). Every 500 reaches the engine without the clock, and the open breaker starts nothing, so once no
    /// transfer runs only the clock moves the run. Then past the cooldown: the pending run's probe closes the breaker.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a run whose transfers open the 5xx breaker ends blocked and the pending run's probe closes it", .timeLimit(.minutes(1)))
    func serverBreakerBlocksRun() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 5, reservedInteractiveSlots: 0))
        let catalog = EngineSyncTests.catalog(6)
        await harness.serveManifest(catalog.map(\.0))
        for (entry, bytes) in catalog {
            await harness.source.script(entry.transferID, [.fail(.transient(.serverError(httpStatus: 500), retryAfter: nil)), .stage(bytes)])
        }
        let probe = EventProbe(stream: try await harness.engine.subscribe().get())
        try await harness.start()
        let opened = await probe.next { event in
            if case .circuitChanged(_, .open(.serverErrors, _)) = event {
                return true
            }
            return false
        }
        #expect(opened != nil)
        await harness.engine.waitUntil { $0.running == 0 && $0.preempting == 0 }
        let reopens = try #require(await harness.engine.readForTests { Self.cooldownEnd(of: $0) }, "the breaker is open")
        try await harness.drive(before: reopens) { $0.groups == 0 && $0.jobsByState[.blocked] == nil && $0.jobsByState[.failed] == nil && $0.lifecycle == .running }
        let first = await probe.next { event in
            if case .syncFinished = event {
                return true
            }
            return false
        }
        guard case .syncFinished(_, .blocked(.circuitOpen(.serverErrors), _))? = first else {
            Issue.record("expected a run blocked by the breaker, got \(String(describing: first))")
            return
        }
        try await harness.drive { $0.groups == 0 && $0.scheduledDeadlines == 0 && $0.jobsByState.isEmpty && $0.ownedTasks <= 1 }
        let closed = await probe.next { event in
            if case .circuitChanged(_, .closed) = event {
                return true
            }
            return false
        }
        #expect(closed != nil, "a probe closed the breaker")
        let view = try await harness.view()
        #expect(catalog.allSatisfy { view.records[$0.0.identifier]?.referencedBlob != nil }, "every asset arrived in later runs")
        await probe.stop()
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: an offline run ends blocked and a new run starts when the path is satisfied", .timeLimit(.minutes(1)))
    func offlineRunResumes() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(2)
        await harness.serveManifest(catalog.map(\.0))
        for (entry, bytes) in catalog {
            await harness.source.script(entry.transferID, [.fail(.offline(.noConnection)), .stage(bytes)])
        }
        try await harness.start()
        let first = await harness.engine.sync(.force)
        guard case .blocked(.offline, _) = first else {
            Issue.record("expected an offline run, got \(first)")
            return
        }
        let probe = EventProbe(stream: try await harness.engine.subscribe().get())
        // The path goes down and the pending run waits; the satisfied edge arms its debounce.
        await harness.conditions.send(EngineConditionsTests.offline)
        let down = await probe.next { event in
            if case .conditionsChanged(let seen) = event {
                return !seen.network.satisfied
            }
            return false
        }
        #expect(down != nil)
        #expect(await harness.engine.introspect().scheduledDeadlines == 0, "no run is armed while offline")
        await harness.conditions.send(.unrestricted)
        await harness.engine.waitUntil { $0.scheduledDeadlines >= 1 }
        try await harness.drive { $0.groups == 0 && $0.scheduledDeadlines == 0 && $0.jobsByState.isEmpty && $0.ownedTasks <= 1 }
        let finished = await probe.next { event in
            if case .syncFinished(_, .complete(let report)) = event {
                return report.trigger == .conditionsChanged
            }
            return false
        }
        #expect(finished != nil)
        await probe.stop()
        await harness.engine.shutdown()
    }

    /// Which of the two racing events comes first: the alarm that opens the pending run's gate, or the blocked run's own
    /// task finishing the run (F-3).
    enum GateOrder: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// The gate opens in the actor turn that settles the run, before the run's task can finish it.
        case gateFirst
        /// The run finishes, then the debounce passes on the manual clock.
        case runFirst

        var testDescription: String {
            self.rawValue
        }
    }

    // Each order is forced, not raced (L4-R8): the debounce keeps the real alarm asleep on the manual clock, and the
    // gate-first order fires the pending run's deadline from a condition wait that runs in the turn that settles the
    // run, before the run's task can resume.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-6: a pending run whose gate opens while the blocked run is still finishing starts once it has finished",
        .timeLimit(.minutes(1)),
        arguments: GateOrder.allCases
    )
    func pendingRunGateOpensBeforeFinish(order: GateOrder) async throws {
        let debounce: TimeInterval = 1
        let harness = EngineHarness.make(tuning: SyncTuning(pendingRunDebounce: debounce))
        let catalog = EngineSyncTests.catalog(1)
        await harness.serveManifest(catalog.map(\.0))
        // The pending run's attempt holds until the blocked run's end has been received: in the gate-first order the
        // pending run starts in the turn that settles the blocked one, and its own end would otherwise replace the
        // blocked run's in the probe's slot if the probe had not pulled it yet (one slot per subject, §7.9; L4-R17).
        let transfer = catalog[0].0.transferID
        await harness.source.script(transfer, [.fail(.offline(.noConnection)), .hold, .stage(catalog[0].1)])
        let engine = harness.engine
        let probe = EventProbe(stream: try await engine.subscribe().get())
        // 0: waiting, 1: firing (a re-entrant evaluation while the deadline fires answers false), 2: fired.
        let gate = Mutex(0)
        var opener: Task<Void, Never>?
        if order == .gateFirst {
            let (registered, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            opener = Task {
                await engine.awaitCondition { engine in
                    signal.yield()
                    guard engine.state.run?.settlement != nil, engine.state.pendingRun != nil else {
                        return false
                    }
                    let fire = gate.withLock { phase -> Bool in
                        guard phase == 0 else {
                            return false
                        }
                        phase = 1
                        return true
                    }
                    guard fire else {
                        return gate.withLock { $0 } == 2
                    }
                    engine.firePendingRunDeadlineForTests()
                    gate.withLock { $0 = 2 }
                    return true
                }
            }
            var registration = registered.makeAsyncIterator()
            _ = await registration.next()
        }
        try await harness.start()
        let blocked = await probe.next { event in
            if case .syncFinished = event {
                return true
            }
            return false
        }
        guard case .syncFinished(_, .blocked(.offline, _))? = blocked else {
            Issue.record("expected an offline run, got \(String(describing: blocked))")
            opener?.cancel()
            await probe.stop()
            await engine.shutdown()
            return
        }
        if order == .gateFirst {
            await opener?.value
            #expect(gate.withLock { $0 } == 2, "the gate opened before the blocked run's task finished it")
        }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations)")
        guard violations.isEmpty else {
            // A stranded pending run never starts: waiting for it would only hang.
            await probe.stop()
            await engine.shutdown()
            return
        }
        await harness.source.release(transfer, with: .progress(received: 0, expected: nil))
        if order == .runFirst {
            // The pending run's debounce itself, not any deadline (L4-R17).
            await engine.awaitCondition { $0.state.heap.deadline(for: .pendingRun) != nil }
            let debounced = try #require(await engine.readForTests { $0.state.heap.deadline(for: .pendingRun) })
            harness.time.advance(to: debounced)
        }
        let resumed = await probe.next { event in
            if case .syncFinished(_, .complete(let report)) = event {
                return report.trigger == .conditionsChanged
            }
            return false
        }
        #expect(resumed != nil)
        await probe.stop()
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a catalog larger than the budget syncs its largest fitting prefix essential-first and stays due", .timeLimit(.minutes(1)))
    func overBudgetCatalog() async throws {
        let storage = StoragePolicy(budget: .bytes(700), reserveFreeBytes: 0, evictionPermitted: false)
        let harness = EngineHarness.make(storage: storage)
        let catalog = [
            (EngineFixture.entry("s0", EngineFixture.bytes(420, count: 300)), EngineFixture.bytes(420, count: 300)),
            (EngineFixture.entry("e0", EngineFixture.bytes(421, count: 300), policy: .essential), EngineFixture.bytes(421, count: 300)),
            (EngineFixture.entry("s1", EngineFixture.bytes(422, count: 300)), EngineFixture.bytes(422, count: 300)),
        ]
        await harness.serve(catalog)
        try await harness.start()
        let outcome = await harness.engine.sync(.force)
        guard case .completeWithFailures(let report) = outcome else {
            Issue.record("expected completeWithFailures (over budget), got \(outcome)")
            return
        }
        #expect(report.fetched == 2)
        #expect(Set(await harness.source.starts.map(\.id)) == [catalog[1].0.transferID, catalog[0].0.transferID], "essential first, then the prefix")
        #expect(try await harness.engine.isSyncDue().get(), "an over-budget run never writes the stamp")
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-OBS-3: the diagnostics keep the last 32 errors", .timeLimit(.minutes(1)))
    func errorRingIsBounded() async throws {
        let harness = EngineHarness.make()
        let catalog = (0..<40).map { EngineHarness.onDemand("m\($0)", EngineFixture.bytes(UInt64(430 + $0))) }
        await harness.serveManifest(catalog)
        for entry in catalog {
            await harness.source.script(entry.transferID, [.fail(.permanentMissing(httpStatus: 404))])
        }
        try await harness.start()
        _ = await harness.engine.sync(.force)
        for entry in catalog {
            #expect(await harness.engine.awaitAsset(entry.identifier, lane: .userInitiated) == .failure(.notFound))
        }
        let errors = try await harness.engine.diagnostics().get().recentErrors
        #expect(errors.count == EngineDiagnostics.recentErrorCapacity)
        #expect(errors.last?.id == "m39" && errors.first?.id == "m8", "oldest first, the earliest dropped")
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-APL-4: catalog and pack skew triggers one update check and a later retry", .timeLimit(.minutes(1)))
    func skewTriggersUpdateCheck() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(440)
        let entry = EngineHarness.onDemand("skewed", bytes)
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.fail(.transient(.sourceVersionSkew, retryAfter: nil)), .stage(bytes)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let requests = await harness.source.manifestRequests.count
        let engine = harness.engine
        let group = try await engine.registerGroup(["skewed"], lane: .prefetch).get()
        await engine.waitUntil { $0.jobsByState[.failed] == 1 }
        try await harness.drive { $0.jobsByState.isEmpty }
        #expect(await harness.source.manifestRequests.count == requests + 1, "one update check")
        #expect(await harness.source.starts.count == 2)
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: a transfer the system cancelled is retried after a backoff and integrity from the transport is recorded", .timeLimit(.minutes(1)))
    func systemCancellationAndTransportIntegrity() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(441)
        let cancelled = EngineHarness.onDemand("system", bytes)
        let truncated = EngineHarness.onDemand("truncated", EngineFixture.bytes(442))
        await harness.serveManifest([cancelled, truncated])
        await harness.source.script(cancelled.transferID, [.fail(.cancelled(.bySystem(.insufficientSystemResources))), .stage(bytes)])
        await harness.source.script(truncated.transferID, [.fail(.integrity(.truncated(expected: 300, received: 10)))])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let location = try await harness.withClock { try await engine.awaitAsset("system", lane: .userInitiated).get() }
        #expect(location.byteSize == Int64(bytes.count))
        #expect(await engine.awaitAsset("truncated", lane: .userInitiated) == .failure(.integrityFailure))
        guard case .quarantined? = try await harness.view().records["truncated"]?.residency else {
            Issue.record("expected the integrity backoff to be persisted")
            return
        }
        #expect(try await engine.metrics().get().integrityFailures == 1)
        await engine.shutdown()
    }
}

extension SyncEngine {
    /// Test seam: the alarm fires the pending run's deadline now, as `fireDue` does (the heap entry is consumed first).
    /// It neither publishes nor notifies when a run is still in place, so a condition wait may call it.
    func firePendingRunDeadlineForTests() {
        self.state.heap.remove(.pendingRun)
        self.pendingRunDeadlineFired()
    }
}
