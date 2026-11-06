import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The publications an owed batch of re-routes holds (Stage 3 close-out cycle 21, ruling S3-R26 items 1 and 10;
/// `integrate-rr21.md` R12 and the branches rr21-B12, rr21-B13 and rr21-B21; `critic-rr21-answers.md` refutation 2): while
/// any re-route is owed no publication binds (`inboundBlocks`' counter term), since its target is known only at its
/// replay, and the batch that ends the last one resumes them (`releaseRerouteHolds`). Each test runs in both orders
/// (`LaneDropVisit`) and expects the visit-first answers in both.
extension EngineFollowBarrierTests {
    /// The answers of `waiters`, driving the clock.
    @available(macOS 15.0, iOS 18.0, *)
    static func answers(of waiters: [Task<Result<AssetLocation, AssetError>, Never>], _ c: OwedCommit) async -> [Result<AssetLocation, AssetError>] {
        var results: [Result<AssetLocation, AssetError>] = []
        for waiter in waiters {
            results.append(await EngineRegressionCycle6Tests.driving([c.s.time], fence: c.engine) { await EngineHarness.value(of: waiter) })
        }
        return results
    }

    // MARK: rr21-T14: a publication that begins while re-routes are owed waits for them

    /// rr21-T14 (rr21-B21, rr21-B12): zz-x (V's) is X's content, which downloads; K0 maps zz-a1…zz-a3 to it, O's commit
    /// owes their re-routes, and X's publication begins while they are owed: it waits. The replay joins W1…W3 to X,
    /// verifying, and the batch's end resumes X's publication, whose binding then holds the three ids: one request of X
    /// serves V and W1…W3, as visited first, where the commit had joined them to X downloading.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a publication that begins while re-routes are owed waits for them and binds the ids they bring (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func publicationWaitsForOwedReroutesAndBindsTheirIDs(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_501
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [x])
        let engine = c.engine
        let xT = x.transferID
        await c.s.harness.source.script(xT, [.hold, .stage(xBytes), .stage(xBytes)])
        let v = await Self.downloadingWaiter(x, c)
        let held = try await Self.oweThroughK0(c, k0: [x] + Self.movedOnto(xBytes, c), visit: visit)
        await c.s.harness.source.release(xT, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[xT]?.state == .verifying && $0.state.inboundWaits[xT] != nil }
        let turns = await Self.releaseOwedTurns(c)
        let stranded = await engine.readForTests { $0.state.inboundWaits.keys.sorted() }
        try #require(stranded.isEmpty, "the batch's end resumed X's publication: \(stranded)")
        await held.stop()
        let answers = await Self.owedAnswers(c)
        let others = await Self.answers(of: [v], c)
        #expect(Self.sizes([answers.k]) == [16] && Self.sizes(others + answers.w) == [18, 18, 18, 18], "K gets O's bytes, V and W1…W3 X's (visit-first): \(answers), V \(others)")
        #expect(await Self.starts(xT, c) == 1, "one request of X serves V and W1…W3 (visit-first)")
        #expect(turns.violations.isEmpty, "\(turns.violations.prefix(3))")
        await Self.finishHeld(c.s)
    }

    // MARK: rr21-T17-hold and rr21-T17: two batches owed

    /// Two owed batches (`twoOwedBatches`): their engine, the second O's waiters, V's, and the store units still held.
    @available(macOS 15.0, iOS 18.0, *)
    struct TwoBatches {
        let c: OwedCommit
        /// zz-p on P's content, and its user waiter.
        let p: ManifestEntry
        let kp: Task<Result<AssetLocation, AssetError>, Never>
        /// zz-b1…zz-b3 on P's content, which K0 maps to X's, and their user waiters.
        let wb: [Task<Result<AssetLocation, AssetError>, Never>]
        /// zz-x on X's content, and V, its user waiter.
        let x: ManifestEntry
        let v: Task<Result<AssetLocation, AssetError>, Never>
        let held: HeldUnits
    }

    /// zz-o (K) and zz-a1…zz-a3 (W1…W3) are O's content; zz-p (KP) and zz-b1…zz-b3 (WB1…WB3) P's; zz-x (V) X's. O, P and
    /// X download; O and P publish, held at their first store units; K0 (swept or visited first) maps every a and b to
    /// X's content. O commits, owing the a's re-routes (batch A); then `between` runs; then P commits, owing the b's
    /// (batch B). The drain's turns stay held.
    @available(macOS 15.0, iOS 18.0, *)
    static func twoOwedBatches(_ visit: LaneDropVisit, seed: UInt64, xScript: [FakeTransferStep], between: @Sendable (OwedCommit, TransferID) async -> Void) async throws -> TwoBatches {
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let pBytes = EngineFixture.bytes(seed + 6, count: 16)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        let onP = (1...3).map { EngineHarness.onDemand("zz-b\($0)", pBytes) }
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [p] + onP + [x])
        let engine = c.engine
        let pT = p.transferID
        let xT = x.transferID
        await c.s.harness.source.script(pT, [.hold, .stage(pBytes)])
        await c.s.harness.source.script(xT, xScript)
        let kp = await Self.downloadingWaiter(p, c)
        var wb: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for entry in onP {
            let id = entry.identifier
            wb.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
        }
        await engine.awaitCondition { $0.state.jobs[pT]?.interests.count == 4 }
        let v = await Self.downloadingWaiter(x, c)
        let (units, releaser) = try await Self.holdPublications(of: [c.transfer, pT], c.s, bulk: c.bulk)
        var held = HeldUnits(bulk: c.bulk, kept: units, releaser: releaser)
        let bOnX = onP.map { EngineHarness.onDemand($0.identifier.rawValue, xBytes) }
        try await Self.applyHeld(c.manifest([p, x] + Self.movedOnto(xBytes, c) + bOnX, round: 1), tag: "k0-two-batches-\(seed)", c.s, visit: visit)
        await engine.readForTests { $0.holdDrainFollowUps() }
        await held.release(units[0])
        let o = c.transfer
        await engine.awaitCondition { $0.state.jobs[o] == nil }
        let first = await engine.readForTests { e in Self.owedBatches(e) }
        try #require(first.count == 1 && first.first?.items.count == 3, "setup: O's commit owes batch A: \(first.map(\.items.count))")
        await between(c, xT)
        await held.release(units[1])
        await engine.awaitCondition { $0.state.jobs[pT] == nil }
        let batches = await engine.readForTests { e in Self.owedBatches(e).map { $0.from } }
        try #require(batches == [c.transfer, pT], "setup: O's batch and P's wait, in that order: \(batches)")
        return TwoBatches(c: c, p: p, kp: kp, wb: wb, x: x, v: v, held: held)
    }

    /// rr21-T17-hold (rr21-B13): with batches A and B owed, X's publication begins and waits; the drain makes A first, and
    /// X still waits once A ends, since B is still owed (`releaseRerouteHolds`' guard); B's end resumes it, and its
    /// binding holds every a and b: one request of X serves V, W1…W3 and WB1…WB3, as visited first, where both commits
    /// had joined them to X downloading.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a publication held by two owed batches stays held until the last one ends (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func publicationHeldByTwoBatchesWaitsForTheLast(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_511
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let two = try await Self.twoOwedBatches(visit, seed: seed, xScript: [.hold, .stage(xBytes), .stage(xBytes)]) { _, _ in }
        let c = two.c
        let engine = c.engine
        let xT = two.x.transferID
        await c.s.harness.source.release(xT, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[xT]?.state == .verifying && $0.state.inboundWaits[xT] != nil }
        var holding: [Bool] = []
        var violations: [String] = []
        while await engine.readForTests({ $0.followOwed || !$0.state.eventsAfterFollow.isEmpty }) {
            let before = await engine.readForTests { Self.owedBatches($0).count }
            _ = await Self.runOneHeldTurn(engine)
            violations += await engine.invariantViolations()
            let after = await engine.readForTests { e in (batches: Self.owedBatches(e).count, waits: e.state.inboundWaits[xT] != nil) }
            if before == 2 && after.batches == 1 {
                holding.append(after.waits)
            }
        }
        await engine.readForTests { e in
            e.releaseDrainFollowUps()
            e.releaseFollowFollowUps()
        }
        #expect(holding == [true], "X's publication still waits once batch A ends: \(holding)")
        await two.held.stop()
        let answers = await Self.owedAnswers(c)
        let others = await Self.answers(of: [two.v, two.kp] + two.wb, c)
        #expect(Self.sizes([answers.k]) == [16] && Self.sizes(answers.w) == [18, 18, 18], "K gets O's bytes, W1…W3 X's: \(answers)")
        #expect(Self.sizes(others) == [18, 16, 18, 18, 18], "V gets X's bytes, KP P's, WB1…WB3 X's: \(others)")
        #expect(await Self.starts(xT, c) == 1, "one request of X serves every a and b (visit-first)")
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await Self.finishHeld(c.s)
    }

    /// rr21-T17 (the owing sites append, `deferToFollow`): X's 404 arrives between the two commits, its verdict deferred
    /// behind batch A; batch B waits behind the verdict. Visited first, O's commit joined W1…W3 to X downloading, X's 404
    /// answered them, and P's commit, after it, re-routed WB1…WB3 to a fresh job of X's content, whose second attempt
    /// served them. The drain replays A, the verdict and B in that order: the same answers.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: two owed batches replay in their owing order around a verdict between them (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedBatchesReplayInTheirOrderAroundAVerdict(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_521
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let two = try await Self.twoOwedBatches(visit, seed: seed, xScript: [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(xBytes)]) { c, xT in
            await c.s.harness.source.release(xT, with: .progress(received: 0, expected: nil))
            await c.engine.awaitCondition { $0.state.verdictsAfterFollow[xT] != nil }
        }
        let c = two.c
        let outcome = await Self.finishOwed(c, held: two.held, others: [two.v, two.kp] + two.wb)
        #expect(Self.sizes([outcome.k]) == [16] && outcome.w.allSatisfy { $0 == .failure(.notFound) }, "K gets O's bytes, W1…W3 X's 404 (visit-first): \(outcome)")
        #expect(outcome.others[0] == .failure(.notFound) && Self.sizes(Array(outcome.others.dropFirst())) == [16, 18, 18, 18], "V gets X's 404, KP P's bytes, WB1…WB3 X's from its second attempt (visit-first): \(outcome)")
        #expect(await Self.starts(two.x.transferID, c) == 2, "X's content is requested twice")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
        await Self.finishHeld(c.s)
    }

    // MARK: RR21-WINDOW-GATE: a publication during the window binds what the re-routes bring

    /// RR21-WINDOW-GATE (rr21-B21; `critic-rr21-answers.md` refutation 2): zz-p (Q's) is P's content, which downloads, and
    /// zz-e's 403 opens the breaker (`authDistinctAssets` 1) before K0 maps zz-a1…zz-a3 to P's content; O's commit owes
    /// their re-routes, and P's bytes arrive while they are owed. Visited first, the commit joined W1…W3 to P downloading
    /// and P's binding held them: no request after the breaker opened. P's publication waits for the replay, which joins
    /// them to P verifying, and binds them: no fresh job of P's content, which the open breaker would have refused.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a publication that begins while re-routes are owed binds their ids though the gate closed before the site (F-28, RR21-WINDOW-GATE)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func publicationDuringTheWindowBindsTheOwedIDsBehindAClosedGate(_ visit: LaneDropVisit) async throws {
        try await self.windowGate(visit, seed: 2_027_531, superseded: false)
    }

    /// RR21-WINDOW-GATE's shape (`publicationDuringTheWindowBindsTheOwedIDsBehindAClosedGate`). With `superseded` (site
    /// 3), K0 also maps zz-o onto P's content: the store refuses O's publication, and its exit owes K's re-route with
    /// W1…W3's. Visited first, the exit joined all four to P downloading, and P's binding held them, so K gets P's bytes
    /// too.
    @available(macOS 15.0, iOS 18.0, *)
    func windowGate(_ visit: LaneDropVisit, seed: UInt64, superseded: Bool) async throws {
        let tuning = SyncTuning(breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let pBytes = EngineFixture.bytes(seed + 5, count: 18)
        let eBytes = EngineFixture.bytes(seed + 6, count: 16)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        let e = EngineHarness.onDemand("zz-e", eBytes)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [p, e], tuning: tuning, away: superseded ? pBytes : nil)
        let engine = c.engine
        let pT = p.transferID
        let origin = c.s.harness.source.originID
        await c.s.harness.source.script(pT, [.hold, .stage(pBytes), .stage(pBytes)])
        await c.s.harness.source.script(e.transferID, [.fail(EngineRegressionCycle20Tests.forbidden)])
        let q = await Self.downloadingWaiter(p, c)
        let eID = e.identifier
        let eResult = await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) { await engine.awaitAsset(eID, lane: .userInitiated) }
        #expect((try? eResult.get()) == nil, "setup: zz-e's 403 fails it: \(eResult)")
        let opened = await engine.readForTests { e in
            if case .open? = e.state.breakers[origin]?.state {
                return true
            }
            return false
        }
        try #require(opened, "setup: zz-e's 403 opened the breaker")
        let held = try await Self.oweThroughK0(c, k0: [p, e] + Self.movedOnto(pBytes, c), visit: visit)
        await c.s.harness.source.release(pT, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[pT]?.state == .verifying && $0.state.inboundWaits[pT] != nil }
        let created = await engine.readForTests { $0.state.jobsCreated }
        let outcome = await Self.finishOwed(c, held: held, others: [q])
        let createdAfter = await engine.readForTests { $0.state.jobsCreated }
        let kBytes: Int64 = superseded ? 18 : 16
        #expect(Self.sizes([outcome.k]) == [kBytes] && Self.sizes(outcome.others + outcome.w) == [18, 18, 18, 18], "K gets \(superseded ? "P's" : "O's") bytes, Q and W1…W3 P's (visit-first): \(outcome)")
        let pStarts = await Self.starts(pT, c)
        #expect(createdAfter == created && pStarts == 1, "no fresh job of P's content: \(created) -> \(createdAfter), P's starts \(pStarts)")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
        await Self.finishHeld(c.s)
    }
}
