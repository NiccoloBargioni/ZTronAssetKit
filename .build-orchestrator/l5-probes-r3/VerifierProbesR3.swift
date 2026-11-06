import Foundation
import Testing
@testable import ZTronAssetKit
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Verifier probes (round 3, correctness lens). Scratch only: never committed.
@Suite("Verifier probes r3")
struct VerifierProbesR3 {
    /// PROBE-1: a purgeable cache registered before the client was started starts the engine's memory-pressure observer
    /// on an engine still in `created`; `shutdown()` then takes the engine's `created` branch, which neither cancels nor
    /// joins owned tasks, so the observer task and its pressure subscription outlive the shutdown (R-SYN-15).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-1: register before start, then shutdown, leaves no owned task and no pressure observation", .timeLimit(.minutes(1)))
    func registerBeforeStartThenShutdown() async throws {
        let harness = KitHarness.make()
        let client = harness.client
        let cache = await MainActor.run { RecordingCache() }
        try await MainActor.run {
            try client.register(cache)
        }
        try await harness.pressure.requireObservers(equalTo: 1)
        let engine = await harness.engine()
        let before = await engine.introspect()
        await client.shutdown()
        let after = await engine.introspect()
        let observations = await harness.pressure.activeObservers
        print("PROBE-1 before: lifecycle=\(before.lifecycle) ownedTasks=\(before.ownedTasks) observer=\(before.memoryPressureObserverActive); after: lifecycle=\(after.lifecycle) ownedTasks=\(after.ownedTasks) observer=\(after.memoryPressureObserverActive) liveObservations=\(observations)")
        #expect(after.lifecycle == .shutDown)
        #expect(after.ownedTasks == 0, "owned tasks after shutdown: \(after.ownedTasks)")
        #expect(after.memoryPressureObserverActive == false, "the observer is still active after shutdown")
        #expect(observations == 0, "live pressure observations after shutdown: \(observations)")
        // The leftover observer ends only at the next pressure event (its loop then sees the shutdown).
        await harness.pressure.send(.warning)
        try await harness.pressure.requireObservers(equalTo: 0)
        let purged = await MainActor.run { cache.levels.count }
        print("PROBE-1 after one more event: liveObservations=\(await harness.pressure.activeObservers) purges=\(purged)")
        withExtendedLifetime(cache) {}
    }

    /// PROBE-2: the reopen applies the recorded pressure request to the replacement while it is still `created`
    /// (`performReopen`, before `next.engine.start()`); a `shutdown()` landing before that start shuts the replacement
    /// down in `created`, and its observer task survives. The probe-only seam point `probeAfterPressure` (scratch copy
    /// only) parks the reopen right after the pressure request was applied, which is where the shipped code goes on to
    /// the start; it changes no logic.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-2: a shutdown between the replacement's pressure request and its start leaves no observer", .timeLimit(.minutes(1)))
    func shutdownBeforeReplacementStart() async throws {
        let harness = KitHarness.make()
        let client = harness.client
        try await harness.startAndSettle()
        let cache = await MainActor.run { RecordingCache() }
        try await MainActor.run {
            try client.register(cache)
        }
        try await harness.pressure.requireObservers(equalTo: 1)
        let hold = SeamHold()
        await client.lifecycle.setSeam { point in
            if case .probeAfterPressure = point {
                await hold.arrive()
            }
        }
        try FacadeRaceTests.wipeRoot(harness)
        let purge = Task { () -> Result<PurgeResult, AssetError> in
            do throws(AssetError) {
                return .success(try await harness.withClock { () throws(AssetError) -> PurgeResult in
                    try await client.purge(.all)
                })
            } catch {
                return .failure(error)
            }
        }
        await hold.waitUntilParked()
        let replacement = await client.lifecycle.current()
        try await harness.pressure.requireObservers(equalTo: 1)
        let before = await replacement.engine.introspect()
        await client.shutdown()
        await hold.open()
        let result = await purge.value
        let after = await replacement.engine.introspect()
        let observations = await harness.pressure.activeObservers
        print("PROBE-2 generation=\(replacement.generation) before shutdown: lifecycle=\(before.lifecycle) ownedTasks=\(before.ownedTasks) observer=\(before.memoryPressureObserverActive); after: lifecycle=\(after.lifecycle) ownedTasks=\(after.ownedTasks) observer=\(after.memoryPressureObserverActive) liveObservations=\(observations); purge=\(result)")
        #expect(after.lifecycle == .shutDown)
        #expect(after.ownedTasks == 0, "owned tasks after shutdown: \(after.ownedTasks)")
        #expect(observations == 0, "live pressure observations after shutdown: \(observations)")
        await harness.pressure.send(.warning)
        try await harness.pressure.requireObservers(equalTo: 0)
        withExtendedLifetime(cache) {}
    }

