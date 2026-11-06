import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A commit's terminal events as one batch per subscriber queue (Stage 3 close-out cycle 22, ruling S3-R27 item 1, a3;
/// d1 §3's T-A-3 with d1 review should-fix 3's setup). Each runs in both orders (`LaneDropVisit`) and expects the same
/// answers in both.
extension EngineFollowBarrierTests {
    /// T-A-3: zz-t1, zz-t2 and zz-t3 share X's content, each with a user waiter; zz-t1 failed before on W's content (v2,
    /// a 404), so the stalled subscriber, which reads nothing, still holds its slot (a failure leaves no stale bytes to
    /// answer zz-t1's waiter with, which a commit would: d1 review should-fix 3). X's publication is held at its first
    /// store unit while v4 makes the follow owe its visits (swept first) or ends it (visited first). At X's commit the
    /// other subscriber's pull waits on an empty queue: it is handed zz-t1's `assetAvailable` and queues the other two in
    /// ascending order; the stalled queue moves zz-t1's slot to its tail, behind which it queues the other two. The
    /// commit's turn counts one move (`eventsCoalesced`) and one hand-off (`eventsDelivered`).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a commit hands its first id to a waiting pull and queues its other ids ascending, and moves an id a stalled queue held to its tail, counting one move and one hand-off (S3-R27 item 1, a3)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitBatchReachesAWaitingAndAStalledSubscriber(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_029_501
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let wBytes = EngineFixture.bytes(seed + 2, count: 12)
        let xBytes = EngineFixture.bytes(seed + 3, count: 16)
        let earlier = EngineHarness.onDemand("zz-t1", wBytes)
        let onX = (1...3).map { EngineHarness.onDemand("zz-t\($0)", xBytes) }
        let ids = onX.map(\.identifier)
        let x = onX[0].transferID
        try #require(earlier.transferID != x && onX.allSatisfy { $0.transferID == x }, "setup: v3 moves zz-t1 from W's content to X's, which zz-t2 and zz-t3 share")
        let subscription = try await engine.subscribe().get()
        let stalled = try #require(await engine.readForTests { $0.state.subscribers.keys.max() }, "setup: the stalled subscriber is registered")
        let waiting = await engine.readForTests { $0.registerSubscriber() }
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [earlier] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        await s.harness.source.script(earlier.transferID, [.fail(.permanentMissing(httpStatus: 404))])
        let w = Task { await engine.awaitAsset(earlier.identifier, lane: .userInitiated) }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: w) }
        try #require(wResult == .failure(.notFound), "setup: zz-t1 fails on W's content: \(wResult)")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 200) + onX + Self.laterFillers(seed + 6_000), etag: "v3")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(x, [.hold, .stage(xBytes)])
        let waiters = ids.map { id in Task { await engine.awaitAsset(id, lane: .userInitiated) } }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[x]?.state == .downloading && $0.state.jobs[x]?.interests.count == 3 }
        }
        let releaser = try await Self.holdPublication(of: x, s, bulk: bulk)
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 300) + onX + Self.laterFillers(seed + 9_000), tag: "v4-batch-\(seed)", s, visit: visit)
        // The waiting subscriber reads everything so far; then its pull waits on an empty queue.
        await engine.readForTests { e in
            while e.state.subscribers[waiting]?.take() != nil {}
        }
        let pull = Task { await engine.pull(waiting) }
        // A pull that waits notifies no observer, so its registration is polled.
        while await engine.readForTests({ $0.state.subscribers[waiting]?.pending == nil }) {
            await Task.yield()
        }
        let before = await engine.readForTests { e in
            (coalesced: e.state.metrics.eventsCoalesced, delivered: e.state.metrics.eventsDelivered, held: e.state.subscribers[stalled]?.liveSlots.contains(.asset(ids[0])) == true, pending: e.state.subscribers[waiting]?.pending != nil)
        }
        try #require(before.held && before.pending, "setup: the stalled queue holds zz-t1's slot from W's failure, and the other pull waits: \(before)")
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        await engine.awaitCondition { $0.state.jobs[x] == nil }
        let after = await engine.readForTests { e in
            var queued: [AssetEvent] = []
            while let event = e.state.subscribers[waiting]?.take() {
                queued.append(event)
            }
            var held: [AssetEvent] = []
            while let event = e.state.subscribers[stalled]?.take() {
                held.append(event)
            }
            return (coalesced: e.state.metrics.eventsCoalesced, delivered: e.state.metrics.eventsDelivered, generation: e.state.generation, queued: queued, held: held)
        }
        let handedOff = await pull.value
        func scenario(_ events: [AssetEvent]) -> [AssetEvent] {
            events.filter { event in
                switch event {
                case .assetAvailable(let id, _), .assetFailed(let id, _, _), .assetRemoved(let id, _):
                    return id.rawValue.hasPrefix("zz-t")
                default:
                    return false
                }
            }
        }
        let announced = ids.map { AssetEvent.assetAvailable($0, generation: after.generation) }
        #expect(handedOff == announced[0], "the waiting pull is handed zz-t1's announcement: \(String(describing: handedOff))")
        #expect(scenario(after.queued) == Array(announced.dropFirst()), "the waiting queue then holds zz-t2's and zz-t3's, ascending: \(after.queued)")
        #expect(scenario(after.held) == announced, "the stalled queue holds the three, ascending, zz-t1's moved to the tail: \(after.held)")
        #expect(after.coalesced - before.coalesced == 1, "the commit moves one live slot, zz-t1's in the stalled queue: \(before.coalesced) -> \(after.coalesced)")
        #expect(after.delivered - before.delivered == 1, "the commit delivers one event, by hand-off: \(before.delivered) -> \(after.delivered)")
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        for (id, waiter) in zip(ids, waiters) {
            let result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) }
            #expect((try? result.get())?.byteSize == Int64(xBytes.count), "\(id) gets X's bytes: \(result)")
        }
        withExtendedLifetime(subscription) {}
        await Self.finishHeld(s)
    }
}
