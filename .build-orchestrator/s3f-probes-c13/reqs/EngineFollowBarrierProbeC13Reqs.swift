import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// PROBE-C13R-STAMP-BREAKER (cycle-13 requirements verifier; evidence only, not for commit as is).
/// Reaches `gate`'s refusal on a place stamp's breaker (EngineDispatch.swift:532-534, 0 hits in the full bundle):
/// X's 403 opens the breaker; prefetch members M and K park; at the cooldown's end one probes and holds, the other
/// stays parked. v3 moves the parked member's id to new content N while the follow owes its visits. The probe then
/// commits and closes the breaker. Visited first, N parked behind the half-open breaker at the apply and the close
/// re-admitted it. Behind the barrier the visit gives N its place with the apply's stamp (half-open, probe running).
extension EngineFollowBarrierTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C13R-STAMP-BREAKER", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func probeC13RStampBreaker(_ visit: LaneDropVisit) async throws {
        let tuning = SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0, breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let (s, _) = try await FollowBarrier.setUp(seed: 1_399_002, tuning: tuning)
        let engine = s.engine
        let origin = s.harness.source.originID
        let xBytes = Data(repeating: 0xA4, count: 100_000)
        let mBytes = Data(repeating: 0xA5, count: 100_000)
        let kBytes = Data(repeating: 0xA6, count: 100_000)
        let hBytes = Data(repeating: 0xA7, count: 100_000)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let m = EngineHarness.onDemand("zz-m", mBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_399_100) + [h, k, m, x], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(x.transferID, [.fail(EngineRegressionCycle20Tests.forbidden)])
        await s.harness.source.script(m.transferID, [.hold, .stage(mBytes)])
        await s.harness.source.script(k.transferID, [.hold, .stage(kBytes)])
        await s.harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        let hGroup = try await engine.registerGroup([h.identifier], lane: .prefetch).get()
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[h.transferID]?.state == .downloading }
        }
        let xResult = await engine.awaitAsset(x.identifier, lane: .userInitiated)
        #expect((try? xResult.get()) == nil, "setup: X's 403 fails it: \(xResult)")
        let group = try await engine.registerGroup([m.identifier, k.identifier], lane: .prefetch).get()
        await engine.awaitCondition { e in
            e.state.jobs[m.transferID]?.state.isCircuitParked == true && e.state.jobs[k.transferID]?.state.isCircuitParked == true
        }
        let opened = await engine.readForTests { $0.state.breakers[origin]?.state }
        guard case .open(_, let cooldownEnd, _)? = opened else {
            Issue.record("setup: X's 403 opened the breaker: \(String(describing: opened))")
            await engine.shutdown()
            return
        }
        EngineRegressionCycle21Tests.advance(s.time, to: cooldownEnd)
        await engine.awaitCondition { $0.state.jobs[m.transferID]?.state == .downloading || $0.state.jobs[k.transferID]?.state == .downloading }
        let mProbes = await engine.readForTests { $0.state.jobs[m.transferID]?.state == .downloading }
        let probe = mProbes ? m : k
        let parkedName = mProbes ? "zz-k" : "zz-m"
        let nBytes = EngineFixture.bytes(1_399_004, count: 16)
        let nEntry = EngineHarness.onDemand(parkedName, nBytes)
        await s.harness.source.script(nEntry.transferID, [.hold, .stage(nBytes)])
        let v3: [ManifestEntry] = [h, mProbes ? nEntry : k, mProbes ? m : nEntry, x]
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(1_399_200) + v3, tag: "v3-stamp-breaker", s, visit: visit)
        let afterApply = await engine.readForTests { e in (owed: e.followOwed, n: e.state.jobs[nEntry.transferID]?.state) }
        print("DBGP \(visit) afterApply=\(afterApply)")
        await s.harness.source.release(probe.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { e in e.state.breakers[origin]?.state == .closed && e.state.jobs[probe.transferID] == nil }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await engine.awaitCondition { e in
            let state = e.state.jobs[nEntry.transferID]?.state
            return state != nil && state != .queued
        }
        let snap = await engine.readForTests { e in
            (n: e.state.jobs[nEntry.transferID]?.state, breaker: e.state.breakers[origin]?.state,
             breakerAlarm: e.state.heap.deadline(for: .breaker(origin)), stamps: e.state.placeStamps.count)
        }
        print("DBGP \(visit) atEnd=\(snap)")
        if snap.n != .downloading {
            // Whatever the engine has scheduled: every deadline it holds, then an hour of clock.
            let heap = await engine.readForTests { e in e.state.heap.entries.map { "\($0)" } }
            print("DBGP \(visit) heap=\(heap)")
            EngineRegressionCycle21Tests.advance(s.time, to: s.time.monotonicNow().adding(seconds: 3_600))
            for _ in 0..<20 {
                await engine.readForTests { _ in }
                await Task.yield()
            }
            let later = await engine.readForTests { e in
                (n: e.state.jobs[nEntry.transferID]?.state, breaker: e.state.breakers[origin]?.state, groupPending: e.state.groups[group]?.pending.count)
            }
            print("DBGP \(visit) afterAnHour=\(later)")
        }
        #expect(snap.n == .downloading, "N runs once the breaker closed (visit-first): \(snap)")
        if snap.n == .downloading {
            await s.harness.source.release(nEntry.transferID, with: .progress(received: 0, expected: nil))
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[nEntry.transferID] == nil }
            }
        }
        await s.harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[h.transferID] == nil }
        }
        let violations = await engine.invariantViolations()
        print("DBGP \(visit) violations=\(violations.prefix(3))")
        await engine.releaseGroup(group)
        await engine.releaseGroup(hGroup)
        await Self.finishHeld(s)
    }
}
