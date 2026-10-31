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

    // MARK: A backoff's end (`EventAfterFollow.retryDue`)

    /// A backoff that ends while the follow owes a visit re-queues its job behind the places the visits give: one slot.
    /// R (zz-r, a user waiter) failed with a 500 and waits for its backoff; H (zz-h) holds the slot; P (zz-p, a user
    /// waiter) waits in the queue. v3 moves zz-p to new content N; then R's backoff ends. Visited first, P's visit queued N
    /// at the apply and the backoff's end re-queued R behind it, so the freed slot goes to N. Re-queued at the backoff's
    /// end, R took the earlier place and the slot.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a backoff that ends during an owed follow re-queues its job behind the places the owed visits give (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierRetriesBehindTheOwedVisitsPlaces(_ visit: LaneDropVisit) async throws {
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
        let hWaiter = Task { await engine.awaitAsset(h.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[h.transferID]?.state == .downloading }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .queued }
        let backoffEnd = await engine.readForTests { e -> MonotonicInstant? in
            if case .failed(.at(let at)) = e.state.jobs[r.transferID]?.state {
                return at
            }
            return nil
        }
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
        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { $0.followOwed }
            #expect(owed, "setup: R's backoff ended while the follow owes P's visit")
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let starts = await s.harness.source.starts.count
        await s.harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { e in
            e.state.jobs[h.transferID] == nil && (e.state.jobs[n.transferID]?.state == .downloading || e.state.jobs[r.transferID]?.state == .downloading)
        }
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

    // MARK: A fresh attempt (`AttemptVerdict.requeue`)

    /// An attempt the transport cancels on its own while the follow owes a visit is re-queued behind the places the
    /// visits give: one slot. R (zz-r, a user waiter) holds it; P (zz-p, a user waiter) waits in the queue. v3 moves zz-p to
    /// new content N; then R's attempt ends `cancelled(byClient)` (a cancel the engine did not ask for: a fresh attempt,
    /// ARCHITECTURE §7.6). Visited first, P's visit queued N at the apply and R's fresh attempt was queued behind it, so
    /// the freed slot goes to N. Re-queued at the cancel, R took the earlier place; a drain that dropped the re-queue left
    /// R failed with nobody to re-admit it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: an attempt cancelled by the transport during an owed follow is re-queued behind the places the owed visits give (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierRequeuesACancelledAttemptBehindTheOwedVisitsPlaces(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 992_502, tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0))
        let engine = s.engine
        let rBytes = EngineFixture.bytes(992_510, count: 16)
        let pBytes = EngineFixture.bytes(992_511, count: 16)
        let nBytes = EngineFixture.bytes(992_512, count: 16)
        let r = EngineHarness.onDemand("zz-r", rBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(767_000) + [p, r], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(r.transferID, [.hold, .hold, .stage(rBytes)])
        await s.harness.source.script(p.transferID, [.stage(pBytes)])
        let rWaiter = Task { await engine.awaitAsset(r.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[r.transferID]?.state == .downloading }
        await engine.waitForHandle(r.transferID)
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .queued }
        let n = EngineHarness.onDemand("zz-p", nBytes)
        await s.harness.source.script(n.transferID, [.hold, .stage(nBytes)])
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(867_000) + [n, r], s, visit: visit)
        // R's attempt ends cancelled by the transport (sweep-first: while the follow owes P's visit).
        await s.harness.source.release(r.transferID, with: .failed(.cancelled(.byClient)))
        await engine.awaitCondition { $0.state.jobs[r.transferID]?.state != .downloading }
        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { $0.followOwed }
            #expect(owed, "setup: R's attempt ended while the follow owes P's visit")
        }
        let starts = await s.harness.source.starts.count
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { e in
            !e.followBarrier && !e.state.drainFollowUpScheduled && (e.state.jobs[n.transferID]?.state == .downloading || e.state.jobs[r.transferID]?.state == .downloading)
        }
        await engine.waitForAllHandles()
        let after = await engine.readForTests { e in (n: e.state.jobs[n.transferID]?.state, r: e.state.jobs[r.transferID]?.state) }
        let next = await s.harness.source.starts.dropFirst(starts).map(\.id)
        #expect(after.n == .downloading && after.r == .queued, "R's fresh attempt waits in the queue behind N, queued at P's visit (visit-first): \(after)")
        #expect(visit == .followVisitedFirst || next.first == n.transferID, "the next start is N's: \(next)")
        await s.harness.source.release(n.transferID, with: .progress(received: 0, expected: nil))
        await s.harness.source.release(r.transferID, with: .progress(received: 0, expected: nil))
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let rResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: rWaiter) }
        #expect((try? pResult.get())?.byteSize == 16 && (try? rResult.get())?.byteSize == 16, "P is served from N and R from its fresh attempt: \(pResult) \(rResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    // MARK: A policy pause on a lane the conditions refuse (`AttemptVerdict.pause`)

    /// A policy pause that ends while the follow owes a visit, on a lane the conditions still refuse after the visits,
    /// parks its job with the place it had, as a visit-first engine's pause did: under Low Data Mode, X (1 MB) downloads
    /// for U's user waiter (b-x) and a prefetch member (zz-x); Y (zz-y), a later member, waits (the policy parks it once a
    /// slot frees); H holds the other of two slots. v3 moves b-x to new content M, so the follow's first turn lowers X to the prefetch lane and
    /// pauses it; the pause ends while the rest of the follow is owed. Visited first, X was parked on its policy with its
    /// ticket, ahead of Y's, so when the network is unrestricted again X is re-admitted, and starts, before Y. Queued at
    /// the front instead, X took a fresh ticket, the gate parked it behind Y, and Y started first.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-7: a policy pause that ends during an owed follow parks its job with its place on the lane the follow leaves (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierParksAPolicyPauseWithItsPlace(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 992_602, tuning: SyncTuning(maxConcurrentTransfers: 2, preemptLowerLanes: false))
        let engine = s.engine
        let xBytes = Data(repeating: 0xD1, count: 1_000_000)
        let hBytes = EngineFixture.bytes(992_610, count: 16)
        let yBytes = EngineFixture.bytes(992_611, count: 16)
        let mBytes = EngineFixture.bytes(992_612, count: 16)
        let bx = EngineHarness.onDemand("b-x", xBytes)
        let zx = EngineHarness.onDemand("zz-x", xBytes)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        let y = EngineHarness.onDemand("zz-y", yBytes)
        try #require(bx.transferID == zx.transferID, "setup: b-x and zz-x share X")
        await s.harness.serveManifest([s.q, bx] + FollowBarrier.fillers(768_000) + [h, zx, y], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        await s.harness.source.script(bx.transferID, [.hold, .hold, .stage(xBytes)])
        await s.harness.source.script(y.transferID, [.hold, .stage(yBytes)])
        let hWaiter = Task { await engine.awaitAsset(h.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[h.transferID]?.state == .downloading }
        }
        await s.harness.conditions.send(EngineRegressionCycle10Tests.constrained)
        await engine.awaitCondition { $0.state.conditions == EngineRegressionCycle10Tests.constrained }
        let uWaiter = Task { await engine.awaitAsset(bx.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[bx.transferID]?.state == .downloading }
        let group = try await engine.registerGroup([zx.identifier, y.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[bx.transferID]?.interests.count == 2 && $0.state.jobs[y.transferID] != nil }
        let tickets = await engine.readForTests { e in (x: e.state.jobs[bx.transferID]?.ticket, y: e.state.jobs[y.transferID]?.ticket) }
        try #require(tickets.x != nil && tickets.y != nil && tickets.x! < tickets.y!, "setup: X's ticket is Y's elder: \(tickets)")
        let m = EngineHarness.onDemand("b-x", mBytes)
        await s.harness.source.script(m.transferID, [.stage(mBytes)])
        await engine.readForTests { $0.holdAttemptTerminals() }
        let sync = await FollowBarrier.apply([s.q, m] + FollowBarrier.fillers(868_000) + [h, zx, y], s, visit: visit)
        await engine.awaitCondition { $0.heldAttemptTerminalCount == 1 }
        if visit == .sweepFollowsFirst {
            let before = await engine.readForTests { e in (owed: e.followOwed, lane: e.state.jobs[bx.transferID]?.lane, pause: e.state.jobs[bx.transferID]?.active?.policyPause) }
            #expect(before.owed && before.lane == .prefetch && before.pause != nil, "setup: X's visit lowered it and asked for a policy pause while the follow is owed: \(before)")
            await engine.readForTests { $0.releaseAttemptTerminals() }
            await engine.awaitCondition { $0.state.jobs[bx.transferID]?.state != .downloading }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        } else {
            await engine.readForTests { $0.releaseAttemptTerminals() }
        }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        #expect((try? uResult.get())?.byteSize == 16, "U is served from M: \(uResult)")
        await engine.awaitCondition { e in
            !e.followBarrier && !e.state.drainFollowUpScheduled && e.state.jobs[bx.transferID]?.state.isLaneParked == true && e.state.jobs[m.transferID] == nil
        }
        // The network is unrestricted again: the parked members are re-admitted in the pump's order, and one slot is free.
        let starts = await s.harness.source.starts.count
        await s.harness.conditions.send(.unrestricted)
        await engine.awaitCondition { e in
            e.state.conditions == .unrestricted && (e.state.jobs[bx.transferID]?.state == .downloading || e.state.jobs[y.transferID]?.state == .downloading)
        }
        await engine.waitForAllHandles()
        let after = await engine.readForTests { e in (x: e.state.jobs[bx.transferID]?.state, y: e.state.jobs[y.transferID]?.state) }
        let next = await s.harness.source.starts.dropFirst(starts).map(\.id)
        #expect(after.x == .downloading && after.y == .queued, "X, parked with its elder ticket, is re-admitted and starts before Y (visit-first): \(after)")
        #expect(next.first == bx.transferID, "the next start is X's: \(next)")
        await s.harness.source.release(bx.transferID, with: .progress(received: 0, expected: nil))
        await s.harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[y.transferID]?.state == .downloading }
        }
        await s.harness.source.release(y.transferID, with: .progress(received: 0, expected: nil))
        _ = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: hWaiter) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[bx.transferID] == nil && $0.state.jobs[y.transferID] == nil }
        }
        await engine.releaseGroup(group)
        await FollowBarrier.finish(s, sync: sync)
    }
}
