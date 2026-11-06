import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch repro (s3f c12 reqs verifier): `barrierRetriesBehindTheOwedVisitsPlaces` with a state dump after each wait.
@Suite("VerifyC12RetryRepro", .serialized)
struct VerifyC12RetryRepro {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier

    @available(macOS 15.0, iOS 18.0, *)
    static func dump(_ engine: SyncEngine, _ s: FollowBarrier.Setup, r: TransferID, h: TransferID, p: TransferID, _ tag: String) async {
        let line = await engine.readForTests { e in
            "REP \(tag): cancelled=\(Task.isCancelled) r=\(String(describing: e.state.jobs[r]?.state)) h=\(String(describing: e.state.jobs[h]?.state)) p=\(String(describing: e.state.jobs[p]?.state)) cond=\(e.state.conditions != nil) storeWork=\(e.state.storeWorkInFlight) storeDeadline=\(String(describing: e.state.storeDeadline)) owed=\(e.followOwed) barrier=\(e.followBarrier) events=\(e.state.eventsAfterFollow.count) run=\(String(describing: e.state.run?.id)) pending=\(e.state.pendingRun != nil) catchUps=\(e.state.manifestCatchUps)"
        }
        print(line + " sleepers=\(s.time.pendingSleepers) next=\(String(describing: s.time.nextDeadline)) now=\(s.time.monotonicNow())")
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C12R-RETRY-REPRO", .timeLimit(.minutes(1)), arguments: LaneDropVisit.allCases)
    func retryRepro(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 992_402, tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0))
        let engine = s.engine
        let rBytes = EngineFixture.bytes(992_410, count: 16)
        let hBytes = EngineFixture.bytes(992_411, count: 16)
        let pBytes = EngineFixture.bytes(992_412, count: 16)
        let nBytes = EngineFixture.bytes(992_413, count: 16)
        let r = EngineHarness.onDemand("zz-r", rBytes)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(766_000) + [h, p, r], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        await Self.dump(engine, s, r: r.transferID, h: h.transferID, p: p.transferID, "step 1")

        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(r.transferID, [.fail(.transient(.serverError(httpStatus: 500), retryAfter: nil)), .hold, .stage(rBytes)])
        await s.harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        await s.harness.source.script(p.transferID, [.stage(pBytes)])
        let rWaiter = Task { await engine.awaitAsset(r.identifier, lane: .userInitiated) }
        await engine.awaitCondition { e in
            if case .failed(.at) = e.state.jobs[r.transferID]?.state {
                return true
            }
            return false
        }
        await Self.dump(engine, s, r: r.transferID, h: h.transferID, p: p.transferID, "step 2")

        let hWaiter = Task { await engine.awaitAsset(h.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[h.transferID]?.state == .downloading }
        await Self.dump(engine, s, r: r.transferID, h: h.transferID, p: p.transferID, "step 3")

        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .queued }
        await Self.dump(engine, s, r: r.transferID, h: h.transferID, p: p.transferID, "step 4")

        let backoffEnd = await engine.readForTests { e -> MonotonicInstant? in
            if case .failed(.at(let at)) = e.state.jobs[r.transferID]?.state {
                return at
            }
            return nil
        }
        await Self.dump(engine, s, r: r.transferID, h: h.transferID, p: p.transferID, "step 5")

        let retryAt = try #require(backoffEnd, "setup: R waits for its backoff")
        let n = EngineHarness.onDemand("zz-p", nBytes)
        await s.harness.source.script(n.transferID, [.hold, .stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(866_000) + [h, n, r], s, visit: visit)
        // R's backoff ends (sweep-first: while the follow owes P's visit).
        s.time.advance(to: retryAt)
        await engine.awaitCondition { e in
            e.state.jobs[r.transferID]?.state == .queued || e.state.eventsAfterFollow.contains { event in
                if case .retryDue(r.transferID, _) = event {
                    return true
                }
                return false
            }
        }
        await Self.dump(engine, s, r: r.transferID, h: h.transferID, p: p.transferID, "step 6")

        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { $0.followOwed }
            #expect(owed, "setup: R's backoff ended while the follow owes P's visit")
        }
        await Self.dump(engine, s, r: r.transferID, h: h.transferID, p: p.transferID, "step 7")

        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.dump(engine, s, r: r.transferID, h: h.transferID, p: p.transferID, "step 8")

        let starts = await s.harness.source.starts.count
        await s.harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { e in
            e.state.jobs[h.transferID] == nil && (e.state.jobs[n.transferID]?.state == .downloading || e.state.jobs[r.transferID]?.state == .downloading)
        }
        await Self.dump(engine, s, r: r.transferID, h: h.transferID, p: p.transferID, "step 9")

        await engine.waitForAllHandles()
        let after = await engine.readForTests { e in (n: e.state.jobs[n.transferID]?.state, r: e.state.jobs[r.transferID]?.state) }
        let next = await s.harness.source.starts.dropFirst(starts).map(\.id)
        #expect(after.n == .downloading && after.r == .queued, "the freed slot goes to N, queued at P's visit before R's backoff ended (visit-first): \(after)")
        #expect(next.first == n.transferID, "the next start is N's: \(next)")
        await s.harness.source.release(n.transferID, with: .progress(received: 0, expected: nil))
        await s.harness.source.release(r.transferID, with: .progress(received: 0, expected: nil))
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let rResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: rWaiter) }
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: hWaiter) }
        #expect((try? pResult.get())?.byteSize == 16 && (try? rResult.get())?.byteSize == 16, "P is served from N and R from its retry: \(pResult) \(rResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

}
