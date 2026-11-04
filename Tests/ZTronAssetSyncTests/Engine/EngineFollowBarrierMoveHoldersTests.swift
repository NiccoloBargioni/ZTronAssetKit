import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Which interests a move re-routes, in what order and how many a turn (Stage 3 close-out cycle 21, ruling S3-R26 item
/// 3; `integrate-c21.md` item B, tests T2, T3 and T6): a move reads a moved id's holders from its job's index
/// (`Job.tokensByID`), where it walked every interest of the job, so these pin what the walk gave: every holder of a
/// moved id, re-routed by token and then id, at most a turn's ids a turn. Each runs in both orders (`LaneDropVisit`),
/// with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    // MARK: T2: a move re-routes its interests by token, then id

    /// Eight user waiters t1 < … < t8 on H's 16 bytes, at ids whose order is the reverse of theirs (t1 waits for zz-m8,
    /// …, t8 for zz-m1), and a ninth at zz-k, which stays, so H is not superseded; H downloads (held). v3 maps the eight
    /// to eight contents of their own: H's visit moves them in one move that fits the turn (`move`), which re-routes them
    /// by token and then id, so the eight contents' jobs are created, queued and admitted in the waiters' token order.
    /// The order is the engine's own (`EngineState.admissionsForTests`), never the fake transport's, whose records race
    /// once more than one attempt runs (ruling S3-R25 item 4; critique A3).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a move re-routes its holder's interests by token and then id (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierReroutesAMovesInterestsByToken(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_023_101
        let (s, _) = try await FollowBarrier.setUp(seed: seed)
        let engine = s.engine
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let k = EngineHarness.onDemand("zz-k", hBytes)
        let names = (1...8).map { "zz-m\($0)" }
        let onH = names.map { EngineHarness.onDemand($0, hBytes) }
        let payloads = (0..<8).map { EngineFixture.bytes(seed + 10 + UInt64($0), count: 20 + $0) }
        let moved = names.indices.map { EngineHarness.onDemand(names[$0], payloads[$0]) }
        let holder = k.transferID
        let contents = moved.map(\.transferID)
        try #require(onH.allSatisfy { $0.transferID == holder } && Set(contents).count == 8 && !contents.contains(holder), "setup: the eight share H's content, and v3 gives each one of its own")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + onH + [k] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(holder, [.hold, .stage(hBytes)])
        for (entry, bytes) in zip(moved, payloads) {
            await s.harness.source.script(entry.transferID, [.stage(bytes)])
        }
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[holder]?.state == .downloading }
        }
        // t1 waits for zz-m8, t8 for zz-m1: each joins before the next asks, so their tokens rise in that order.
        var waiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for (index, entry) in onH.enumerated().reversed() {
            let id = entry.identifier
            waiters.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
            let joined = 9 - index
            await engine.awaitCondition { $0.state.jobs[holder]?.interests.count == joined }
        }
        let tokens = await engine.readForTests { e in names.reversed().map { name in e.state.waiters.first { $0.value.asset == AssetID(name) }?.key } }
        let ordered = tokens.compactMap { $0 }
        try #require(ordered.count == 8 && ordered == ordered.sorted(), "setup: the waiters' tokens rise from zz-m8's to zz-m1's: \(tokens)")
        await engine.readForTests { $0.state.admissionsForTests = [] }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + moved + [k] + Self.laterFillers(seed + 6_000), tag: "v3-token-order-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            var turns = 0
            while await engine.readForTests({ $0.followOwed }) {
                try #require(turns < 16, "the follow ends within 16 turns")
                await Self.runOneFollowTurn(engine)
                turns += 1
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        var results: [Result<AssetLocation, AssetError>] = []
        for waiter in waiters {
            results.append(await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        let admitted = await engine.readForTests { $0.state.admissionsForTests ?? [] }
        var firstAdmissions: [TransferID] = []
        for admission in admitted where contents.contains(admission.transfer) && !firstAdmissions.contains(admission.transfer) {
            firstAdmissions.append(admission.transfer)
        }
        #expect(firstAdmissions == contents.reversed(), "the eight contents are admitted in their waiters' token order, zz-m8's first: \(firstAdmissions.map { contents.firstIndex(of: $0).map { names[$0] } ?? "?" })")
        #expect(results.map { (try? $0.get())?.byteSize } == (0..<8).reversed().map { 20 + $0 }, "each waiter gets its id's new content: \(results)")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await s.harness.source.release(holder, with: .progress(received: 0, expected: nil))
        let kResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        #expect((try? kResult.get())?.byteSize == 16, "the ninth waiter gets H's bytes: \(kResult)")
        await Self.finishHeld(s)
    }

    // MARK: T3: a move re-routes every holder of a moved id

    /// W1 (a user waiter) joins zz-t on H's 16 bytes first, so it is the id's first holder; then G (a prefetch group of
    /// zz-t, and with `bounded` of zz-b0 … zz-b4 too) and W2 (a second user waiter) join it; K (a prefetch waiter) holds
    /// zz-k, which stays, so H is not superseded; H downloads (held). W1 is withdrawn: one of the other two becomes the
    /// id's first holder (`IDTokens.remove`'s promotion; critique A6). v3 maps zz-t (and the five) to O's content; H's
    /// visit moves them in one move that fits the turn, or with `bounded` over turns of four ids
    /// (`EngineState.followIDsPerTurn`, `startMove`). Both of zz-t's holders are re-routed onto O's job: W2 gets O's
    /// bytes, and G's interest holds every moved id there.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a move re-routes every interest that holds a moved id, the one promoted when the id's first holder left among them (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, [false, true])
    func barrierReroutesEveryHolderOfAMovedID(_ visit: LaneDropVisit, _ bounded: Bool) async throws {
        let seed: UInt64 = bounded ? 2_023_211 : 2_023_201
        let (s, _) = try await FollowBarrier.setUp(seed: seed)
        let engine = s.engine
        if bounded {
            await engine.readForTests { $0.state.followIDsPerTurn = 4 }
        }
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let oBytes = EngineFixture.bytes(seed + 3, count: 24)
        let t = EngineHarness.onDemand("zz-t", hBytes)
        let k = EngineHarness.onDemand("zz-k", hBytes)
        let names = (0..<(bounded ? 5 : 0)).map { "zz-b\($0)" }
        let onH = names.map { EngineHarness.onDemand($0, hBytes) }
        let tOnO = EngineHarness.onDemand("zz-t", oBytes)
        let onO = names.map { EngineHarness.onDemand($0, oBytes) }
        let holder = t.transferID
        let o = tOnO.transferID
        try #require((onH + [k]).allSatisfy { $0.transferID == holder } && onO.allSatisfy { $0.transferID == o } && o != holder, "setup: H's ids share its content, and v3 maps the moved ones to O's")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + onH + [k, t] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(holder, [.hold, .stage(hBytes)])
        await s.harness.source.script(o, [.hold, .stage(oBytes)])
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[holder]?.state == .downloading }
        }
        let w1 = Task { await engine.awaitAsset(t.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[holder]?.interests.count == 2 }
        let first = try #require(await engine.readForTests { e in e.state.waiters.first { $0.value.asset == t.identifier }?.key }, "setup: W1 waits")
        let g = try await engine.registerGroup([t.identifier] + onH.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[holder]?.interests[g] != nil }
        let w2 = Task { await engine.awaitAsset(t.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[holder]?.interests.count == 4 }
        let joined = await engine.readForTests { e in e.state.jobs[holder]?.tokensByID[t.identifier].map { (first: $0.first, count: $0.tokens.count) } }
        try #require(joined?.first == first && joined?.count == 3, "setup: W1 joined zz-t first, then G and W2: \(String(describing: joined))")
        w1.cancel()
        let w1Result = await w1.value
        #expect(w1Result == .failure(.cancelled), "W1's caller is answered at once: \(w1Result)")
        await engine.awaitCondition { $0.state.jobs[holder]?.interests.count == 3 }
        let promoted = await engine.readForTests { e in e.state.jobs[holder]?.tokensByID[t.identifier].map { (first: $0.first, tokens: $0.tokens) } }
        #expect(promoted.map { $0.first != first && $0.tokens.count == 2 && !$0.tokens.contains(first) && $0.tokens.contains(g) } == true, "one of G and W2 is zz-t's first holder now, the other the other: \(String(describing: promoted))")
        let withdrawn = await engine.invariantViolations()
        #expect(withdrawn.isEmpty, "the index follows W1's withdrawal: \(withdrawn.prefix(3))")
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + onO + [k, tOnO] + Self.laterFillers(seed + 6_000), tag: "v3-holders-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            var turns = 0
            while await engine.readForTests({ $0.followOwed }) {
                try #require(turns < 16, "the follow ends within 16 turns")
                await Self.runOneFollowTurn(engine)
                turns += 1
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[o]?.state == .downloading }
        }
        let after = await engine.readForTests { e in (onO: e.state.jobs[o]?.interests.count, g: e.state.jobs[o]?.interests[g]?.assets, h: e.state.jobs[holder]?.assets, hInterests: e.state.jobs[holder]?.interests.count) }
        #expect(after.onO == 2 && after.g == Set([t.identifier] + onH.map(\.identifier)), "G's interest in every moved id and W2's are on O's job: \(after)")
        #expect(after.h == [k.identifier] && after.hInterests == 1, "H keeps zz-k and K alone: \(after)")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await s.harness.source.release(o, with: .progress(received: 0, expected: nil))
        let w2Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: w2) }
        #expect((try? w2Result.get())?.byteSize == 24, "W2 gets O's bytes: \(w2Result)")
        await s.harness.source.release(holder, with: .progress(received: 0, expected: nil))
        let kResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        #expect((try? kResult.get())?.byteSize == 16, "K gets H's bytes: \(kResult)")
        await engine.releaseGroup(g)
        await Self.finishHeld(s)
    }

    // MARK: T6: one-id moves owed off one holder, at most a turn's ids a turn

    /// H, a prefetch group G of 40 members (zz-h00 … zz-h39) sharing 16 bytes, downloads (held); eight user waiters
    /// U0 … U7 on contents of their own publish, each held at its first store unit. v3 maps H's first eight members each
    /// to one Ui's content, and v4 (the same mapping, other fillers) follows. Visited first, v3's follow visits H and
    /// moves the eight over turns of four ids (`startMove`). Swept first, v3's follow is still owed at v4, whose walk
    /// finds one move off H per publication (`bringInboundOntoPublications`), owed to the follow's turns
    /// (`continueInbound`), which spend at most four ids a turn (`EngineState.followIDsPerTurn`), the apply's turn at most
    /// `inboundIDsNow` (two). Either way each Ui's job ends holding its member for G and its waiter, and H the other 32.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: one-id moves owed off one holder take at most a turn's ids a turn, the apply's turn at most half of them (C2, F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierBoundsOneIDMovesOffAHolderPerTurn(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_023_301
        let perTurn = 4
        // No preemption: the users' downloads must not cancel H's held attempt.
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 1, preemptLowerLanes: false))
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = perTurn }
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let names = (0..<40).map { String(format: "zz-h%02d", $0) }
        let onH = names.map { EngineHarness.onDemand($0, hBytes) }
        let uBytes = (0..<8).map { EngineFixture.bytes(seed + 10 + UInt64($0), count: 20 + $0) }
        let users = (0..<8).map { EngineHarness.onDemand("zz-u\($0)", uBytes[$0]) }
        let movedH = names.indices.map { $0 < 8 ? EngineHarness.onDemand(names[$0], uBytes[$0]) : onH[$0] }
        let holder = onH[0].transferID
        let contents = users.map(\.transferID)
        try #require(onH.allSatisfy { $0.transferID == holder } && Set(contents).count == 8 && !contents.contains(holder) && movedH.prefix(8).map(\.transferID) == contents, "setup: H's members share its content, and v3 maps the first eight to the users'")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + onH + users + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(holder, [.hold, .stage(hBytes)])
        for (user, bytes) in zip(users, uBytes) {
            await s.harness.source.script(user.transferID, [.stage(bytes)])
        }
        let g = try await engine.registerGroup(onH.map(\.identifier), lane: .prefetch).get()
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[holder]?.state == .downloading && $0.state.jobs[holder]?.assets.count == 40 }
        }
        await engine.awaitCondition { !$0.state.storeWorkInFlight }
        await bulk.setHolding(true)
        var waiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for user in users {
            let id = user.identifier
            waiters.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
        }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in contents.allSatisfy { e.state.jobs[$0]?.state == .verifying } }
        }
        try await bulk.requireHeldUnits(atLeast: 8)
        let publications = Set(await bulk.heldUnits)
        let releaser = Task {
            while !Task.isCancelled {
                await bulk.waitForHeldUnits(atLeast: publications.count + 1)
                for other in await bulk.heldUnits where !publications.contains(other) {
                    await bulk.release(other)
                }
            }
        }
        let ids = onH.map(\.identifier)
        let left: @Sendable () async -> Int = { await Self.membersLeft(engine, on: holder, members: ids) }
        var applyTurns: [Int] = []
        var turns: [Int] = []
        var now = await left()
        try #require(now == 40, "setup: H holds its 40 members: \(now)")
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + movedH + users + Self.laterFillers(seed + 6_000), tag: "v3-one-id-moves-\(seed)", s, visit: .sweepFollowsFirst)
        var after = await left()
        applyTurns.append(now - after)
        now = after
        for pass in 0..<2 {
            if pass == 1 {
                try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 300) + movedH + users + Self.laterFillers(seed + 9_000), tag: "v4-one-id-moves-\(seed)", s, visit: .sweepFollowsFirst)
                after = await left()
                applyTurns.append(now - after)
                now = after
                if visit == .sweepFollowsFirst {
                    let owed = await engine.readForTests { e in e.state.inboundMoves[e.state.inboundNext...].filter { $0.holder == holder }.map(\.ids.count) }
                    #expect(owed.count + (40 - now) == 8 && owed.allSatisfy { $0 == 1 }, "setup: v4's walk owes one one-id move off H per publication: \(owed)")
                }
            }
            guard pass == 1 || visit == .followVisitedFirst else {
                continue
            }
            while await engine.readForTests({ $0.followOwed }) {
                try #require(turns.count < 32, "the follow ends within 32 turns: \(turns)")
                await Self.runOneFollowTurn(engine)
                after = await left()
                turns.append(now - after)
                now = after
                let violations = await engine.invariantViolations()
                #expect(violations.isEmpty, "after turn \(turns.count): \(violations.prefix(3))")
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        #expect(applyTurns.allSatisfy { $0 <= perTurn / 2 }, "an apply's turn moves at most inboundIDsNow ids: \(applyTurns)")
        #expect(turns.allSatisfy { $0 <= perTurn }, "no follow turn moves more than followIDsPerTurn ids: \(turns)")
        #expect(applyTurns.reduce(0, +) + turns.reduce(0, +) == 8 && now == 32, "eight members left H over the turns, and H holds 32: \(applyTurns), \(turns)")
        let onUsers = await engine.readForTests { e in contents.indices.map { index in e.state.jobs[contents[index]].map { $0.assets == [users[index].identifier, AssetID(names[index])] && $0.interests.count == 2 && $0.interests[g]?.assets == [AssetID(names[index])] } ?? false } }
        #expect(onUsers.allSatisfy { $0 }, "each user's job holds its waiter's id and its member for G: \(onUsers)")
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        await bulk.releaseAll()
        var results: [Result<AssetLocation, AssetError>] = []
        for waiter in waiters {
            results.append(await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        #expect(results.map { (try? $0.get())?.byteSize } == (0..<8).map { 20 + $0 }, "each waiter gets its content's bytes: \(results)")
        await s.harness.source.release(holder, with: .progress(received: 0, expected: nil))
        await engine.releaseGroup(g)
        await Self.finishHeld(s)
    }
}
