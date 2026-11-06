import Foundation
import Testing
@testable import ZTronAssetKit
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Close-out cycle 1 verifier probes (correctness lens). Scratch only; never committed.
@Suite("Verifier probes C1", .serialized)
struct VerifierProbesC1 {
    static func isClientStarted(_ event: AssetEvent) -> Bool {
        if case .clientStarted = event {
            return true
        }
        return false
    }

    static func isMaintenanceFinished(_ event: AssetEvent) -> Bool {
        if case .maintenanceFinished = event {
            return true
        }
        return false
    }

    /// PROBE-A: a `subscribe()` stream is registered eagerly (live) before a reopen, and its consumer has not pulled
    /// yet when the reopen installs the replacement. `pullFirst` = true is the control: one pull before the reopen.
    @available(macOS 15.0, iOS 18.0, *)
    func runProbeA(pullFirst: Bool, label: String) async throws -> (clientStarted: Bool, maintenance: Bool, subscribersAfterReopen: Int) {
        let bytes = KitFixture.bytes(171)
        let entry = KitFixture.entry("x", bytes, policy: .onDemand)
        let harness = KitHarness.make()
        let manifest = KitFixture.manifestData([entry])
        await harness.source.scriptManifest([
            .fetched(manifest, etag: KitFixture.etag("v1")),
            .fetched(manifest, etag: KitFixture.etag("v2")),
        ])
        let client = harness.client
        try await harness.startAndSettle()
        let stream = try await harness.withClock { () throws(AssetError) -> AsyncStream<AssetEvent> in
            try await client.subscribe()
        }
        var iterator = stream.makeAsyncIterator()
        var received: [AssetEvent] = []
        if pullFirst {
            if let event = await iterator.next() {
                received.append(event)
            }
            // Let the pump register as a follower.
            for _ in 0..<50 {
                await Task.yield()
            }
        }
        try FacadeRaceTests.wipeRoot(harness)
        _ = try await harness.withClock { () throws(AssetError) -> PurgeResult in
            try await client.purge(.all)
        }
        let replacement = await client.lifecycle.current()
        let subscribersAfterReopen = await replacement.engine.introspect().subscribers
        let expected = await replacement.engine.kitRead { $0.state.launch?.report.generation }
        // Marker 1 on the replacement, before the consumer's next pull: a terminal maintenanceFinished.
        _ = try await harness.withClock { () throws(AssetError) -> MaintenanceReport in
            try await client.performMaintenance(timeBudget: 1)
        }
        // Marker 2: once the replacement has a subscriber, a terminal asset event of another subject.
        await harness.source.script(entry.transferID, [.stage(bytes)])
        let marker = Task { () -> Bool in
            await replacement.engine.waitUntil { $0.subscribers >= 1 }
            do throws(AssetError) {
                _ = try await harness.withClock { () throws(AssetError) -> URL in
                    try await client.resolve("x")
                }
                return true
            } catch {
                return false
            }
        }
        while let event = await iterator.next() {
            received.append(event)
            if case .assetAvailable(let id, _) = event, id == "x" {
                break
            }
        }
        let markerRan = await marker.value
        let gotStarted = received.contains { VerifierProbesC1.isClientStarted($0) }
        let gotMaintenance = received.contains { VerifierProbesC1.isMaintenanceFinished($0) }
        print("PROBE-A[\(label)] generation=\(replacement.generation) expectedStartGeneration=\(String(describing: expected)) replacementSubscribersRightAfterReopen=\(subscribersAfterReopen) markerRan=\(markerRan)")
        print("PROBE-A[\(label)] received=\(received)")
        print("PROBE-A[\(label)] replacement clientStarted received=\(gotStarted) maintenanceFinished(marker 1) received=\(gotMaintenance)")
        await client.shutdown()
        _ = await FacadeReopenTests.drain(&iterator)
        return (gotStarted, gotMaintenance, subscribersAfterReopen)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-A: a subscribe() stream live but not yet pulled when a reopen installs the replacement", .timeLimit(.minutes(1)))
    func probeA() async throws {
        let result = try await self.runProbeA(pullFirst: false, label: "not pulled")
        #expect(result.clientStarted, "the replacement's clientStarted reached the live subscribe() stream")
        #expect(result.maintenance, "the replacement's maintenanceFinished reached the live subscribe() stream")
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-A control: the same stream pulled once before the reopen", .timeLimit(.minutes(1)))
    func probeAControl() async throws {
        let result = try await self.runProbeA(pullFirst: true, label: "pulled once")
        #expect(result.clientStarted, "control: clientStarted")
        #expect(result.maintenance, "control: maintenanceFinished")
    }

    /// PROBE-A2: the app pattern `let s = try await client.subscribe(); await client.sync(.force); for await e in s`.
    /// The sync meets a replaced root, the facade reopens and repeats it on the replacement, and `sync` returns
    /// `.complete`. The consumer then reads its stream: does it see the repeated run's `syncFinished(.complete)`?
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-A2: subscribe(), then a sync that reopens, then read", .timeLimit(.minutes(1)))
    func probeA2() async throws {
        let bytes = KitFixture.bytes(161)
        let entry = KitFixture.entry("a", bytes)
        let marker = KitFixture.entry("m", KitFixture.bytes(162), policy: .onDemand)
        let markerBytes = KitFixture.bytes(162)
        let harness = KitHarness.make()
        let client = harness.client
        await harness.serve([(entry, bytes), (marker, markerBytes)])
        try await harness.startAndSettle()
        let stream = try await harness.withClock { () throws(AssetError) -> AsyncStream<AssetEvent> in
            try await client.subscribe()
        }
        var iterator = stream.makeAsyncIterator()
        let core = await client.lifecycle.current()
        let lock = try #require(harness.fileSystem.operations.last { $0.kind == .acquireExclusiveLock }?.url)
        try wipe(lock.deletingLastPathComponent(), in: harness.fileSystem)
        let store = core.store
        await #expect(throws: StoreError.storageUnavailable(.rootVanished)) {
            try await harness.withClock { () throws(StoreError) in
                try await store.markSyncDue()
            }
        }
        await FacadeReopenTests.serveTwice(harness, [(entry, bytes), (marker, markerBytes)])
        let outcome = await harness.syncDriven(.force)
        let replacement = await client.lifecycle.current()
        print("PROBE-A2 sync outcome=\(outcome) generation=\(replacement.generation) replacementSubscribers=\(await replacement.engine.introspect().subscribers)")
        await harness.source.script(marker.transferID, [.stage(markerBytes)])
        let resolver = Task { () -> Bool in
            await replacement.engine.waitUntil { $0.subscribers >= 1 }
            do throws(AssetError) {
                _ = try await harness.withClock { () throws(AssetError) -> URL in
                    try await client.resolve("m")
                }
                return true
            } catch {
                return false
            }
        }
        var received: [AssetEvent] = []
        while let event = await iterator.next() {
            received.append(event)
            if case .assetAvailable(let id, _) = event, id == "m" {
                break
            }
        }
        _ = await resolver.value
        let finished = received.compactMap { event -> SyncOutcome? in
            if case .syncFinished(_, let outcome) = event {
                return outcome
            }
            return nil
        }
        print("PROBE-A2 received=\(received)")
        print("PROBE-A2 syncFinished outcomes the consumer saw=\(finished)")
        #expect(finished.contains { if case .complete = $0 { return true }; return false }, "the consumer saw the repeated sync complete, as sync() returned: \(finished)")
        await client.shutdown()
        _ = await FacadeReopenTests.drain(&iterator)
    }

    /// PROBE-B1 (L5-R2, facade, my own shape): a prefetch registered before start, then shutdown: the group's join
    /// was spawned in `created`; right after shutdown no owned task is left, the store was never opened, and no log
    /// line was written.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-B1: prefetch before start, then shutdown", .timeLimit(.minutes(1)))
    func probeB1() async throws {
        let harness = KitHarness.make()
        let client = harness.client
        let engine = await harness.engine()
        let handle = client.prefetch(["x", "y"])
        try await handle.awaitRegistration()
        let before = await engine.introspect()
        await client.shutdown()
        let after = await engine.introspect()
        let locks = harness.fileSystem.operations.filter { $0.kind == .acquireExclusiveLock }.count
        print("PROBE-B1 before: lifecycle=\(before.lifecycle) ownedTasks=\(before.ownedTasks) groups=\(before.groups); after: lifecycle=\(after.lifecycle) ownedTasks=\(after.ownedTasks) groups=\(after.groups) locks=\(locks) ops=\(harness.fileSystem.operations.count)")
        #expect(after.ownedTasks == 0)
        withExtendedLifetime(handle) {}
    }

    /// PROBE-E (L5-R1 window 2 end to end): fast swipes through the window controller, several moves in one main-actor
    /// turn and then one move per turn without waiting for any join; in a monotonic swipe no asset re-enters, so no
    /// transfer may start twice.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-E: fast swipes never start a transfer twice", .timeLimit(.minutes(1)))
    func probeE() async throws {
        let harness = KitHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 8))
        let client = harness.client
        let entries: [ManifestEntry] = (0..<60).map { KitFixture.entry("p\($0)", KitFixture.bytes(100 + UInt64($0)), policy: .onDemand) }
        await harness.serveManifest(entries)
        try await harness.startAndSettle()
        let ids: [AssetID] = entries.map { $0.identifier }
        let source = harness.source
        let controller = PrefetchWindowController(client: client, radius: 2)
        await MainActor.run {
            controller.update(ids: ids, current: 2)
        }
        let engine = await harness.engine()
        let window: Set<TransferID> = Set(entries[0...4].map { $0.transferID })
        await engine.awaitCondition { engine in window.allSatisfy { PrefetchFacadeTests.inFlight($0, engine) } }
        await MainActor.run {
            controller.update(ids: ids, current: 3)
            controller.update(ids: ids, current: 4)
            controller.update(ids: ids, current: 5)
        }
        for current in 6...40 {
            await MainActor.run {
                controller.update(ids: ids, current: current)
            }
            if current % 3 == 0 {
                await Task.yield()
            }
        }
        await MainActor.run {
            controller.update(ids: ids, current: 41)
            controller.update(ids: ids, current: 42)
        }
        let final: Set<TransferID> = Set(entries[40...44].map { $0.transferID })
        await engine.awaitCondition { engine in
            engine.state.groups.count == 5 && final.allSatisfy { PrefetchFacadeTests.inFlight($0, engine) }
                && engine.state.jobs.keys.allSatisfy { final.contains($0) } && engine.state.releasing.isEmpty
        }
        let starts: [TransferID] = await source.starts.map { $0.id }
        var counts: [TransferID: Int] = [:]
        for id in starts {
            counts[id, default: 0] += 1
        }
        let restarted = counts.filter { $0.value > 1 }
        let promotions = await source.controlLog.filter { $0.control == .setPriority(.userInitiated) }.count
        let violations = await engine.invariantViolations()
        print("PROBE-E starts=\(starts.count) distinct=\(counts.count) restarted=\(restarted.count) promotions=\(promotions) violations=\(violations.count)")
        #expect(restarted.isEmpty, "\(restarted.count) transfers started more than once")
        #expect(violations.isEmpty, "\(violations)")
        await MainActor.run {
            controller.cancelAll()
        }
        await engine.waitUntil { $0.groups == 0 && $0.running == 0 }
        let claims = await engine.kitRead { ($0.state.claims.count, $0.state.claimHeld.count, $0.state.unlistedClaims, $0.state.jobs.count) }
        print("PROBE-E after cancelAll: claims=\(claims.0) held=\(claims.1) unlisted=\(claims.2) jobs=\(claims.3)")
        #expect(claims.0 == 0 && claims.1 == 0 && claims.2 == 0, "no claim outlives the handles")
        await client.shutdown()
    }

    /// PROBE-R1 (L5-V3-05 reproduction, my own shape): a cache registered before start and a prefetch registered before
    /// start (the join spawned in `created` only if it has not run yet), then shutdown at once: right after shutdown no
    /// owned task, no observer and no live observation, with no further pressure event.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-R1: register before start, then shutdown", .timeLimit(.minutes(1)))
    func probeR1() async throws {
        for round in 0..<20 {
            let harness = KitHarness.make()
            let client = harness.client
            let engine = await harness.engine()
            let cache = await MainActor.run { RecordingCache() }
            try await MainActor.run {
                try client.register(cache)
            }
            try await harness.pressure.requireObservers(equalTo: 1)
            let before = await engine.introspect()
            await client.shutdown()
            let after = await engine.introspect()
            // The fake removes an observation in a task its stream's termination spawns: wait for it (time limit).
            try await harness.pressure.requireObservers(equalTo: 0)
            let observers = await harness.pressure.activeObservers
            if round == 0 || after.ownedTasks != 0 || after.memoryPressureObserverActive || observers != 0 {
                print("PROBE-R1 round \(round) before: lifecycle=\(before.lifecycle) ownedTasks=\(before.ownedTasks) observer=\(before.memoryPressureObserverActive); after: lifecycle=\(after.lifecycle) ownedTasks=\(after.ownedTasks) observer=\(after.memoryPressureObserverActive) liveObservations=\(observers) ops=\(harness.fileSystem.operations.count) logLines=\(harness.tap.lines.count)")
            }
            #expect(after.lifecycle == .shutDown && after.ownedTasks == 0 && !after.memoryPressureObserverActive)
            #expect(observers == 0, "the observation ended with shutdown, no further event needed")
            #expect(harness.fileSystem.operations.isEmpty, "a created shutdown never touches the volume")
            withExtendedLifetime(cache) {}
        }
    }

    /// PROBE-R2 (L5-V3-05's reopen path, stress, no seam): a cache registered, a purge that meets a replaced root and
    /// reopens, and a shutdown placed after 0 to 7 yields; once both returned, every generation the client built is shut
    /// down with no owned task and no observation left.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-R2: reopen and shutdown interleavings leave no owned task", .timeLimit(.minutes(2)))
    func probeR2() async throws {
        var outcomes: [String: Int] = [:]
        for round in 0..<40 {
            let harness = KitHarness.make()
            let client = harness.client
            try await harness.startAndSettle()
            let cache = await MainActor.run { RecordingCache() }
            try await MainActor.run {
                try client.register(cache)
            }
            try await harness.pressure.requireObservers(equalTo: 1)
            let first = await client.lifecycle.current()
            try FacadeRaceTests.wipeRoot(harness)
            let purge = Task { () -> String in
                do throws(AssetError) {
                    _ = try await harness.withClock { () throws(AssetError) -> PurgeResult in
                        try await client.purge(.all)
                    }
                    return "ok"
                } catch {
                    return "\(error)"
                }
            }
            switch round % 4 {
            case 0:
                for _ in 0..<(round % 8) {
                    await Task.yield()
                }
            case 1:
                for _ in 0..<(40 + round * 5) {
                    await Task.yield()
                }
            case 2:
                // After the reopen installed and finished (current() waits for it).
                _ = await client.lifecycle.current()
            default:
                // After the replacement exists, while the purge may still run on it.
                while await client.lifecycle.current().generation == first.generation {
                    await Task.yield()
                }
            }
            await client.shutdown()
            let outcome = await purge.value
            outcomes[outcome, default: 0] += 1
            let last = await client.lifecycle.current()
            var engines = [first.engine]
            if last.generation != first.generation {
                engines.append(last.engine)
            }
            for engine in engines {
                let state = await engine.introspect()
                if state.ownedTasks != 0 || state.memoryPressureObserverActive || state.lifecycle != .shutDown {
                    print("PROBE-R2 round \(round) generation leak: \(state.lifecycle) ownedTasks=\(state.ownedTasks) observer=\(state.memoryPressureObserverActive)")
                }
                #expect(state.lifecycle == .shutDown && state.ownedTasks == 0 && !state.memoryPressureObserverActive)
            }
            try await harness.pressure.requireObservers(equalTo: 0)
            withExtendedLifetime(cache) {}
        }
        print("PROBE-R2 purge outcomes=\(outcomes)")
    }
}
