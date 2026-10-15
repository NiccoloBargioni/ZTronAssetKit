import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Event broadcast and backpressure (R-SYN-12, H-9, ADR-023).
@Suite("Engine events")
struct EngineEventsTests {
    // Three minutes, not one: the sync takes about 10 s on macOS but 58 s under the thread sanitizer and 36 to 57 s on
    // the iOS Simulator under load, where an overrun restarts the runner (F-17). No assertion depends on the limit.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a stalled subscriber's backlog never exceeds one slot per progress key and subject during a 10,000-asset sync", .timeLimit(.minutes(3)))
    func stalledSubscriberIsBounded() async throws {
        let concurrency = 8
        // Index commits of 10,000 records are coalesced to one per hour of manual time (the run needs very few), and
        // the manifest deadline is far beyond any step the clock is driven by.
        let tuning = SyncTuning(maxConcurrentTransfers: concurrency, reservedInteractiveSlots: 0, runLookahead: 32, manifestFetchDeadline: 1_000_000)
        let harness = EngineHarness.make(tuning: tuning, commitInterval: 3_600, installInterval: 0.1)
        let catalog = (0..<10_000).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(UInt64(10_000 + index), count: 16)
            return (EngineFixture.entry("e\(index)", bytes), bytes)
        }
        await harness.serve(catalog)
        let engine = harness.engine
        // Subscribed before `start()`, so the stalled subscriber sees the launch run from its first event.
        let stalled = try await engine.subscribe().get()
        // Every mutation re-evaluates condition waits: this one samples the backlog after each and never holds. It and
        // the wait for the transfers read the engine directly: an introspection snapshot per mutation (what `waitUntil`
        // evaluates) would dominate a 10,000-asset sync under the thread sanitizer (F-17).
        let peak = Mutex(0)
        let (registered, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let sampler = Task {
            await engine.awaitCondition { engine in
                let backlog = engine.state.subscribers.values.reduce(0) { $0 + $1.liveCount }
                peak.withLock { $0 = max($0, backlog) }
                signal.yield()
                return false
            }
        }
        // The first evaluation runs in the turn that registers the sampler, before `start()` reaches the engine.
        var registration = registered.makeAsyncIterator()
        _ = await registration.next()
        try await harness.start()
        // Commit windows and install intervals pass on the manual clock; the manifest deadline must not.
        // The clock moves only for the run's two commits: `apply` (once the manifest is fetched) and the stamp.
        try await harness.drive(maxStep: 3_600) { !$0.jobsByState.isEmpty || $0.groups == 0 }
        await engine.awaitCondition { $0.state.jobs.isEmpty }
        try await harness.drive(maxStep: 3_600) { $0.groups == 0 }
        sampler.cancel()
        await sampler.value
        signal.finish()
        // Progress keys: at most one transfer key per running non-bulk transfer (none here) plus run, snapshot and
        // conditions; subjects: client, run started, run finished, breaker, maintenance (bulk outcomes fold).
        let bound = (concurrency + 3) + 5
        #expect(peak.withLock { $0 } <= bound, "peak backlog \(peak.withLock { $0 })")
        #expect(peak.withLock { $0 } >= 3, "the stalled subscriber did accumulate a backlog")
        await engine.shutdown()
        var slots: [EventSlot] = []
        var fetched = 0
        for await event in stalled {
            slots.append(EventSlot(event))
            if case .syncFinished(_, .complete(let report)) = event {
                fetched = report.fetched
            }
        }
        #expect(fetched == 10_000, "the launch run fetched the whole catalog")
        #expect(Set(slots).count == slots.count, "one event per key or subject: \(slots)")
        #expect(slots.last == .client)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: transfer progress published to subscribers never exceeds 10 Hz per asset under ManualTimeSource", .timeLimit(.minutes(1)))
    func progressIsRateLimited() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(160)
        let entry = EngineHarness.onDemand("viewed", bytes)
        await harness.serveManifest([entry])
        let rounds = 50
        await harness.source.script(entry.transferID, [.progress(1), .progress(2), .progress(3), .hold] + Array(repeating: FakeTransferStep.hold, count: rounds) + [.stage(bytes)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let stream = try await engine.subscribe().get()
        let collector = Task { () -> [AssetEvent] in
            var progress: [AssetEvent] = []
            for await event in stream {
                if case .transferProgress = event {
                    progress.append(event)
                }
                if case .clientShutDown = event {
                    break
                }
            }
            return progress
        }
        let waiter = Task { await engine.awaitAsset("viewed", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        for round in 0..<rounds {
            await harness.source.release(entry.transferID, with: .progress(received: Int64(10 + round), expected: Int64(bytes.count)))
            harness.time.advance(by: 0.02)
            await engine.waitUntil { $0.running == 1 }
        }
        await harness.source.release(entry.transferID, with: .progress(received: Int64(bytes.count), expected: Int64(bytes.count)))
        _ = try await waiter.value.get()
        await engine.shutdown()
        let progress = await collector.value
        let elapsed = Double(rounds) * 0.02
        let ceiling = 1 + Int((elapsed / 0.1).rounded(.up)) + 1
        #expect(progress.count >= 2, "progress flows")
        #expect(progress.count <= ceiling, "\(progress.count) progress events in \(elapsed) s")
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a subscriber cancelled while waiting is removed and its pending pull returns nil", .timeLimit(.minutes(1)))
    func cancelledSubscriberIsRemoved() async throws {
        let harness = EngineHarness.make()
        try await harness.start()
        let engine = harness.engine
        let stream = try await engine.subscribe().get()
        let consumer = Task { () -> Int in
            var count = 0
            for await _ in stream {
                count += 1
            }
            return count
        }
        await engine.waitUntil { $0.subscribers == 1 && $0.bufferedEvents == 0 }
        consumer.cancel()
        _ = await consumer.value
        await engine.waitUntil { $0.subscribers == 0 }
        #expect(await engine.introspect().subscribers == 0)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a subscriber that breaks out of its loop is removed when its stream is released", .timeLimit(.minutes(1)))
    func releasedStreamIsRemoved() async throws {
        let harness = EngineHarness.make()
        try await harness.start()
        let engine = harness.engine
        var first: AssetEvent?
        do {
            let stream = engine.makeEventStream()
            for await event in stream {
                first = event
                break
            }
        }
        guard case .snapshotChanged? = first else {
            Issue.record("expected the snapshot replay first, got \(String(describing: first))")
            return
        }
        await engine.waitUntil { $0.subscribers == 0 }
        #expect(await engine.introspect().subscribers == 0)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a new subscriber first receives the current snapshot and run progress", .timeLimit(.minutes(1)))
    func lateSubscriberReplay() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(2)
        await harness.serveManifest(catalog.map(\.0))
        for (entry, bytes) in catalog {
            await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        }
        try await harness.start()
        let engine = harness.engine
        let run = Task { await engine.sync(.force) }
        await engine.waitUntil { $0.running == 2 }
        let stream = try await engine.subscribe().get()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()
        guard case .snapshotChanged? = first, case .conditionsChanged? = second, case .syncStarted? = third else {
            Issue.record("unexpected replay \(String(describing: first)), \(String(describing: second)), \(String(describing: third))")
            return
        }
        for (entry, _) in catalog {
            await harness.source.release(entry.transferID, with: .progress(received: 0, expected: nil))
        }
        _ = await run.value
        await engine.shutdown()
    }
}
