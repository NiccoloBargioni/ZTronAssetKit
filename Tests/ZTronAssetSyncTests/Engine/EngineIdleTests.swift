import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Idle silence, `waitUntil`, shutdown and the last event (R-SYN-14, R-SYN-15, R-SYN-12).
@Suite("Engine idle and shutdown")
struct EngineIdleTests {
    /// Records the order in which concurrent waits returned.
    actor Order {
        private(set) var events: [String] = []

        func note(_ event: String) {
            self.events.append(event)
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-14: after a sync quiesces the engine owns zero timers and zero tasks and observes nothing", .timeLimit(.minutes(1)))
    func idleAfterSync() async throws {
        // The store's real coalescing and deletion grace leave deadlines the engine's alarm must drive.
        let harness = EngineHarness.make(commitInterval: 0.25, installInterval: 0.1)
        let catalog = EngineSyncTests.catalog(6)
        await harness.serve(catalog)
        try await harness.start()
        _ = try #require(try await harness.syncDriven().completeReport)
        // A prune leaves a doomed blob whose grace the alarm must reach.
        await harness.serveManifest(Array(catalog.dropFirst().map(\.0)), etag: "v2")
        let second = try await harness.syncDriven()
        _ = try #require(second.completeReport, "\(second)")
        try await harness.settle()
        let state = await harness.engine.introspect()
        #expect(state.isIdleSilent)
        #expect(state.armedTimers == 0 && state.ownedTasks == 0 && state.scheduledDeadlines == 0 && !state.watcherActive)
        #expect(harness.time.pendingSleepers == 0)
        #expect(await harness.source.activeTransfers == 0)
        try await harness.conditions.requireObservers(equalTo: 0)
        #expect(await harness.conditions.activeObservers == 0)
        #expect(await harness.store.nextDeadline() == nil, "every store deadline was driven")
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-14: waitUntil ends when its caller is cancelled, with the predicate unmet, and a later mutation resumes only the waiters still registered", .timeLimit(.minutes(1)))
    func waitUntilEndsOnCancellation() async throws {
        let harness = EngineHarness.make()
        let entry = EngineHarness.onDemand("x", EngineFixture.bytes(31))
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.hold])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let order = Order()
        let cancelled = Task {
            await engine.waitUntil { $0.waiters == 1 }
            await order.note("cancelled-returned:\(await engine.introspect().waiters)")
        }
        let kept = Task {
            await engine.waitUntil { $0.waiters == 1 }
            await order.note("kept-returned")
        }
        await engine.waitUntilObservers(2)
        cancelled.cancel()
        await cancelled.value
        #expect(await order.events == ["cancelled-returned:0"], "the cancelled wait returned with its predicate unmet")
        #expect(await engine.observerCount() == 1)
        let caller = Task { await engine.awaitAsset("x", lane: .userInitiated) }
        await kept.value
        #expect(await order.events == ["cancelled-returned:0", "kept-returned"])
        #expect(await engine.observerCount() == 0)
        caller.cancel()
        _ = await caller.value
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: shutdown mid-flight cancels every transfer, finishes every stream and leaves zero owned tasks, sleepers and observers", .timeLimit(.minutes(1)))
    func shutdownMidFlight() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 3, reservedInteractiveSlots: 0))
        let catalog = EngineSyncTests.catalog(5)
        let page = EngineHarness.onDemand("page", EngineFixture.bytes(32))
        await harness.serveManifest(catalog.map(\.0) + [page])
        for (entry, _) in catalog {
            await harness.source.script(entry.transferID, [.hold])
        }
        await harness.source.script(page.transferID, [.hold])
        try await harness.start()
        let engine = harness.engine
        let stream = try await engine.subscribe().get()
        let consumer = Task { () -> [AssetEvent] in
            var events: [AssetEvent] = []
            for await event in stream {
                events.append(event)
            }
            return events
        }
        let run = Task { await engine.sync(.force) }
        await engine.waitUntil { $0.running == 3 }
        let waiter = Task { await engine.awaitAsset("page", lane: .userInitiated) }
        await engine.waitUntil { $0.waiters == 1 }
        await engine.shutdown()
        #expect(await waiter.value == .failure(.shutDown))
        #expect(await run.value == .failed(.shutDown))
        let events = await consumer.value
        #expect(events.last == .clientShutDown)
        let state = await engine.introspect()
        #expect(state.lifecycle == .shutDown)
        #expect(state.ownedTasks == 0 && state.armedTimers == 0 && state.waiters == 0 && state.subscribers == 0)
        #expect(harness.time.pendingSleepers == 0)
        #expect(await harness.source.activeTransfers == 0)
        try await harness.conditions.requireObservers(equalTo: 0)
        #expect(await harness.source.isInvalidated)
        #expect(await engine.awaitAsset("page", lane: .userInitiated) == .failure(.shutDown))
        #expect(await engine.sync(.force) == .failed(.shutDown))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: concurrent shutdown calls are idempotent", .timeLimit(.minutes(1)))
    func concurrentShutdown() async throws {
        let harness = EngineHarness.make()
        try await harness.start()
        let engine = harness.engine
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await engine.shutdown() }
            }
        }
        #expect(await engine.introspect().lifecycle == .shutDown)
        await engine.shutdown()
        #expect(await engine.start() == .failure(.shutDown))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: shutdown in created never opens the store and every API fails with shutDown", .timeLimit(.minutes(1)))
    func shutdownBeforeStart() async throws {
        let harness = EngineHarness.make()
        let engine = harness.engine
        await engine.shutdown()
        #expect(harness.fileSystem.mutationCount == 0)
        #expect(await engine.start() == .failure(.shutDown))
        #expect(await engine.awaitAsset("x", lane: .userInitiated) == .failure(.shutDown))
        #expect(await engine.registerGroup(["x"], lane: .prefetch) == .failure(.shutDown))
        #expect(await engine.sync(.ifDue) == .failed(.shutDown))
        #expect(await engine.availability(scope: .all) == .failure(.shutDown))
        #expect(await engine.ensureAvailable(scope: .all) == .failure(.shutDown))
        #expect(await engine.isSyncDue() == .failure(.shutDown))
        #expect(await engine.lastSyncedAt() == .failure(.shutDown))
        #expect(await engine.setRetentionScope(.all).isShutDown)
        #expect(await engine.setPinned(["x"], pinned: true).isShutDown)
        #expect(await engine.purge(.all) == .failure(.shutDown))
        #expect(await engine.performMaintenance(timeBudget: 1) == .failure(.shutDown))
        #expect(await engine.reportUnreadable("x").isShutDown)
        #expect(await engine.storageReport() == .failure(.shutDown))
        #expect(await engine.metrics() == .failure(.shutDown))
        #expect(await engine.diagnostics() == .failure(.shutDown))
        #expect(await engine.acquireLease("x") == .failure(.shutDown))
        #expect(await engine.observeMemoryPressure(epoch: 1, handler: { _ in }).isShutDown)
        #expect(await engine.backgroundSessionEventsPending(identifier: "id").isShutDown)
        #expect((try? await engine.subscribe().get()) == nil)
        var events: [AssetEvent] = []
        for await event in engine.makeEventStream() {
            events.append(event)
        }
        #expect(events == [.clientShutDown])
        await engine.releaseGroup(InterestToken(rawValue: 1))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: clientShutDown is the last event every subscriber receives", .timeLimit(.minutes(1)))
    func clientShutDownIsLast() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(3)
        await harness.serve(catalog)
        try await harness.start()
        let engine = harness.engine
        let waiting = try await engine.subscribe().get()
        let lagging = try await engine.subscribe().get()
        let consumer = Task { () -> [AssetEvent] in
            var events: [AssetEvent] = []
            for await event in waiting {
                events.append(event)
            }
            return events
        }
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.waitUntil { $0.bufferedEvents >= 1 && $0.subscribers == 2 }
        await engine.shutdown()
        let waited = await consumer.value
        var lagged: [AssetEvent] = []
        for await event in lagging {
            lagged.append(event)
        }
        #expect(waited.last == .clientShutDown && waited.filter { $0 == .clientShutDown }.count == 1)
        #expect(lagged.last == .clientShutDown && lagged.filter { $0 == .clientShutDown }.count == 1)
        #expect(lagged.contains { if case .syncFinished = $0 { return true } else { return false } })
        #expect(await engine.introspect().subscribers == 0)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: no store mutation or commit happens after close returns", .timeLimit(.minutes(1)))
    func noMutationAfterClose() async throws {
        let bulk = NextUnitGate()
        let harness = EngineHarness.make(bulk: bulk, commitInterval: 0.25)
        let catalog = EngineSyncTests.catalog(4)
        await harness.serve(catalog)
        try await harness.start()
        let engine = harness.engine
        _ = try #require(try await harness.syncDriven().completeReport)
        // v2 prunes a0 (its blob's deletion becomes due work) and adds b0, whose transfer is held.
        let addedBytes = EngineFixture.bytes(77)
        let added = EngineFixture.entry("b0", addedBytes)
        await harness.serveManifest(catalog.dropFirst().map(\.0) + [added], etag: "v2")
        await harness.source.script(added.transferID, [.hold, .stage(addedBytes)])
        let run = Task { await engine.sync(.force) }
        // The run applies v2 (its commit window passes on the clock) and starts b0.
        try await harness.drive(maxStep: 1) { $0.running == 1 }
        await engine.waitForHandle(added.transferID)
        // b0 stages; its publication is held at its first store unit (verifying, with a coalesced commit to follow).
        await bulk.holdNext()
        await harness.source.release(added.transferID, with: .progress(received: 0, expected: nil))
        await bulk.waitForHold()
        #expect(await engine.introspect().jobsByState[.verifying] == 1)
        let shutdown = Task { await engine.shutdown() }
        await engine.waitUntil { $0.lifecycle == .shuttingDown }
        await bulk.release()
        // Shutdown joins the publication, whose commit window needs the clock, then closes the store.
        await harness.withClock {
            await EngineHarness.value(of: shutdown)
        }
        _ = await run.value
        // The baseline is close's return: the store releases its lock last.
        let operations = harness.fileSystem.operations
        let closed = try #require(operations.lastIndex { $0.kind == .releaseLock }, "close released the lock")
        #expect(!operations[(closed + 1)...].contains { $0.kind.isMutation }, "no mutation after the lock was released")
        #expect(operations[..<closed].contains { $0.kind == .rename && $0.destination?.lastPathComponent == "index.bin" })
        // Nothing the engine still has can touch the store: every API fails, nothing sleeps, nothing is owned.
        #expect(await engine.awaitAsset("a1", lane: .userInitiated) == .failure(.shutDown))
        #expect(await engine.performMaintenance(timeBudget: 10) == .failure(.shutDown))
        await engine.releaseLease(AssetLease(id: "a1", blob: BlobKey(hash: ContentHash.sha256(of: Data()), ext: AssetFileExtension("png")!), token: 1, url: EngineHarness.base))
        #expect(await engine.introspect().ownedTasks == 0)
        #expect(harness.time.pendingSleepers == 0, "no sleeper is left that could wake and write")
        // With no owned task and no sleeper, moving the clock wakes nothing: the record is final.
        harness.time.advance(by: 3_600)
        let after = harness.fileSystem.operations
        #expect(after.count == operations.count)
        #expect(!after[(closed + 1)...].contains { $0.kind.isMutation })
    }
}

extension Result where Success == Void, Failure == AssetError {
    /// Whether the result is `.failure(.shutDown)`.
    var isShutDown: Bool {
        if case .failure(.shutDown) = self {
            return true
        }
        return false
    }
}
