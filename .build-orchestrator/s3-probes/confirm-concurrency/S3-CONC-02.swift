import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import ZTronAssetTransport

/// Stage 3 concurrency probes (S3-CONC-01): the background coordinator's priority changes interleaved at their
/// listing await (REENTRANCY row D-9), ordered through `FakeBackgroundSessionDriver`'s snapshot hold, never by timing.
@Suite("S3 concurrency probes: background priority")
struct S3ConcurrencyProbeTests {
    @available(macOS 15.0, iOS 18.0, *)
    typealias Rig = BackgroundCoordinatorTests.Rig

    /// The engine promotes a bulk background transfer (a user waiter joined) and, while that change lists the tasks,
    /// demotes it again (the waiter withdrew). The demotion is the newest request, so the OS task must end at the bulk
    /// priority 0.25; D-9 re-validates the token and liveness after the listing but not that its request is still the
    /// newest, so the promotion lands last and the OS task stays at 0.75 while the engine's lane is bulk.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-10: the newest of two overlapping priority changes is the one a background transfer's OS task keeps", .timeLimit(.minutes(1)))
    func newestPriorityChangeWins() async throws {
        let rig = try Rig("s3-priority-order")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let handle = try #require(await coordinator.start(rig.job()) as? BackgroundTransferHandle)
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.25])
        // The promotion's listing is held after it was taken...
        await rig.driver.holdNextSnapshot(.afterListing)
        let promotion = Task { await coordinator.setPriority(.userInitiated, of: handle.name, token: handle.token) }
        await rig.awaitSignal("snapshot")
        // ...while the later demotion runs to its end.
        await coordinator.setPriority(.bulk, of: handle.name, token: handle.token)
        await rig.driver.releaseSnapshot()
        await promotion.value
        let changes = await rig.driver.priorityChanges.map(\.priority)
        #expect(changes.last == 0.25, "the newest request was bulk (0.25), the OS task ends at \(String(describing: changes.last)); changes \(changes)")
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.25])
        withExtendedLifetime(handle) {}
    }

    /// S3-CONC-02: UIKit hands a second completion handler for the same session identifier while the first one is
    /// still held (the facade's first `handleBackgroundEvents` task has not completed it yet). Every handler UIKit hands
    /// over must be called exactly once; `accept` overwrites the first, which is then never called, and the first task's
    /// `complete` calls the second one before its own events were staged.
    @MainActor
    @Test("R-NET-3: a second background-events handler for one identifier never drops the first one uncalled")
    func secondHandlerKeepsFirst() {
        let relay = BackgroundEventsRelay()
        let ours = BackgroundCoordinatorTests.identifier.rawValue
        var calls: [String] = []
        #expect(relay.accept(identifier: ours) { calls.append("first") })
        #expect(relay.accept(identifier: ours) { calls.append("second") })
        // The first handleBackgroundEvents task finishes, then the second.
        relay.complete(identifier: ours)
        relay.complete(identifier: ours)
        #expect(calls.sorted() == ["first", "second"], "each handler UIKit handed over runs once: \(calls)")
    }
}
