import Foundation
import Testing
@testable import ZTronAssetKit
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

@Suite("Facade prefetch")
struct PrefetchFacadeTests {
    /// Whether `transfer` is downloading with its handle in place (the fake source recorded its start).
    static func inFlight(_ transfer: TransferID, _ engine: isolated SyncEngine) -> Bool {
        engine.state.jobs[transfer]?.state.kind == .downloading && engine.state.jobs[transfer]?.active?.handle != nil
    }

    /// On-demand entries whose transfers park in the fake source (unscripted), so a started transfer stays in flight
    /// until the engine cancels it.
    @available(macOS 15.0, iOS 18.0, *)
    private static func parkedCatalog(_ harness: KitHarness, count: Int) async throws -> [ManifestEntry] {
        let entries = (0..<count).map { KitFixture.entry("p\($0)", KitFixture.bytes(100 + UInt64($0)), policy: .onDemand) }
        await harness.serveManifest(entries)
        try await harness.startAndSettle()
        return entries
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-3: moving the window by one cancels exactly the asset that left and starts exactly the one that entered", .timeLimit(.minutes(1)))
    func windowMoveByOne() async throws {
        let harness = KitHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 8))
        let client = harness.client
        let entries = try await PrefetchFacadeTests.parkedCatalog(harness, count: 10)
        let ids = entries.map(\.identifier)
        let source = harness.source
        let controller = PrefetchWindowController(client: client, radius: 2)
        await MainActor.run {
            controller.update(ids: ids, current: 2)
        }
        let engine = await harness.engine()
        let window = Set(entries[0...4].map(\.transferID))
        await engine.awaitCondition { engine in window.allSatisfy { PrefetchFacadeTests.inFlight($0, engine) } }
        let initial = Set(await source.starts.map(\.id))
        #expect(initial == window, "the window 0…4 is in flight")
        let startsBefore = await source.starts.count
        let controlsBefore = await source.controlLog.count

        await MainActor.run {
            controller.update(ids: ids, current: 3)
        }
        // 0 left, 5 entered; 2 and 3 swapped lanes in place.
        let moved = Set(entries[1...5].map(\.transferID))
        let left = entries[0].transferID
        await engine.awaitCondition { engine in
            engine.state.jobs[left] == nil && engine.state.groups.count == 5
                && moved.allSatisfy { PrefetchFacadeTests.inFlight($0, engine) }
        }
        let starts = await source.starts.dropFirst(startsBefore).map(\.id)
        let cancels = await source.controlLog.dropFirst(controlsBefore).filter { $0.control == .cancel }.map(\.transfer)
        #expect(starts.contains(entries[5].transferID), "the entering asset started: \(starts)")
        #expect(cancels.contains(left), "the leaving asset was cancelled: \(cancels)")
        // Intermittent: whether the old handle's release lands before the successor's join is a race the engine
        // usually loses, not always (2 of 30 consecutive runs joined first on the reference host), so this test cannot
        // be CCR-G2's tripwire; `promotionNeverRestarts` repeats the re-lane 1,000 times and is.
        withKnownIssue("CCR-G2: SyncEngine.registerGroup returns before the group's interests exist, so the re-laned assets 2 and 3 lose every interest in between and restart", isIntermittent: true) {
            #expect(starts == [entries[5].transferID], "exactly the entering asset started: \(starts)")
            #expect(cancels == [left], "exactly the leaving asset was cancelled: \(cancels)")
        }
        await MainActor.run {
            controller.cancelAll()
        }
        await engine.waitUntil { $0.groups == 0 && $0.running == 0 }
        await client.shutdown()
    }

    /// sync-1 S1-05's regression at load: 1,000 window moves, each turning the +1 neighbour, already in flight at the
    /// prefetch lane, into the current page. A re-lane that let an asset's interest drop to zero in between would
    /// cancel its transfer and start it again; every promotion must reach the transport as a priority change instead,
    /// and no transfer may start twice.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-3: a neighbour that becomes current is promoted without a second transfer", .timeLimit(.minutes(1)))
    func promotionNeverRestarts() async throws {
        let harness = KitHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 8))
        let client = harness.client
        let entries = try await PrefetchFacadeTests.parkedCatalog(harness, count: 1_002)
        let ids = entries.map(\.identifier)
        let source = harness.source
        let engine = await harness.engine()
        let controller = PrefetchWindowController(client: client, radius: 1)
        for current in 0...1_000 {
            await MainActor.run {
                controller.update(ids: ids, current: current)
            }
            // The next neighbour is in flight at the prefetch lane before the window moves onto it.
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
        let promotions = await source.controlLog.filter { $0.control == .setPriority(.userInitiated) }.count
        #expect(startsByTransfer[entries[1_000].transferID] != nil, "the final current page is in flight")
        // Not intermittent: 1,000 re-lanes always lose the race somewhere, so this wrapper fails ("known issue was not
        // recorded") the run after the engine fix, which is the signal to remove both wrappers (CCR-G2).
        withKnownIssue("CCR-G2: SyncEngine.registerGroup returns before the group's interests exist, so each re-lane drops the asset's last interest and restarts its transfer") {
            #expect(restarted.isEmpty, "\(restarted.count) transfers started more than once")
            #expect(promotions == 1_000, "every promotion reached the transport as a priority change: \(promotions)")
        }
        await MainActor.run {
            controller.cancelAll()
        }
        await engine.waitUntil { $0.groups == 0 }
        await client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-4: a handle released without cancel() releases its interest on deinit", .timeLimit(.minutes(1)))
    func handleDeinitReleasesEngineInterest() async throws {
        let harness = KitHarness.make()
        let client = harness.client
        let entries = try await PrefetchFacadeTests.parkedCatalog(harness, count: 1)
        let engine = await harness.engine()
        do {
            let handle = client.prefetch([entries[0].identifier])
            try await handle.awaitRegistration()
            let transfer = entries[0].transferID
            await engine.awaitCondition { PrefetchFacadeTests.inFlight(transfer, $0) }
            #expect(await engine.introspect().groups == 1)
        }
        // The handle is gone without cancel(): its deinit releases the group, and the transfer wanted by nobody stops.
        let transfer = entries[0].transferID
        await engine.awaitCondition { $0.state.groups.isEmpty && $0.state.jobs[transfer] == nil }
        let cancels = await harness.source.controlLog.filter { $0.control == .cancel }.map(\.transfer)
        #expect(cancels == [entries[0].transferID])
        await client.shutdown()
    }
}
