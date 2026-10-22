import Foundation
import Testing
@testable import ZTronAssetKit
@testable import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

extension AssetStore {
    /// The leases held now (test seam of the facade tests).
    func kitLeaseCount() -> Int {
        self.state.cleanup.leases.values.reduce(0) { $0 + $1.count }
    }
}

/// A purgeable cache that reports each purge on a stream, so a test waits for it without polling.
@MainActor
final class SignallingCache: PurgeableCache {
    private(set) var levels: [MemoryPressureLevel] = []
    private let signal: AsyncStream<MemoryPressureLevel>.Continuation

    init(signal: AsyncStream<MemoryPressureLevel>.Continuation) {
        self.signal = signal
    }

    func purge(level: MemoryPressureLevel) {
        self.levels.append(level)
        self.signal.yield(level)
    }
}

/// Suspends until the calling task is cancelled, then throws `CancellationError` (a body that never finishes by
/// itself, without any clock).
func untilCancelled() async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    for await _ in stream {}
    withExtendedLifetime(continuation) {}
    try Task.checkCancellation()
}

@Suite("Facade behaviour")
struct FacadeBehaviourTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-7: lookup, prefetch, events and resolve entry make zero file-system calls on the main thread", .timeLimit(.minutes(1)))
    func uiCallsDoNoMainThreadIO() async throws {
        let bytes = KitFixture.bytes(101)
        let present = KitFixture.entry("present", bytes)
        let onDemandBytes = KitFixture.bytes(102)
        let onDemand = KitFixture.entry("od", onDemandBytes, policy: .onDemand)
        let harness = KitHarness.make()
        await harness.serve([(present, bytes)])
        await harness.source.script(onDemand.transferID, [.stage(onDemandBytes)])
        await harness.serveManifest([present, onDemand], etag: "v1")
        try await harness.startAndSettle()
        let client = harness.client
        let mainCallsBefore = harness.fileSystem.mainThreadCalls
        let operationsBefore = harness.fileSystem.operations.count
        // Every UI-facing call made on the main actor, including the synchronous part of `resolve` (its entry).
        let (location, handle, events, resolving) = await MainActor.run { () -> (AssetLocation?, PrefetchHandle, AsyncStream<AssetEvent>, Task<URL, any Error>) in
            let location = client.lookup(present.identifier)
            let handle = client.prefetch([onDemand.identifier])
            let events = client.events
            let resolving = Task { @MainActor in
                try await client.resolve(present.identifier)
            }
            return (location, handle, events, resolving)
        }
        #expect(location != nil)
        try await handle.awaitRegistration()
        let probe = EventProbe(stream: events)
        let url = try await resolving.value
        #expect(url == location?.url)
        try await harness.drive(until: { $0.isIdleSilent && $0.groups == 1 })
        handle.cancel()
        await client.shutdown()
        _ = await probe.next { $0 == .clientShutDown }
        await probe.stop()
        #expect(harness.fileSystem.operations.count > operationsBefore, "setup: the calls led to store work")
        #expect(harness.fileSystem.mainThreadCalls == mainCallsBefore, "file-system calls on the main thread: \(harness.fileSystem.mainThreadCalls - mainCallsBefore)")
        #expect(harness.fileSystem.mainThreadCalls == 0)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-8: withAsset releases its lease when the body throws or is cancelled", .timeLimit(.minutes(1)))
    func withAssetReleasesLease() async throws {
        struct BodyFailure: Error {}
        let bytes = KitFixture.bytes(103)
        let entry = KitFixture.entry("video", bytes, ext: "mp4")
        let harness = KitHarness.make()
        await harness.serve([(entry, bytes)])
        try await harness.startAndSettle()
        let client = harness.client
        let store = await client.lifecycle.current().store
        let engine = await harness.engine()

        let value = try await client.withAsset(entry.identifier) { url in
            url.pathExtension
        }
        #expect(value == "mp4")
        // The engine releases the store's lease in an owned task (so the release re-arms its alarm).
        await engine.waitUntil { $0.ownedTasks == 0 }
        #expect(await store.kitLeaseCount() == 0, "released after a body that returned")

        await #expect(throws: BodyFailure.self) {
            try await client.withAsset(entry.identifier) { _ in
                throw BodyFailure()
            }
        }
        // The engine releases the store's lease in an owned task (so the release re-arms its alarm).
        await engine.waitUntil { $0.ownedTasks == 0 }
        #expect(await store.kitLeaseCount() == 0, "released after a body that threw")

        let (started, signal) = AsyncStream<Int>.makeStream()
        let playing = Task {
            try await client.withAsset(entry.identifier) { _ in
                signal.yield(await store.kitLeaseCount())
                try await untilCancelled()
            }
        }
        var heldWhileRunning: Int?
        for await count in started {
            heldWhileRunning = count
            break
        }
        #expect(heldWhileRunning == 1, "the body runs under one lease")
        playing.cancel()
        await #expect(throws: CancellationError.self) {
            try await playing.value
        }
        // The engine releases the store's lease in an owned task (so the release re-arms its alarm).
        await engine.waitUntil { $0.ownedTasks == 0 }
        #expect(await store.kitLeaseCount() == 0, "released after a cancelled body")
        await #expect(throws: AssetError.notFound) {
            try await harness.withClock { () throws(AssetError) in
                do {
                    _ = try await client.withAsset("never-listed") { url in url }
                } catch let error as AssetError {
                    throw error
                } catch {
                    Issue.record("withAsset rethrows the engine's AssetError: \(error)")
                }
            }
        }
        await client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-11: a registered purgeable cache is purged on a memory-pressure event", .timeLimit(.minutes(1)))
    func cachePurgedOnPressure() async throws {
        let harness = KitHarness.make()
        try await harness.startAndSettle()
        let client = harness.client
        let (purges, signal) = AsyncStream<MemoryPressureLevel>.makeStream()
        let cache = await MainActor.run { SignallingCache(signal: signal) }
        try await MainActor.run {
            try client.register(cache)
        }
        try await harness.pressure.requireObservers(equalTo: 1)
        await harness.pressure.send(.critical)
        var received: MemoryPressureLevel?
        for await level in purges {
            received = level
            break
        }
        #expect(received == .critical)
        #expect(await MainActor.run { cache.levels } == [.critical])
        await MainActor.run {
            client.unregister(cache)
        }
        try await harness.pressure.requireObservers(equalTo: 0)
        let engine = await harness.engine()
        await engine.waitUntil { !$0.memoryPressureObserverActive }
        #expect(await engine.introspect().memoryPressureObserverActive == false, "the observer stops with the last cache")
        await client.shutdown()
    }

    /// L4-R23 (fresh call): the engine refuses a fetch-first `ensureAvailable` whose manifest fetch the origin's
    /// throttle refuses with `.serverUnavailable(retryAfter:)` carrying the time left; the facade reports it as is.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: the facade's ensureAvailable throws serverUnavailable with the time left when the origin's throttle refuses its manifest fetch", .timeLimit(.minutes(1)))
    func ensureRefusedByThrottle() async throws {
        let harness = KitHarness.make()
        let bytesA = KitFixture.bytes(111)
        let a = KitFixture.entry("a", bytesA, policy: .onDemand)
        let m = KitFixture.entry("m", KitFixture.bytes(112), policy: .onDemand)
        await harness.serveManifest([a, m])
        try await harness.startAndSettle()
        let client = harness.client
        let engine = await harness.engine()
        let origin = harness.source.originID
        // A prefetch transfer's 429 throttles the origin for 30 s.
        await harness.source.script(a.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(30))), .stage(bytesA)])
        let handle = client.prefetch([a.identifier])
        try await handle.awaitRegistration()
        await engine.awaitCondition { $0.state.throttles[origin] != nil }
        let end = try #require(await engine.kitRead { $0.state.throttles[origin] })
        let requests = await harness.source.manifestRequests.count
        let expected = end.seconds(since: harness.time.monotonicNow())
        await #expect(throws: AssetError.serverUnavailable(retryAfter: expected)) {
            try await client.ensureAvailable(scope: .identifiers([m.identifier]))
        }
        #expect(await harness.source.manifestRequests.count == requests, "the throttle refuses the fetch before any request")
        handle.cancel()
        await client.shutdown()
    }

    /// L4-R23 (manifest in hand): a member whose wait a throttle extension answered counts as missing, with the
    /// report's `manifestFresh`, and the call succeeds; the facade reports the engine's result as is.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: the facade's ensureAvailable reports a member a throttle answered as missing with a fresh manifest", .timeLimit(.minutes(1)))
    func ensureMemberAnsweredByThrottle() async throws {
        let harness = KitHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0))
        let bytesA = KitFixture.bytes(121)
        let bytesB = KitFixture.bytes(122)
        let bytesM = KitFixture.bytes(123)
        let a = KitFixture.entry("a", bytesA, policy: .onDemand)
        let b = KitFixture.entry("b", bytesB, policy: .onDemand)
        let m = KitFixture.entry("m", bytesM, policy: .onDemand)
        await harness.serveManifest([a, b, m])
        try await harness.startAndSettle()
        let client = harness.client
        let engine = await harness.engine()
        await harness.source.script(b.transferID, [.hold, .stage(bytesB)])
        await harness.source.script(a.transferID, [.hold, .stage(bytesA)])
        await harness.source.script(m.transferID, [.stage(bytesM)])
        let callerB = Task { try await client.resolve(b.identifier) }
        let callerA = Task { try await client.resolve(a.identifier) }
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.active != nil && $0.state.jobs[a.transferID]?.active != nil }
        let ensure = Task {
            try await client.ensureAvailable(scope: .identifiers([m.identifier]))
        }
        await engine.awaitCondition { $0.state.jobs[m.transferID]?.interests.values.contains { $0.kind == .ensure } == true }
        // A's 429 throttles the origin for 1 s: the member waits behind the throttle.
        await harness.source.release(a.transferID, with: .failed(.transient(.throttled, retryAfter: .seconds(1))))
        await engine.awaitCondition { $0.state.jobs[m.transferID]?.state.isThrottleParked == true }
        // B's 429 extends the throttle to 60 s, beyond interactiveMaxWait: the member's wait is answered.
        await harness.source.release(b.transferID, with: .failed(.transient(.throttled, retryAfter: .seconds(60))))
        let report = try await ensure.value
        #expect(report.manifestFresh, "the manifest was in hand")
        #expect(report.missing == 1 && report.present == 0 && report.failed == 0, "the member is missing: \(report)")
        callerA.cancel()
        callerB.cancel()
        _ = await callerA.result
        _ = await callerB.result
        await client.shutdown()
    }

    /// RECON §5: a present asset is served from local storage, offline from the cached manifest, with no transfer.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-1: a present asset resolves from local storage without any request, also offline", .timeLimit(.minutes(1)))
    func presentAssetResolvesLocally() async throws {
        let bytes = KitFixture.bytes(131)
        let entry = KitFixture.entry("a", bytes)
        let harness = KitHarness.make()
        await harness.serve([(entry, bytes)])
        try await harness.startAndSettle()
        let client = harness.client
        let requests = (await harness.source.manifestRequests.count, await harness.source.starts.count)
        var offline = DeviceConditions.unrestricted
        offline.network.satisfied = false
        await harness.conditions.send(offline)
        let url = try await client.resolve(entry.identifier)
        #expect(await MainActor.run { client.lookup(entry.identifier)?.url } == url)
        #expect(await harness.source.manifestRequests.count == requests.0)
        #expect(await harness.source.starts.count == requests.1)
        #expect(try await client.metrics().resolveHits == 1)
        await client.shutdown()
    }

    /// RECON §5: an on-demand resolve fetches that asset only; it never reconciles or downloads the rest of the
    /// catalog.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-1: an on-demand resolve downloads only the asset asked for", .timeLimit(.minutes(1)))
    func onDemandResolveFetchesOnlyItself() async throws {
        let entries = (0..<3).map { KitFixture.entry("od\($0)", KitFixture.bytes(140 + UInt64($0)), policy: .onDemand) }
        let harness = KitHarness.make()
        await harness.serveManifest(entries)
        try await harness.startAndSettle()
        await harness.source.script(entries[1].transferID, [.stage(KitFixture.bytes(141))])
        let client = harness.client
        _ = try await harness.withClock { () throws(AssetError) -> URL in
            try await client.resolve(entries[1].identifier)
        }
        #expect(await harness.source.starts.map(\.id) == [entries[1].transferID])
        let report = try await client.availability(scope: .all)
        #expect(report.present == 1 && report.missing == 2)
        await client.shutdown()
    }

    /// RECON §5's sync progress semantics: a run is announced, then finished with its outcome, on the client's
    /// stream; a shutdown ends it with `clientShutDown`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: the client's event stream reports a sync as started and then finished with its outcome, and ends with clientShutDown", .timeLimit(.minutes(1)))
    func eventsReportSync() async throws {
        let bytes = KitFixture.bytes(151)
        let entry = KitFixture.entry("a", bytes)
        let harness = KitHarness.make()
        let client = harness.client
        let probe = EventProbe(stream: client.events)
        await harness.serve([(entry, bytes)])
        try await harness.startAndSettle()
        let finished = await probe.next { event in
            if case .syncFinished = event {
                return true
            }
            return false
        }
        await client.shutdown()
        _ = await probe.next { $0 == .clientShutDown }
        let events = await probe.received
        await probe.stop()
        guard case .syncFinished(let run, .complete(let report))? = finished else {
            Issue.record("the launch run finished complete: \(String(describing: finished))")
            return
        }
        #expect(report.fetched == 1)
        let started = events.firstIndex { event in
            if case .syncStarted(let id, _) = event {
                return id == run
            }
            return false
        }
        let ended = events.firstIndex { $0 == finished }
        #expect(started != nil && ended != nil && started! < ended!, "started before finished")
        #expect(events.last == .clientShutDown, "clientShutDown is the last event")
    }
}
