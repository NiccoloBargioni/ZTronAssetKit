import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Event broadcast and backpressure (R-SYN-12, H-9, ADR-023).
@Suite("Engine events")
struct EngineEventsTests {
    // Four minutes: the sync takes about 4 s in debug and 16 s under the thread sanitizer alone, but its in-suite
    // sanitizer time grows with the host's load (115 s at a load of about 25 and 151 s near 73 before L4-R8 cut the
    // engine's per-pump and per-settle passes; F-17). An overrun restarts the simulator runner (ios.md item 8). No
    // assertion depends on the limit. `harness.start()` raises the engine's utility-priority tasks (the run and its bulk
    // drivers) to the default priority: beside 16 default-QoS busy loops on 8 cores the test overran its limit at
    // 258 s, every transfer's actor hand-offs waiting for the scheduler's share of a starved priority class, and took
    // 45 s once raised (close-out cycle 13, F-17).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a stalled subscriber's backlog never exceeds one slot per progress key and subject during a 10,000-asset sync", .timeLimit(.minutes(4)))
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
        // Subscribed before `start()`, so the stalled subscriber sees the launch run from its first event. Its queue
        // records the most live slots it ever held, at every publication (no sampler evaluated after each mutation).
        let stalled = try await engine.subscribe().get()
        try await harness.start()
        // Commit windows and install intervals pass on the manual clock; the manifest deadline must not.
        // The clock moves only for the run's two commits: `apply` (once the manifest is fetched) and the stamp. The wait
        // for the transfers reads the engine directly: an introspection snapshot per mutation (what `waitUntil`
        // evaluates) would dominate a 10,000-asset sync under the thread sanitizer (F-17).
        try await harness.drive(maxStep: 3_600) { !$0.jobsByState.isEmpty || $0.groups == 0 }
        await engine.awaitCondition { $0.state.jobs.isEmpty }
        try await harness.drive(maxStep: 3_600) { $0.groups == 0 }
        let peak = await engine.peakSubscriberBacklogForTests()
        // Progress keys: at most one transfer key per running non-bulk transfer (none here) plus run, snapshot and
        // conditions; subjects: client, run started, run finished, breaker, maintenance (bulk outcomes fold).
        let bound = (concurrency + 3) + 5
        #expect(peak <= bound, "peak backlog \(peak)")
        #expect(peak >= 3, "the stalled subscriber did accumulate a backlog")
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
        let transfer = entry.transferID
        let slot = EventSlot.transfer("viewed")
        // The three updates before the hold, all at the start instant: the first is published, the other two leave a
        // trailing emission for the interval's end.
        await engine.awaitCondition { $0.state.jobs[transfer]?.active?.bytesReceived == 3 }
        for round in 0..<rounds {
            // Each round starts once the collector has pulled everything published so far, so no emission is coalesced
            // into a later one because the collector was not scheduled (the queue coalesces newest-wins per key and
            // retires the key with the transfer, §7.9).
            await engine.awaitCondition { $0.state.subscribers.values.allSatisfy { $0.liveCount == 0 } }
            await harness.source.release(transfer, with: .progress(received: Int64(10 + round), expected: Int64(bytes.count)))
            // The engine applies this round's update at this round's instant, before the clock moves (L4-C10-08)...
            await engine.awaitCondition { $0.state.jobs[transfer]?.active?.bytesReceived == Int64(10 + round) }
            harness.time.advance(by: 0.02)
            // ...and a trailing emission the move made due is flushed at its own instant, before the next update.
            let now = harness.time.monotonicNow()
            await engine.awaitCondition { engine in
                engine.state.heap.deadline(for: .progress(slot)).map { $0 > now } ?? true
            }
        }
        await engine.awaitCondition { $0.state.subscribers.values.allSatisfy { $0.liveCount == 0 } }
        await harness.source.release(transfer, with: .progress(received: Int64(bytes.count), expected: Int64(bytes.count)))
        _ = try await waiter.value.get()
        await engine.shutdown()
        let progress = await collector.value
        let elapsed = Double(rounds) * 0.02
        let interval = harness.configuration.tuning.progressInterval
        let ceiling = 1 + Int((elapsed / 0.1).rounded(.up)) + 1
        // Every update is applied, and every trailing emission flushed, at its own instant: one emission at the start,
        // then one per elapsed interval; the last update, inside the last interval, is retired with the transfer.
        let expected = 1 + Int((elapsed / interval).rounded(.down))
        #expect(progress.count >= 2, "progress flows")
        #expect(progress.count == expected, "\(progress.count) progress events in \(elapsed) s, \(expected) expected")
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

extension SyncEngine {
    /// Test seam: the most live slots any subscriber queue held (R-SYN-12's bound).
    func peakSubscriberBacklogForTests() -> Int {
        self.state.subscribers.values.map(\.peakLiveCount).max() ?? 0
    }
}
