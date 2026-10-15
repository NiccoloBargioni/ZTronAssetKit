import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Lanes, promotion and preemption (R-SYN-3, R-NET-10, H-4).
@Suite("Engine lanes")
struct EngineLaneTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a userInitiated request for an in-flight bulk asset promotes it without restarting the transfer", .timeLimit(.minutes(1)))
    func promotesInFlightBulk() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(21)
        let entry = EngineFixture.entry("bulk", bytes)
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        try await harness.start()
        let engine = harness.engine
        let run = Task { await engine.sync(.force) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(entry.transferID)
        let user = Task { await engine.awaitAsset("bulk", lane: .userInitiated) }
        await engine.waitUntil { $0.waiters == 1 }
        #expect(await harness.source.controlLog == [FakeControlRecord(transfer: entry.transferID, control: .setPriority(.userInitiated))])
        #expect(try await engine.metrics().get().promotions == 1)
        await harness.source.release(entry.transferID, with: .progress(received: 0, expected: nil))
        let location = try await user.value.get()
        #expect(location.id == "bulk")
        #expect(await run.value.completeReport?.fetched == 1)
        #expect(await harness.source.starts.count == 1, "the transfer was not restarted")
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-10: a promoted asset's priority change reaches the transport before any other transfer starts", .timeLimit(.minutes(1)))
    func promotionPrecedesNextStart() async throws {
        // Two slots, one reserved for user work: bulk runs one transfer at a time until the first is promoted.
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 1))
        let first = EngineFixture.entry("first", EngineFixture.bytes(22))
        let second = EngineFixture.entry("second", EngineFixture.bytes(23))
        await harness.serveManifest([first, second])
        await harness.source.script(first.transferID, [.hold, .stage(EngineFixture.bytes(22))])
        await harness.source.script(second.transferID, [.hold, .stage(EngineFixture.bytes(23))])
        try await harness.start()
        let engine = harness.engine
        let run = Task { await engine.sync(.force) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(first.transferID)
        #expect(await harness.source.starts.map(\.id) == [first.transferID])
        let user = Task { await engine.awaitAsset("first", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 2 }
        await engine.waitForHandle(second.transferID)
        let log = harness.source.transportLog.events
        let promotion = log.firstIndex(of: .controlled(FakeControlRecord(transfer: first.transferID, control: .setPriority(.userInitiated))))
        let nextStart = log.firstIndex { event in
            if case .started(let request) = event {
                return request.id == second.transferID
            }
            return false
        }
        let promoted = try #require(promotion)
        let started = try #require(nextStart)
        #expect(promoted < started)
        await harness.source.release(first.transferID, with: .progress(received: 0, expected: nil))
        await harness.source.release(second.transferID, with: .progress(received: 0, expected: nil))
        _ = await user.value
        #expect(await run.value.completeReport?.fetched == 2)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: with concurrency 1 a userInitiated request preempts the bulk transfer, which later resumes", .timeLimit(.minutes(1)))
    func preemptsAndResumes() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 1))
        let bulkBytes = EngineFixture.bytes(24)
        let bulk = EngineFixture.entry("bulk", bulkBytes)
        let pageBytes = EngineFixture.bytes(25)
        let page = EngineHarness.onDemand("page", pageBytes)
        await harness.serveManifest([bulk, page])
        await harness.source.script(bulk.transferID, [.hold, .stage(bulkBytes)])
        await harness.source.script(page.transferID, [.stage(pageBytes)])
        try await harness.start()
        let engine = harness.engine
        let run = Task { await engine.sync(.force) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(bulk.transferID)
        let location = try await engine.awaitAsset("page", lane: .userInitiated).get()
        #expect(location.id == "page")
        let outcome = await run.value
        #expect(outcome.completeReport?.fetched == 1)
        let starts = await harness.source.starts.map(\.id)
        #expect(starts == [bulk.transferID, page.transferID, bulk.transferID], "the bulk transfer resumed after the user one")
        #expect(await harness.source.controlLog.contains(FakeControlRecord(transfer: bulk.transferID, control: .pause)))
        #expect(try await engine.metrics().get().preemptions == 1)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: never more than maxConcurrentTransfers transfers count as running for every setting 1…16", .timeLimit(.minutes(1)), arguments: [1, 2, 4, 7, 16])
    func boundedParallelism(concurrency: Int) async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: concurrency, reservedInteractiveSlots: 0))
        let catalog = (0..<40).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(UInt64(300 + index))
            return (EngineFixture.entry("p\(index)", bytes), bytes)
        }
        await harness.serveManifest(catalog.map(\.0))
        for (entry, bytes) in catalog {
            await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        }
        try await harness.start()
        let engine = harness.engine
        let run = Task { await engine.sync(.force) }
        var released = 0
        var peak = 0
        while released < catalog.count {
            await engine.waitUntil { $0.running >= 1 }
            await engine.waitForAllHandles()
            let state = await engine.introspect()
            peak = max(peak, state.running)
            #expect(state.running <= concurrency)
            #expect(await engine.invariantViolations().isEmpty)
            let starts = await harness.source.starts.map(\.id)
            guard released < starts.count else {
                Issue.record("no transfer started for release \(released)")
                break
            }
            await harness.source.release(starts[released], with: .progress(received: 0, expected: nil))
            await engine.waitForJobEnd(starts[released])
            released += 1
        }
        #expect(peak == concurrency, "the slots fill up")
        let outcome = await run.value
        #expect(outcome.completeReport?.fetched == catalog.count)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: concurrency outside 1…16 is clamped and reported in diagnostics", .timeLimit(.minutes(1)))
    func concurrencyClamped() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 64))
        try await harness.start()
        let diagnostics = try await harness.engine.diagnostics().get()
        #expect(diagnostics.recentErrors.contains { $0.detail == "clamped maxConcurrentTransfers" })
        await harness.engine.shutdown()
    }
}