    /// PROBE-3: a consumer of `client.events` registered before start sees generation 0's `clientStarted` (terminal,
    /// R-SYN-12); after a reopen, does it see the replacement's `clientStarted` too? The pump switches engines in
    /// `lifecycle.current()`, which waits for the whole reopen task, and that task ends only after the replacement's
    /// `start()` returned, i.e. after `clientStarted` was broadcast to nobody (the replay does not repeat it).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-3: the replacement's clientStarted reaches a consumer that followed the reopen", .timeLimit(.minutes(1)))
    func replacementClientStartedReachesConsumer() async throws {
        var missed = 0
        let rounds = 20
        for round in 0..<rounds {
            let harness = KitHarness.make()
            let client = harness.client
            let probe = EventProbe(stream: client.events)
            let engine0 = await harness.engine()
            await engine0.waitUntil { $0.subscribers == 1 }
            try await harness.startAndSettle()
            _ = await probe.next { event in
                if case .clientStarted = event {
                    return true
                }
                return false
            }
            try FacadeRaceTests.wipeRoot(harness)
            _ = try await harness.withClock { () throws(AssetError) -> PurgeResult in
                try await client.purge(.all)
            }
            let replacement = await client.lifecycle.current()
            await replacement.engine.waitUntil { $0.subscribers == 1 }
            await client.shutdown()
            _ = await probe.next { $0 == .clientShutDown }
            let received = await probe.received
            await probe.stop()
            let starts = received.filter { event in
                if case .clientStarted = event {
                    return true
                }
                return false
            }
            if starts.count < 2 {
                missed += 1
            }
            if round < 3 || starts.count < 2 && missed <= 2 {
                print("PROBE-3 round \(round): generation=\(replacement.generation) clientStarted events=\(starts) all=\(received)")
            }
        }
        print("PROBE-3 summary: the replacement's clientStarted was missing in \(missed) of \(rounds) rounds")
        #expect(missed == 0, "the replacement's clientStarted was missing in \(missed) of \(rounds) rounds")
    }

    /// PROBE-4: a terminal `assetAvailable` of the replacement, for a resolve that runs on it while the reopen task is
    /// still re-registering prefetch groups (parked at the shipped `registrationAnswered` seam point), never reaches a
    /// consumer that held `client.events` throughout.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-4: an assetAvailable of the replacement during the reopen's tail reaches the consumer", .timeLimit(.minutes(1)))
    func replacementAssetAvailableDuringReopenTail() async throws {
        let bytes = KitFixture.bytes(7)
        let entry = KitFixture.entry("x", bytes, policy: .onDemand)
        let harness = KitHarness.make()
        let manifest = KitFixture.manifestData([entry])
        await harness.source.scriptManifest([
            .fetched(manifest, etag: KitFixture.etag("v1")),
            .fetched(manifest, etag: KitFixture.etag("v2")),
            .fetched(manifest, etag: KitFixture.etag("v3")),
        ])
        let client = harness.client
        let probe = EventProbe(stream: client.events)
        let engine0 = await harness.engine()
        await engine0.waitUntil { $0.subscribers == 1 }
        try await harness.startAndSettle()
        let handle = client.prefetch(["g"])
        try await handle.awaitRegistration()
        let hold = SeamHold()
        await client.lifecycle.setSeam { point in
            if point == .registrationAnswered {
                await hold.arrive()
            }
        }
        try FacadeRaceTests.wipeRoot(harness)
        let purge = Task { () -> Result<PurgeResult, AssetError> in
            do throws(AssetError) {
                return .success(try await harness.withClock { () throws(AssetError) -> PurgeResult in
                    try await client.purge(.all)
                })
            } catch {
                return .failure(error)
            }
        }
        await hold.waitUntilParked()
        let replacement = await client.lifecycle.current()
        let subscribersWhileParked = await replacement.engine.introspect().subscribers
        // Control: a direct subscriber of the replacement engine, registered before the resolve.
        let direct = EventProbe(stream: try await replacement.engine.subscribe().get())
        await harness.source.script(entry.transferID, [.stage(bytes)])
        let url = try await harness.withClock { () throws(AssetError) -> URL in
            try await client.resolve("x")
        }
        let directSaw = await direct.next { event in
            if case .assetAvailable(let id, _) = event, id == "x" {
                return true
            }
            return false
        } != nil
        await hold.open()
        let purged = await purge.value
        await replacement.engine.waitUntil { $0.subscribers == 2 }
        await client.shutdown()
        await direct.stop()
        _ = await probe.next { $0 == .clientShutDown }
        let received = await probe.received
        await probe.stop()
        let available = received.contains { event in
            if case .assetAvailable(let id, _) = event, id == "x" {
                return true
            }
            return false
        }
        print("PROBE-4 control: the direct subscriber of the replacement saw assetAvailable(x): \(directSaw)")
        print("PROBE-4 generation=\(replacement.generation) subscribersWhileParked=\(subscribersWhileParked) resolved=\(url.lastPathComponent) purge=\(purged) assetAvailable(x) received=\(available) events=\(received.map { String(describing: $0).prefix(40) })")
        #expect(available, "the replacement's assetAvailable(x) never reached the consumer")
        withExtendedLifetime(handle) {}
    }

    /// PROBE-1 control: the same registration after start; shutdown takes the full path and stops the observer.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-1 control: register after start, then shutdown, leaves nothing", .timeLimit(.minutes(1)))
    func registerAfterStartThenShutdown() async throws {
        let harness = KitHarness.make()
        let client = harness.client
        try await harness.startAndSettle()
        let cache = await MainActor.run { RecordingCache() }
        try await MainActor.run {
            try client.register(cache)
        }
        try await harness.pressure.requireObservers(equalTo: 1)
        let engine = await harness.engine()
        await client.shutdown()
        let after = await engine.introspect()
        try await harness.pressure.requireObservers(equalTo: 0)
        print("PROBE-1 control after: lifecycle=\(after.lifecycle) ownedTasks=\(after.ownedTasks) observer=\(after.memoryPressureObserverActive)")
        #expect(after.ownedTasks == 0)
        #expect(after.memoryPressureObserverActive == false)
        withExtendedLifetime(cache) {}
    }
}
