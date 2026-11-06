import Foundation
import Testing
@testable import ZTronAssetKit
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Requirements-lens verifier probes (close-out cycle 1). Scratch copy only, never committed.
@Suite("Verifier reqs probes")
struct VerifierReqsProbes {
    /// The vanished-root helper of `FacadeReopenTests` without its own `serve` (the probe served before start).
    @available(macOS 15.0, iOS 18.0, *)
    static func vanishNoServe(_ harness: KitHarness) async throws -> ClientCore {
        try await harness.startAndSettle()
        let core = await harness.client.lifecycle.current()
        let lock = try #require(harness.fileSystem.operations.last { $0.kind == .acquireExclusiveLock }?.url)
        try wipe(lock.deletingLastPathComponent(), in: harness.fileSystem)
        let store = core.store
        await #expect(throws: StoreError.storageUnavailable(.rootVanished)) {
            try await harness.withClock { () throws(StoreError) in
                try await store.markSyncDue()
            }
        }
        return core
    }

    /// PROBE-F1: `syncAndEventsFollowReopen` with the interleaving its flaky run took forced: generation 0's launch run
    /// fetches the scripted manifest and downloads the asset before the root vanishes. The test's claim "the
    /// replacement's source attach starts a fresh transport log" is checked directly.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-F1: the transport log is not reset by a reopen's attach", .timeLimit(.minutes(1)))
    func probeTransportLogNotReset() async throws {
        let bytes = KitFixture.bytes(161)
        let entry = KitFixture.entry("a", bytes)
        let harness = KitHarness.make()
        let client = harness.client
        await harness.serve([(entry, bytes)])
        let probe = EventProbe(stream: try await harness.withClock { () throws(AssetError) in
            try await client.subscribe()
        })
        let old = try await VerifierReqsProbes.vanishNoServe(harness)
        let startsBeforeReopen = await harness.source.starts.filter { $0.id == entry.transferID }.count
        let manifest = KitFixture.manifestData([entry])
        await harness.source.scriptManifest([.fetched(manifest, etag: KitFixture.etag("v2")), .fetched(manifest, etag: KitFixture.etag("v3"))])
        await harness.source.script(entry.transferID, [.stage(bytes)])
        let outcome = await harness.syncDriven(.force)
        let replacement = await client.lifecycle.current()
        let all = await harness.source.starts.filter { $0.id == entry.transferID }
        print("PROBE-F1 generation=\(replacement.generation) (old \(old.generation)) outcome=\(outcome) startsBeforeReopen=\(startsBeforeReopen) startsTotal=\(all.count) attempts=\(all.map { "\($0.attempt) \($0.priority)" })")
        #expect(startsBeforeReopen == 1, "setup: generation 0 downloaded the asset before the root vanished")
        // The assertion of FacadeReopenTests.swift:124, unchanged:
        #expect(all.count == 1, "FacadeReopenTests.swift:124's assertion under this interleaving: \(all.count)")
        // What the test means: the replacement's own starts.
        #expect(all.count - startsBeforeReopen == 1, "the replacement downloaded the asset once")
        await client.shutdown()
        await probe.stop()
    }

    /// PROBE-R1: a `subscribe()` stream (registered with generation 0 before it returns) that the consumer has not
    /// pulled yet when a reopen installs the replacement. L5-R3's invariant: a live consumer stream receives every event
    /// the replacement publishes, from its first one on (its `clientStarted` included, G-2).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-R1: a subscribe() stream not yet pulled at a reopen receives the replacement's clientStarted", .timeLimit(.minutes(1)))
    func probeSubscribeUnpulledAcrossReopen() async throws {
        try await VerifierReqsProbes.subscribeAcrossReopen(pullBefore: false)
    }

    /// PROBE-R1 control: the same with one pull before the reopen (the pump registered as a follower).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-R1 control: a subscribe() stream pulled once before a reopen receives the replacement's clientStarted", .timeLimit(.minutes(1)))
    func probeSubscribePulledAcrossReopen() async throws {
        try await VerifierReqsProbes.subscribeAcrossReopen(pullBefore: true)
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func subscribeAcrossReopen(pullBefore: Bool) async throws {
        let harness = KitHarness.make()
        let client = harness.client
        try await harness.startAndSettle()
        let stream = try await harness.withClock { () throws(AssetError) in
            try await client.subscribe()
        }
        let gen0 = await client.lifecycle.current()
        #expect(await gen0.engine.introspect().subscribers == 1, "setup: subscribe() registered with generation 0 before it returned")
        var iterator = stream.makeAsyncIterator()
        var received: [AssetEvent] = []
        if pullBefore, let first = await iterator.next() {
            received.append(first)
        }
        try FacadeRaceTests.wipeRoot(harness)
        _ = try await harness.withClock { () throws(AssetError) -> PurgeResult in
            try await client.purge(.all)
        }
        let replacement = await client.lifecycle.current()
        #expect(replacement.generation == 1, "setup: one reopen")
        let expected = await replacement.engine.kitRead { $0.state.launch?.report.generation }
        let subscribersAfterReopen = await replacement.engine.introspect().subscribers
        let marker = Task { () -> Bool in
            await replacement.engine.waitUntil { $0.subscribers >= 1 }
            do throws(AssetError) {
                _ = try await harness.withClock { () throws(AssetError) -> MaintenanceReport in
                    try await client.performMaintenance(timeBudget: 1)
                }
                return true
            } catch {
                return false
            }
        }
        while let event = await iterator.next() {
            received.append(event)
            if case .maintenanceFinished = event {
                break
            }
        }
        #expect(await marker.value, "setup: the marker's maintenance ran on the replacement")
        let starts = received.filter { event in
            if case .clientStarted = event {
                return true
            }
            return false
        }
        print("PROBE-R1 pullBefore=\(pullBefore) subscribersOnReplacementRightAfterReopen=\(subscribersAfterReopen) clientStarted=\(starts) expected=\(String(describing: expected)) received=\(received.count)")
        #expect(expected.map { starts.contains(.clientStarted(generation: $0)) } == true, "the replacement's clientStarted reached the consumer: \(received)")
        await client.shutdown()
    }
}

