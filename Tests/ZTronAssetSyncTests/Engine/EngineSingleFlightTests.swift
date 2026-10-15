import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Single-flight, interests and cancellation (R-SYN-4, R-SYN-10, H-3).
@Suite("Engine single-flight")
struct EngineSingleFlightTests {
    /// A harness whose manifest lists `entries` on demand (applied, not fetched by the run).
    @available(macOS 15.0, iOS 18.0, *)
    static func applied(_ entries: [ManifestEntry], harness: EngineHarness) async throws {
        await harness.serveManifest(entries)
        try await harness.start()
        let outcome = await harness.engine.sync(.force)
        #expect(outcome.completeReport != nil, "the on-demand catalog applies without fetching: \(outcome)")
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-4: 100 callers on one asset with seeded random cancellations share one transfer and each resumes exactly once",
        .timeLimit(.minutes(1)),
        arguments: [UInt64(0xA1), 0xB2, 0xC3, 0xD4, 0xE5]
    )
    func hundredCallers(seed: UInt64) async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(5)
        let entry = EngineHarness.onDemand("shared", bytes)
        try await EngineSingleFlightTests.applied([entry], harness: harness)
        await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        let engine = harness.engine
        let callers = (0..<100).map { index in
            Task { await engine.awaitAsset("shared", lane: index % 2 == 0 ? .userInitiated : .prefetch) }
        }
        await engine.waitUntil { $0.waiters == 100 }
        var random = SplitMix64(seed: seed)
        var cancelled = Set<Int>()
        for index in 0..<100 where random.next() % 3 == 0 {
            cancelled.insert(index)
        }
        cancelled.remove(0)
        for index in cancelled.sorted() {
            callers[index].cancel()
        }
        let survivors = 100 - cancelled.count
        await engine.waitUntil { $0.waiters == survivors }
        await harness.source.release(entry.transferID, with: .progress(received: 0, expected: nil))
        for (index, caller) in callers.enumerated() {
            let result = await caller.value
            if cancelled.contains(index) {
                #expect(result == .failure(.cancelled), "seed \(seed): caller \(index)")
            } else {
                #expect((try? result.get())?.id == "shared", "seed \(seed): caller \(index) got \(result)")
            }
        }
        #expect(await harness.source.starts.count == 1, "seed \(seed): one transfer")
        let state = await engine.introspect()
        #expect(state.waiters == 0 && state.interests == 0, "seed \(seed)")
        #expect(try await engine.metrics().get().illegalTransitions == 0)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: the transfer is cancelled only after the last of 100 callers cancels", .timeLimit(.minutes(1)))
    func cancelledOnlyAfterLastCaller() async throws {
        let harness = EngineHarness.make()
        let entry = EngineHarness.onDemand("shared", EngineFixture.bytes(6))
        try await EngineSingleFlightTests.applied([entry], harness: harness)
        await harness.source.script(entry.transferID, [.hold])
        let engine = harness.engine
        let callers = (0..<100).map { _ in Task { await engine.awaitAsset("shared", lane: .userInitiated) } }
        await engine.waitUntil { $0.waiters == 100 && $0.running == 1 }
        for (index, caller) in callers.dropLast().enumerated() {
            caller.cancel()
            await engine.waitUntil { $0.waiters == 99 - index }
        }
        #expect(await harness.source.controlLog.filter { $0.control == .cancel }.isEmpty, "99 withdrawals never cancel the transfer")
        #expect(await harness.source.activeTransfers == 1)
        callers.last?.cancel()
        await engine.waitUntil { $0.waiters == 0 && $0.jobsByState.isEmpty }
        #expect(await harness.source.controlLog == [FakeControlRecord(transfer: entry.transferID, control: .cancel)])
        #expect(await harness.source.activeTransfers == 0)
        for caller in callers {
            #expect(await caller.value == .failure(.cancelled))
        }
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: two identifiers with the same checksum share one transfer and both become present", .timeLimit(.minutes(1)))
    func sameChecksumSharesTransfer() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(11)
        let left = EngineHarness.onDemand("left", bytes)
        let right = EngineHarness.onDemand("right", bytes)
        #expect(left.transferID == right.transferID)
        try await EngineSingleFlightTests.applied([left, right], harness: harness)
        await harness.source.script(left.transferID, [.hold, .stage(bytes)])
        let engine = harness.engine
        let first = Task { await engine.awaitAsset("left", lane: .userInitiated) }
        let second = Task { await engine.awaitAsset("right", lane: .userInitiated) }
        await engine.waitUntil { $0.waiters == 2 }
        await harness.source.release(left.transferID, with: .progress(received: 0, expected: nil))
        let leftLocation = try await first.value.get()
        let rightLocation = try await second.value.get()
        #expect(leftLocation.url == rightLocation.url)
        #expect(await harness.source.starts.count == 1)
        let view = try await harness.view()
        #expect(view.records["left"]?.referencedBlob != nil && view.records["right"]?.referencedBlob != nil)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a caller cancelled before joining fails with cancelled and registers nothing", .timeLimit(.minutes(1)))
    func preCancelledCaller() async throws {
        let harness = EngineHarness.make()
        let entry = EngineHarness.onDemand("x", EngineFixture.bytes(12))
        try await EngineSingleFlightTests.applied([entry], harness: harness)
        let engine = harness.engine
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.awaitAsset("x", lane: .userInitiated)
        }
        #expect(await caller.value == .failure(.cancelled))
        let state = await engine.introspect()
        #expect(state.waiters == 0 && state.jobsByState.isEmpty)
        #expect(await harness.source.starts.isEmpty)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: withdrawing the highest-priority interest demotes the running transfer", .timeLimit(.minutes(1)))
    func withdrawalDemotes() async throws {
        let harness = EngineHarness.make()
        let entry = EngineHarness.onDemand("x", EngineFixture.bytes(13))
        try await EngineSingleFlightTests.applied([entry], harness: harness)
        await harness.source.script(entry.transferID, [.hold])
        let engine = harness.engine
        let token = try await engine.registerGroup(["x"], lane: .prefetch).get()
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(entry.transferID)
        let user = Task { await engine.awaitAsset("x", lane: .userInitiated) }
        await engine.waitUntil { $0.waiters == 1 }
        user.cancel()
        await engine.waitUntil { $0.waiters == 0 }
        let controls = await harness.source.controlLog.map(\.control)
        #expect(controls == [.setPriority(.userInitiated), .setPriority(.prefetch)])
        await engine.releaseGroup(token)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: ensureAvailable cancelled as its last member commits resumes exactly once", .timeLimit(.minutes(1)), arguments: Array(0..<12))
    func ensureAvailableCancelRacesCommit(iteration: Int) async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(UInt64(100 + iteration))
        let entry = EngineHarness.onDemand("member", bytes)
        try await EngineSingleFlightTests.applied([entry], harness: harness)
        await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        let engine = harness.engine
        let caller = Task { await engine.ensureAvailable(scope: .identifiers(["member"])) }
        await engine.waitUntil { $0.running == 1 && $0.groups == 1 }
        let source = harness.source
        async let release: Void = source.release(entry.transferID, with: .progress(received: 0, expected: nil))
        if iteration % 2 == 0 {
            caller.cancel()
        }
        await release
        if iteration % 2 == 1 {
            caller.cancel()
        }
        let result = await caller.value
        switch result {
        case .success(let report):
            #expect(report.total == 1)
        case .failure(let error):
            #expect(error == .cancelled)
        }
        await engine.waitUntil { $0.groups == 0 && $0.waiters == 0 }
        #expect(await engine.introspect().interests == 0)
        await engine.shutdown()
    }
}
