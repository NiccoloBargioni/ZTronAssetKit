import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Every branch that defers an event behind the follow barrier, reached in both orders (R-SYN-3, R-SYN-11, F-28; Stage 3
/// close-out cycle 12, ruling S3-R15 item 6): each test delivers one kind of event while the follow still owes the visit
/// that changes what the event's decision reads (`.sweepFollowsFirst`), or after the follow ended
/// (`.followVisitedFirst`), and expects the visit-first outcome in both. The mutant that applies the event at its arrival
/// instead of deferring it fails each of them (`docs/adr-drafts/s3f.md`, cycle 12's mutant table).
extension EngineFollowBarrierTests {
    // MARK: A re-admission follow-up turn (`EventAfterFollow.readmit`)

    /// A re-admission follow-up turn that runs while the follow owes a visit re-queues the jobs the visits leave, behind
    /// the places the visits give: a prefetch group of `readmissionsPerTurn` + 8 members (zz-m…, then P at zz-p, last)
    /// goes offline, its running members failing `whenOnline` and the others parking offline. The network returns: one
    /// turn re-queues `readmissionsPerTurn` members, which download, and owes the last 8 in the pump's order, P among
    /// them, to a follow-up turn the hold keeps waiting. v3 moves zz-p to new content N. Visited first,
    /// the visit moved P's interest onto N, queued at the apply, and the follow-up then re-queued the other 7 behind it,
    /// so N starts before them. Re-admitted before the visit, the 7 took their places ahead of N (P, re-queued with them,
    /// left the queue at its visit).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a re-admission turn during an owed follow re-queues its jobs behind the places the owed visits give (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierReadmitsBehindTheOwedVisitsPlaces(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 992_102)
        let engine = s.engine
        let count = SyncEngine.readmissionsPerTurn + 8
        var members: [ManifestEntry] = []
        var payloads: [TransferID: Data] = [:]
        for index in 0..<(count - 1) {
            let bytes = EngineFixture.bytes(992_200 + UInt64(index), count: 16)
            let entry = EngineHarness.onDemand(String(format: "zz-m%03d", index), bytes)
            members.append(entry)
            payloads[entry.transferID] = bytes
        }
        let pBytes = EngineFixture.bytes(992_110, count: 16)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        payloads[p.transferID] = pBytes
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(762_000) + members + [p], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        // The group's first members start and wait for a script (none yet); the network drops: the queued members park
        // offline and the running ones fail offline (`failed(whenOnline)`).
        let token = try await engine.registerGroup((members + [p]).map(\.identifier), lane: .prefetch).get()
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && !$0.state.inFlight.isEmpty && $0.state.jobs.count == count }
        }
        await engine.waitForAllHandles()
        let running = await s.harness.source.starts.map(\.id).filter { payloads[$0] != nil }
        await s.harness.conditions.send(EngineRegressionCycle10Tests.offline)
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions?.network.satisfied == false }
        }
        for transfer in running {
            await s.harness.source.script(transfer, [.fail(.offline(.noConnection))])
        }
        await engine.awaitCondition { $0.state.inFlight.isEmpty && $0.state.laneParked.count + $0.state.failedJobs.count == count }
        for (transfer, bytes) in payloads {
            await s.harness.source.script(transfer, [.stage(bytes)])
        }
        // The network returns: one turn re-queues `readmissionsPerTurn` members (they download and leave) and owes the
        // rest, P (the last ticket) among them, to the follow-up turn the hold keeps waiting.
        await engine.holdReadmissionFollowUps()
        await s.harness.conditions.send(.unrestricted)
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                e.state.readmissionFollowUpWaiting && e.state.jobs.count == count - SyncEngine.readmissionsPerTurn && e.state.inFlight.isEmpty
            }
        }
        let owed = await engine.readForTests { e in Set(e.state.jobs.keys) }
        try #require(owed.contains(p.transferID), "setup: the follow-up owes P its re-queue: \(owed.count) jobs")
        let others = owed.subtracting([p.transferID])
        let nBytes = EngineFixture.bytes(992_111, count: 16)
        let n = EngineHarness.onDemand("zz-p", nBytes)
        await s.harness.source.script(n.transferID, [.stage(nBytes)])
        let startsBefore = await s.harness.source.starts.count
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(862_000) + members + [n], s, visit: visit)
        // The follow-up turn (sweep-first: while the follow owes P's visit).
        await engine.readForTests { $0.releaseReadmissionFollowUps() }
        if visit == .sweepFollowsFirst {
            let stillOwed = await engine.readForTests { $0.followOwed }
            #expect(stillOwed, "setup: the follow-up turn ran while the follow owes P's visit")
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in !e.followBarrier && e.state.jobs.isEmpty }
        }
        let started = await s.harness.source.starts.dropFirst(startsBefore).map(\.id)
        #expect(started.first == n.transferID, "N, queued at P's visit, starts before the members the follow-up re-queues (visit-first): \(started.prefix(3))")
        #expect(Set(started) == others.union([n.transferID]), "N and the 7 other owed members start, P does not: \(started.count) starts")
        await engine.releaseGroup(token)
        await FollowBarrier.finish(s, sync: sync)
    }
}