extension VerifierReqsProbes {
    /// PROBE-P1 (instrumented copy of `promotionNeverRestarts`, unchanged synchronisation): before each move it records
    /// whether the page that was current had already received its user-initiated interest (the promotion's join ran).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-P1: promotionNeverRestarts instrumented", .timeLimit(.minutes(1)))
    func probePromotionInstrumented() async throws {
        try await VerifierReqsProbes.promotion(waitForJoin: false)
    }

    /// PROBE-P2: the same with one more wait per move: the current page's user-initiated join reached its job.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-P2: promotionNeverRestarts with a wait for each promotion's join", .timeLimit(.minutes(1)))
    func probePromotionWithJoinWait() async throws {
        try await VerifierReqsProbes.promotion(waitForJoin: true)
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func promotion(waitForJoin: Bool) async throws {
        let harness = KitHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 8))
        let client = harness.client
        let entries = (0..<1_002).map { KitFixture.entry("p\($0)", KitFixture.bytes(100 + UInt64($0)), policy: .onDemand) }
        await harness.serveManifest(entries)
        try await harness.startAndSettle()
        let ids = entries.map(\.identifier)
        let source = harness.source
        let engine = await harness.engine()
        let controller = PrefetchWindowController(client: client, radius: 1)
        var movedBeforeJoin: [Int] = []
        for current in 0...1_000 {
            if current >= 2 {
                let previous = entries[current - 1].transferID
                let joined = await engine.kitRead { engine in
                    engine.state.jobs[previous]?.interests.values.contains { $0.lane == .userInitiated } == true
                }
                if !joined {
                    movedBeforeJoin.append(current - 1)
                }
            }
            await MainActor.run {
                controller.update(ids: ids, current: current)
            }
            if waitForJoin, current >= 1 {
                let page = entries[current].transferID
                await engine.awaitCondition { engine in
                    engine.state.jobs[page]?.interests.values.contains { $0.lane == .userInitiated } == true
                }
            }
            let next = entries[current + 1].transferID
            await engine.awaitCondition { PrefetchFacadeTests.inFlight(next, $0) }
        }
        await engine.awaitCondition { $0.state.groups.count == 3 }
        let starts = await source.starts.map(\.id)
        var startsByTransfer: [TransferID: Int] = [:]
        for id in starts {
            startsByTransfer[id, default: 0] += 1
        }
        let restarted = startsByTransfer.filter { $0.value > 1 }
        let promoted = await source.controlLog.filter { $0.control == .setPriority(.userInitiated) }.map(\.transfer)
        let promotedSet = Set(promoted)
        let unpromoted = (1...1_000).filter { !promotedSet.contains(entries[$0].transferID) }
        print("PROBE-P waitForJoin=\(waitForJoin) promotions=\(promoted.count) restarted=\(restarted.count) unpromotedPages=\(unpromoted) pagesTheWindowLeftBeforeTheirJoin=\(movedBeforeJoin.prefix(20)) (\(movedBeforeJoin.count))")
        #expect(restarted.isEmpty, "\(restarted.count) transfers started more than once")
        #expect(promoted.count == 1_000, "every promotion reached the transport as a priority change: \(promoted.count)")
        await MainActor.run {
            controller.cancelAll()
        }
        await engine.waitUntil { $0.groups == 0 }
        await client.shutdown()
    }
}

