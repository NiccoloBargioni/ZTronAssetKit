import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

extension SyncEngine {
    /// Test seam: asks for a transition the way the engine does (the one mutator of a job's state).
    func attemptTransition(_ transfer: TransferID, to next: JobState) -> Bool {
        self.transition(transfer, to: next)
    }

    /// Test seam: the entries the lane queues store, live and stale.
    func queueStoredCount() -> Int {
        self.state.queues.storedCount
    }

    /// Test seam: applies `edit` (a state no correct path produces), then lets the run settle as it would after any
    /// mutation; the run's settlement afterwards.
    func settleRunAfter(_ edit: @Sendable (inout EngineState) -> Void) -> RunSettlement? {
        edit(&self.state)
        self.checkRunSettled()
        return self.state.run?.settlement
    }
}

/// The engine's safety nets: validated transitions (R-SYN-2), bounded lane queues (R-SYN-3, sync.md §7.2), answers for
/// joiners of parked jobs (R-SYN-4), a run that cannot be stranded by a lost claim (R-SYN-6) and a source built while
/// shutdown began (R-SYN-15, RE-S03).
@Suite("Engine safety nets")
struct EngineSafetyTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: an illegal transition is counted and logged, never applied", .timeLimit(.minutes(1)))
    func illegalTransitionIsRefused() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(1_700)
        let entry = EngineHarness.onDemand("t", bytes)
        await harness.serveManifest([entry])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        let group = try await engine.registerGroup(["t"], lane: .prefetch).get()
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(entry.transferID)
        // downloading → committing skips verification: refused.
        #expect(await engine.attemptTransition(entry.transferID, to: .committing) == false)
        #expect(try await engine.metrics().get().illegalTransitions == 1)
        #expect(await engine.introspect().jobsByState == [.downloading: 1], "the job's state is unchanged")
        #expect(harness.tap.lines.contains { $0.message.contains("illegal transition downloading → committing") })
        // The job goes on as if nothing was asked.
        await harness.source.release(entry.transferID, with: .progress(received: 0, expected: nil))
        await engine.waitForJobEnd(entry.transferID)
        #expect(try await engine.awaitAsset("t", lane: .userInitiated).get().byteSize == Int64(bytes.count))
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: lane queues stay within twice their live entries while queued jobs move between lanes", .timeLimit(.minutes(1)))
    func laneQueuesStayCompact() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0, preemptLowerLanes: false))
        let entries = (0..<12).map { EngineHarness.onDemand("q\($0)", EngineFixture.bytes(UInt64(1_800 + $0))) }
        await harness.serveManifest(entries)
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        // The first prefetch holds the only slot; the others queue.
        await harness.source.script(entries[0].transferID, [.hold])
        let group = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        await engine.waitUntil { $0.running == 1 && ($0.queued[.prefetch] ?? 0) == entries.count - 1 }
        await engine.waitForHandle(entries[0].transferID)
        // Each user resolve moves a queued job to the user queue, its cancellation moves it back: two stale entries.
        for round in 0..<4 {
            for entry in entries.dropFirst() {
                let resolve = Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) }
                await engine.waitUntil { $0.waiters == 1 && ($0.queued[.userInitiated] ?? 0) == 1 }
                resolve.cancel()
                #expect(await resolve.value == .failure(.cancelled))
                await engine.waitUntil { $0.waiters == 0 }
            }
            let stored = await engine.queueStoredCount()
            #expect(stored <= 2 * entries.count + 16, "round \(round): \(stored) stored entries for \(entries.count) jobs")
            #expect(await engine.invariantViolations().isEmpty, "round \(round)")
        }
        #expect(await engine.introspect().queued == [.prefetch: entries.count - 1], "every job is back in its own lane")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a resolve that joins a job waiting to be online is answered offline at once", .timeLimit(.minutes(1)))
    func joinerOfOfflineJobFailsFast() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(1_900)
        let entry = EngineHarness.onDemand("w", bytes)
        await harness.serveManifest([entry])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(entry.transferID, [.fail(.offline(.noConnection))])
        // A prefetch is not failed fast: its job waits, failed until the path comes back.
        let group = try await engine.registerGroup(["w"], lane: .prefetch).get()
        await engine.waitUntil { ($0.jobsByState[.failed] ?? 0) == 1 }
        // A resolve below the user lane does not skip that wait: it gets the answer a new job would get.
        #expect(await engine.awaitAsset("w", lane: .prefetch) == .failure(.offline))
        #expect(await harness.source.starts.count == 1)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run whose claimed job vanished without an outcome still settles, and counts the asset as failed", .timeLimit(.minutes(1)))
    func lostClaimStillSettles() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(1)
        let (entry, _) = catalog[0]
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.hold])
        try await harness.start()
        let engine = harness.engine
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(entry.transferID)
        let run = Task { await engine.sync(.force) }
        await engine.awaitCondition { !$0.state.syncJoiners.isEmpty }
        // No correct path drops a job the run claims without telling it; the safety net still lets the run settle.
        let settlement = await engine.settleRunAfter { state in
            state.jobs[entry.transferID]?.interests.removeAll()
        }
        #expect(settlement == .finished)
        let outcome = await run.value
        guard case .completeWithFailures(let report) = outcome else {
            Issue.record("expected the run to settle with the lost asset failed, got \(outcome)")
            await engine.shutdown()
            return
        }
        #expect(report.failures.map(\.id) == [entry.identifier])
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: a source built after shutdown began is invalidated at once and start fails with shutDown", .timeLimit(.minutes(1)))
    func sourceBuiltDuringShutdown() async throws {
        let source = FakeRemoteSource()
        let factory = GatedSourceFactory(source: source)
        let harness = EngineHarness.make(source: source, factory: factory)
        let engine = harness.engine
        let start = Task { await engine.start() }
        await factory.waitUntilEntered()
        let shutdown = Task { await engine.shutdown() }
        await engine.waitUntil { $0.lifecycle == .shuttingDown }
        await factory.open()
        #expect(await start.value.map { _ in true } == .failure(.shutDown))
        await shutdown.value
        #expect(await source.isInvalidated, "the source was invalidated as soon as it was built")
        #expect(await engine.introspect().ownedTasks == 0)
        #expect(await engine.awaitAsset("x", lane: .userInitiated) == .failure(.shutDown))
    }
}
