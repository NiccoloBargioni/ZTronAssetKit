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

    /// Whether a group's interest at `lane` holds `transfer`'s job (a join reached it).
    static func joined(_ transfer: TransferID, at lane: AssetPriority, _ engine: isolated SyncEngine) -> Bool {
        engine.state.jobs[transfer]?.interests.values.contains { $0.lane == lane } == true
    }

    /// Whether every registration and release of the window has landed: no pending claim (each join reached its members,
    /// L5-R1) and no release in progress.
    static func settled(_ engine: isolated SyncEngine) -> Bool {
        engine.state.claims.isEmpty && engine.state.releasing.isEmpty
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
        // 0 left, 5 entered; 2 and 3 swapped lanes in place. The move has settled once 3 is joined at the user-initiated
        // lane, 2 no longer is, and no claim or release is pending (L5-R14 (a): five groups and the window in flight
        // already held before the re-lanes landed, so the assertions below could pass before the move they check).
        let moved = Set(entries[1...5].map(\.transferID))
        let left = entries[0].transferID
        let promoted = entries[3].transferID
        let demoted = entries[2].transferID
        await engine.awaitCondition { engine in
            engine.state.jobs[left] == nil && engine.state.groups.count == 5 && PrefetchFacadeTests.settled(engine)
                && moved.allSatisfy { PrefetchFacadeTests.inFlight($0, engine) }
                && PrefetchFacadeTests.joined(promoted, at: .userInitiated, engine)
                && !PrefetchFacadeTests.joined(demoted, at: .userInitiated, engine)
        }
        let starts = await source.starts.dropFirst(startsBefore).map(\.id)
        let cancels = await source.controlLog.dropFirst(controlsBefore).filter { $0.control == .cancel }.map(\.transfer)
        // The re-laned assets 2 and 3 keep their transfers: each successor's registration claims its asset before the
        // old handle's release (L5-R1, CCR-G2), whichever of the release and the successor's join comes first.
        #expect(starts == [entries[5].transferID], "exactly the entering asset started: \(starts)")
        #expect(cancels == [left], "exactly the leaving asset was cancelled: \(cancels)")
        await MainActor.run {
            controller.cancelAll()
        }
        await engine.waitUntil { $0.groups == 0 && $0.running == 0 }
        await client.shutdown()
    }

    /// sync-1 S1-05's regression at load: 1,000 window moves, each turning the +1 neighbour, already in flight at the
    /// prefetch lane, into the current page. A re-lane that let an asset's interest drop to zero in between would
    /// cancel its transfer and start it again; every promotion must reach the transport as a priority change instead,
    /// and no transfer may start twice. Before the engine's claims (L5-R1) 995 to 1,001 of 1,002 transfers started more
    /// than once in every run.
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
            // The page made current is joined at the user-initiated lane before the window moves on (L5-R14 (a),
            // L5-C1-02): a move that released its handle before that join promoted nothing, while the claim correctly kept
            // the transfer, so waiting for "in flight" alone failed 7 of 50 runs under load.
            let page = entries[current].transferID
            await engine.awaitCondition { PrefetchFacadeTests.joined(page, at: .userInitiated, $0) }
            // The next neighbour is in flight at the prefetch lane before the window moves onto it.
            let next = entries[current + 1].transferID
            await engine.awaitCondition { PrefetchFacadeTests.inFlight(next, $0) }
        }
        await engine.awaitCondition { $0.state.groups.count == 3 && PrefetchFacadeTests.settled($0) }
        let starts = await source.starts.map(\.id)
        var startsByTransfer: [TransferID: Int] = [:]
        for id in starts {
            startsByTransfer[id, default: 0] += 1
        }
        let restarted = startsByTransfer.filter { $0.value > 1 }
        let promotions = await source.controlLog.filter { $0.control == .setPriority(.userInitiated) }.count
        #expect(startsByTransfer[entries[1_000].transferID] != nil, "the final current page is in flight")
        #expect(restarted.isEmpty, "\(restarted.count) transfers started more than once")
        #expect(promotions == 1_000, "every promotion reached the transport as a priority change: \(promotions)")
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