extension VerifierReqsProbes {
    /// PROBE-R2: as PROBE-R1, for a terminal asset event (R-SYN-12: terminal events never dropped) that the replacement
    /// publishes after the reopen and before the consumer's first pull.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-R2: a subscribe() stream not yet pulled at a reopen receives the replacement's assetAvailable", .timeLimit(.minutes(1)))
    func probeSubscribeUnpulledAssetEvent() async throws {
        try await VerifierReqsProbes.assetEventAcrossReopen(pullBefore: false)
    }

    /// PROBE-R2 control: one pull before the reopen.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-R2 control: a subscribe() stream pulled once before a reopen receives the replacement's assetAvailable", .timeLimit(.minutes(1)))
    func probeSubscribePulledAssetEvent() async throws {
        try await VerifierReqsProbes.assetEventAcrossReopen(pullBefore: true)
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func assetEventAcrossReopen(pullBefore: Bool) async throws {
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
        let stream = try await harness.withClock { () throws(AssetError) in
            try await client.subscribe()
        }
        var iterator = stream.makeAsyncIterator()
        var received: [AssetEvent] = []
        if pullBefore, let first = await iterator.next() {
            received.append(first)
        }
        try FacadeRaceTests.wipeRoot(harness)
        _ = try await harness.withClock { () throws(AssetError) -> PurgeResult in
            try await client.purge(.all)
        }
        let replacement = await client.lifecycle.current()
        #expect(replacement.generation == 1, "setup: one reopen")
        await harness.source.script(entry.transferID, [.stage(bytes)])
        let url = try await harness.withClock { () throws(AssetError) -> URL in
            try await client.resolve("x")
        }
        #expect(url.lastPathComponent.hasSuffix(".png"), "setup: the replacement served the resolve")
        await client.shutdown()
        while let event = await iterator.next() {
            received.append(event)
        }
        let available = received.contains { event in
            if case .assetAvailable(let id, _) = event, id == "x" {
                return true
            }
            return false
        }
        print("PROBE-R2 pullBefore=\(pullBefore) assetAvailable(x)=\(available) received=\(received)")
        #expect(available, "the replacement's assetAvailable(x) reached the subscriber: \(received)")
    }
}
