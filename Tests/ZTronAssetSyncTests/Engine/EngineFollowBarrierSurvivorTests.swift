import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The pumps the follow barrier owes once it ends (R-SYN-2, R-SYN-5, F-28, F-41; Stage 3 close-out cycles 11 and 12, rulings
/// S3-R14 item 5 and S3-R15 item 5): the surviving mutants `noFlagPump` (`continueFollow`'s pump on `pumpWaitsForFollow`)
/// and `noDispatchOwedFlag` (`dispatchOwed`'s `pumpWaitsForFollow` term), each pinned in both orders (`LaneDropVisit`).
extension EngineFollowBarrierTests {
    // MARK: A slot freed behind the barrier (noFlagPump)

    /// A slot freed while the follow is owed is filled in the follow's last turn although that turn moved nothing: one
    /// slot; A (zz-a) downloads for a user waiter and B (zz-b) waits in the queue for another. v3 changes only the fillers,
    /// so no job moves. Behind the barrier, A's commit frees the slot and the pump it runs waits for the follow
    /// (`pumpWaitsForFollow`); the follow's last turn visits nothing and no event waits for it, so only its own pump on
    /// that flag starts B. Visited first, A's commit started B at once. Without that pump B waited in the queue with the
    /// slot free until an unrelated pump (the cycle-3 survivor `noFlagPump`).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: a slot freed during an owed follow is filled in the follow's last turn, which moved nothing (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierFillsAFreedSlotInTheFollowsLastTurn(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 998_502, tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0))
        let engine = s.engine
        let aBytes = Data(repeating: 0xA1, count: 100_000)
        let bBytes = Data(repeating: 0xA2, count: 100_000)
        let a = EngineHarness.onDemand("zz-a", aBytes)
        let b = EngineHarness.onDemand("zz-b", bBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(740_000) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .stage(aBytes)])
        await s.harness.source.script(b.transferID, [.hold, .stage(bBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state == .queued }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(840_000) + [a, b], s, visit: visit)
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? aResult.get())?.byteSize == Int64(aBytes.count), "A is served: \(aResult)")
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in
                (owed: e.followOwed, events: e.state.eventsAfterFollow.count, b: e.state.jobs[b.transferID]?.state, waits: e.state.pumpWaitsForFollow, free: e.state.jobs[a.transferID] == nil)
            }
            #expect(before.owed && before.events == 0 && before.b == .queued && before.waits && before.free, "setup: A's slot is free, B waits in the queue for the follow, and no event waits: \(before)")
        }
        // The follow's last turn (sweep-first) or nothing (visit-first), and B's state at its end.
        let atEnd = await engine.readForTests { e in
            e.releaseFollowFollowUps()
            return (owed: e.followOwed, b: e.state.jobs[b.transferID]?.state)
        }
        #expect(!atEnd.owed && atEnd.b == .downloading, "B has the freed slot once the follow ends, in its last turn (visit-first: at A's commit): \(atEnd)")
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        #expect((try? bResult.get())?.byteSize == Int64(bBytes.count), "B is served: \(bResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    // MARK: A pending run behind a pump the barrier holds (noDispatchOwedFlag)

    /// A pending run that waits for the breaker does not start behind the barrier while the pump owed to the jobs the
    /// cooldown re-admits waits for the follow: two slots, a breaker that one 403 opens. H (zz-h) downloads for a prefetch
    /// member; X's 403 opens the breaker; a forced sync is refused (a pending run on the breaker); M (zz-m), a prefetch
    /// member, parks behind it. v3 changes the fillers and drops zz-h, so the follow owes H's visit, and the cooldown ends
    /// while it is owed: the re-admission waits for the follow (`.unblock`) and the alarm's pump follow-up runs refused
    /// (`pumpWaitsForFollow`). H's visit then abandons its download, and the breaker's reconsideration of the pending run
    /// (`recordBreaker`) reads that pump as still owed (`dispatchOwed`): the run waits, M probes first and the run starts
    /// after M's verdict (F-41). Visited first, H's visit came before the cooldown's end, which re-admitted M and owed the
    /// pump the run waited for. Without the flag in `dispatchOwed` the abandon started the run behind the barrier, M still
    /// parked (the cycle-3 survivor `noDispatchOwedFlag`).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a pending run on the breaker waits behind the pump the barrier holds for the jobs a cooldown re-admits (F-28, F-41)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierHoldsAPendingRunBehindTheOwedPump(_ visit: LaneDropVisit) async throws {
        let tuning = SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0, breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let (s, _) = try await FollowBarrier.setUp(seed: 998_602, tuning: tuning)
        let engine = s.engine
        let origin = s.harness.source.originID
        let hBytes = Data(repeating: 0xA5, count: 100_000)
        let mBytes = Data(repeating: 0xA6, count: 100_000)
        let xBytes = Data(repeating: 0xA7, count: 100_000)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        let m = EngineHarness.onDemand("zz-m", mBytes)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(750_000) + [h, m, x], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        await s.harness.source.script(x.transferID, [.fail(EngineRegressionCycle20Tests.forbidden)])
        await s.harness.source.script(m.transferID, [.stage(mBytes)])
        let hGroup = try await engine.registerGroup([h.identifier], lane: .prefetch).get()
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[h.transferID]?.state == .downloading }
        }
        let xResult = await engine.awaitAsset(x.identifier, lane: .userInitiated)
        #expect((try? xResult.get()) == nil, "setup: X's 403 fails it: \(xResult)")
        let refused = await engine.sync(.force)
        #expect(refused.completeReport == nil, "setup: the breaker refuses the forced sync: \(refused)")
        await engine.awaitCondition { $0.state.run == nil && $0.state.pendingRun != nil }
        let mGroup = try await engine.registerGroup([m.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[m.transferID]?.state.isCircuitParked == true }
        let before = await engine.readForTests { e in (run: e.state.lastRunID, breaker: e.state.breakers[origin]?.state) }
        guard case .open(_, let cooldownEnd, _)? = before.breaker else {
            Issue.record("setup: X's 403 opened the breaker: \(String(describing: before.breaker))")
            await engine.shutdown()
            return
        }
        // v3 drops zz-h and changes the fillers, through the engine's apply path; its follow's first turn stops before zz-h.
        let v3Entries = [s.q] + FollowBarrier.fillers(850_000) + [m, x]
        let v3 = try ValidatedManifest(entries: v3Entries, digest: ContentHash.sha256(of: Data("v3-pending-run".utf8)))
        await engine.readForTests { $0.holdFollowFollowUps() }
        let applied = await engine.applyAndFollow(v3, etag: nil, eviction: nil)
        #expect((try? applied.get()) != nil, "setup: v3 is applied: \(applied)")
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && $0.state.jobs[h.transferID] == nil }
        }
        let watch = EngineRegressionCycle22Tests.RunStartWatch(origin: origin, watched: [m.transferID])
        let watcher = await EngineRegressionCycle22Tests.RunStartWatch.install(watch, on: engine)
        watch.arm(after: before.run)
        // The cooldown's end: one alarm turn, and the pump follow-up it owes.
        EngineRegressionCycle21Tests.advance(s.time, to: cooldownEnd)
        if visit == .sweepFollowsFirst {
            // The breaker stays `.open` until a probe is admitted, and the pump that would admit one waits for the follow:
            // the alarm's turn is awaited through the re-admission it defers and the pump follow-up it ran refused.
            await engine.awaitCondition { e in
                let unblock = e.state.eventsAfterFollow.contains { event in
                    if case .unblock(.circuitOpen) = event { return true }
                    return false
                }
                return unblock && !e.state.pumpFollowUpScheduled && e.state.pumpWaitsForFollow
            }
            let mid = await engine.readForTests { e in
                (owed: e.followOwed, h: e.state.jobs[h.transferID]?.state, m: e.state.jobs[m.transferID]?.state.isCircuitParked, run: e.state.lastRunID, pending: e.state.pendingRun != nil)
            }
            #expect(mid.owed && mid.h == .downloading && mid.m == true && mid.run == before.run && mid.pending, "setup: the cooldown ended while the follow owes H's visit; M waits parked, the run pending: \(mid)")
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        // M's verdict, then the run it lets start, to its end (its store work included): the watch saw the run in place.
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                e.state.lastRunID > before.run && e.state.jobs[m.transferID] == nil && !e.followBarrier && e.state.run == nil && !e.state.storeWorkInFlight
            }
        }
        let start = watch.sightings.first
        #expect(start != nil && start?.waiting == 0, "M, re-admitted by the cooldown's end, probes before the pending run starts (visit-first, F-41): \(String(describing: start?.waiting)) waiting")
        #expect(watch.violations.isEmpty, "\(watch.violations.prefix(3))")
        watcher.cancel()
        await watcher.value
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await engine.releaseGroup(mGroup)
        await engine.releaseGroup(hGroup)
        await engine.shutdown()
    }
}
