import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The follow's id bound holds for a whole turn, across the holders its moves and visits take ids off (Stage 3 close-out
/// cycle 20, ruling S3-R25 item 5; the cycle-19 requirements verifier's PROBE-C19R-TWO-HOLDER-TURN and
/// PROBE-C19R-THREE-HOLDER-VISITS): `barrierMovesASharedContentsIDsOverBoundedTurns` counts the members that leave one
/// holder a turn, so a turn that went on to a second holder with the ids the first had spent was not seen. Here each
/// sweep-first turn counts the members that left any holder. The bound is set small (`EngineState.followIDsPerTurn`,
/// S3-R23 item 3). Each case runs in both orders (`LaneDropVisit`), with the visit-first answers expected in both.
extension EngineFollowBarrierTests {
    /// The ids a turn moves in these tests.
    static let turnTotalIDsPerTurn = 4

    /// Two owed moves off two holders in the follow's turns. H1 (zz-a00…05, 16 bytes) and H2 (zz-b00…05, 20 bytes) each
    /// hold six members with a prefetch waiter each, both downloading (held); O (zz-o, 24 bytes) has a user waiter and
    /// downloads (held). v3 maps all twelve members to O's content. Sweep-first, O's 404 arrives before the follow's
    /// first follow-up turn: its attempt's end owes one move per holder (H1 → O, H2 → O, six ids each) and makes
    /// `inboundIDsNow` (two) of them; the follow's turns make the rest, and a turn that ends H1's move goes on to H2's
    /// with what H1's left (`continueInbound`). Visited first, v3's visit moved every member onto O's job at the apply,
    /// and O's 404 answered them all.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: the follow's turns that make owed moves off two holders each move at most followIDsPerTurn ids across both, with the visit-first answers (C2, F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierBoundsAnOwedMovesTurnAcrossHolders(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_919_952
        let tuning = SyncTuning(maxConcurrentTransfers: 5, reservedInteractiveSlots: 2)
        let (s, _) = try await Self.setUpHeldPublications(seed: seed, tuning: tuning)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = Self.turnTotalIDsPerTurn }
        let oBytes = EngineFixture.bytes(seed + 3, count: 24)
        let h1Bytes = EngineFixture.bytes(seed + 4, count: 16)
        let h2Bytes = EngineFixture.bytes(seed + 5, count: 20)
        let o = EngineHarness.onDemand("zz-o", oBytes)
        let aNames = (0..<6).map { String(format: "zz-a%02d", $0) }
        let bNames = (0..<6).map { String(format: "zz-b%02d", $0) }
        let onH1 = aNames.map { EngineHarness.onDemand($0, h1Bytes) }
        let onH2 = bNames.map { EngineHarness.onDemand($0, h2Bytes) }
        let onO = (aNames + bNames).map { EngineHarness.onDemand($0, oBytes) }
        let h1 = try #require(onH1.first?.transferID)
        let h2 = try #require(onH2.first?.transferID)
        try #require(Set(onH1.map(\.transferID)) == [h1] && Set(onH2.map(\.transferID)) == [h2] && Set([h1, h2, o.transferID]).count == 3, "setup: two shared contents and O's")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + onH1 + onH2 + [o] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(o.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        await s.harness.source.script(h1, [.hold, .stage(h1Bytes)])
        await s.harness.source.script(h2, [.hold, .stage(h2Bytes)])
        let oWaiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[o.transferID]?.state == .downloading }
        }
        var waiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for member in onH1 + onH2 {
            let id = member.identifier
            waiters.append(Task { await engine.awaitAsset(id, lane: .prefetch) })
        }
        await engine.awaitCondition { $0.state.jobs[h1]?.interests.count == 6 && $0.state.jobs[h2]?.interests.count == 6 }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[h1]?.state == .downloading && $0.state.jobs[h2]?.state == .downloading }
        }
        let ids = (onH1 + onH2).map(\.identifier)
        let left: @Sendable () async -> Int = {
            await Self.membersLeft(engine, on: h1, members: ids) + Self.membersLeft(engine, on: h2, members: ids)
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + onO + [o] + Self.laterFillers(seed + 6_000), tag: "v3-two-holder-\(seed)", s, visit: visit)
        var turns: [Int] = []
        var moveSizes: [Int] = []
        if visit == .sweepFollowsFirst {
            var now = await left()
            try #require(now == 12, "setup: no member moved before the follow's turns: \(now)")
            await s.harness.source.release(o.transferID, with: .progress(received: 0, expected: nil))
            await engine.awaitCondition { $0.state.verdictsAfterFollow[o.transferID] != nil }
            moveSizes = await engine.readForTests { e in
                e.state.inboundMoves[e.state.inboundNext...].map { $0.ids.count }
            }
            var after = await left()
            turns.append(now - after)
            now = after
            while await engine.readForTests({ $0.followOwed }) {
                try #require(turns.count < 16, "the follow ends within 16 turns: \(turns)")
                await Self.runOneFollowTurn(engine)
                after = await left()
                turns.append(now - after)
                now = after
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        } else {
            await s.harness.source.release(o.transferID, with: .progress(received: 0, expected: nil))
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let oResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: oWaiter) }
        var members: [Result<AssetLocation, AssetError>] = []
        for waiter in waiters {
            members.append(await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        #expect(oResult == .failure(.notFound), "O's waiter gets its 404: \(oResult)")
        #expect(members.allSatisfy { $0 == .failure(.notFound) }, "every member gets O's 404 (visit-first): \(members)")
        if visit == .sweepFollowsFirst {
            #expect(moveSizes.sorted() == [6, 6], "setup: O's attempt's end owes one move per holder: \(moveSizes)")
            #expect(turns.reduce(0, +) == 12, "every member left its job over the turns: \(turns)")
            #expect(turns.allSatisfy { $0 <= Self.turnTotalIDsPerTurn }, "no turn moves more than followIDsPerTurn ids across the holders: \(turns)")
        }
        await Self.finishHeld(s)
    }

    /// Three holders' visits in the follow's turns. H1 (six members, 16 bytes), H2 and H3 (three each, 20 and 22 bytes)
    /// each hold their members with a prefetch waiter each, all downloading (held); O (zz-o, 24 bytes) has a user waiter
    /// and downloads (held). v3 maps all twelve members to O's content. Sweep-first, the follow's first turn visits H1
    /// and leaves two of its ids to the next (`followMoving`), which ends that rest and goes on to visit H2 with what the
    /// rest left (`continueVisitRemainder`, then the visits). O's bytes arrive once the follow ended. Visited first, v3's
    /// visit moved every member onto O's job at the apply, and O's bytes served them all.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: the follow's turns that end a visit's rest and visit further holders each move at most followIDsPerTurn ids across them, with the visit-first answers (C2, F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierBoundsARestsTurnAcrossHolders(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_919_962
        let tuning = SyncTuning(maxConcurrentTransfers: 6, reservedInteractiveSlots: 2)
        let (s, _) = try await Self.setUpHeldPublications(seed: seed, tuning: tuning)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = Self.turnTotalIDsPerTurn }
        let oBytes = EngineFixture.bytes(seed + 3, count: 24)
        let sizes = [(prefix: "zz-a", count: 6, bytes: 16), (prefix: "zz-b", count: 3, bytes: 20), (prefix: "zz-c", count: 3, bytes: 22)]
        let o = EngineHarness.onDemand("zz-o", oBytes)
        var before: [ManifestEntry] = []
        var onO: [ManifestEntry] = []
        var holders: [TransferID] = []
        for (index, size) in sizes.enumerated() {
            let bytes = EngineFixture.bytes(seed + 10 + UInt64(index), count: size.bytes)
            let names = (0..<size.count).map { String(format: "\(size.prefix)%02d", $0) }
            let entries = names.map { EngineHarness.onDemand($0, bytes) }
            before += entries
            onO += names.map { EngineHarness.onDemand($0, oBytes) }
            let holder = try #require(entries.first?.transferID)
            try #require(Set(entries.map(\.transferID)) == [holder], "setup: one shared content per holder")
            holders.append(holder)
        }
        try #require(Set(holders + [o.transferID]).count == 4, "setup: three shared contents and O's")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + before + [o] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(o.transferID, [.hold, .stage(oBytes)])
        for (index, size) in sizes.enumerated() {
            let bytes = EngineFixture.bytes(seed + 10 + UInt64(index), count: size.bytes)
            await s.harness.source.script(holders[index], [.hold, .stage(bytes)])
        }
        let oWaiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[o.transferID]?.state == .downloading }
        }
        var waiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for member in before {
            let id = member.identifier
            waiters.append(Task { await engine.awaitAsset(id, lane: .prefetch) })
        }
        let held = holders
        await engine.awaitCondition { e in zip(held, sizes).allSatisfy { e.state.jobs[$0.0]?.interests.count == $0.1.count } }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in held.allSatisfy { e.state.jobs[$0]?.state == .downloading } }
        }
        let ids = before.map(\.identifier)
        let left: @Sendable () async -> Int = {
            var sum = 0
            for holder in held {
                sum += await Self.membersLeft(engine, on: holder, members: ids)
            }
            return sum
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + onO + [o] + Self.laterFillers(seed + 6_000), tag: "v3-three-holders-\(seed)", s, visit: visit)
        var turns: [Int] = []
        if visit == .sweepFollowsFirst {
            var now = await left()
            try #require(now == 12, "setup: no member moved before the follow's turns: \(now)")
            while await engine.readForTests({ $0.followOwed }) {
                try #require(turns.count < 16, "the follow ends within 16 turns: \(turns)")
                await Self.runOneFollowTurn(engine)
                let after = await left()
                turns.append(now - after)
                now = after
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await s.harness.source.release(o.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let oResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: oWaiter) }
        var members: [Result<AssetLocation, AssetError>] = []
        for waiter in waiters {
            members.append(await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        #expect((try? oResult.get())?.byteSize == 24, "O's waiter is served: \(oResult)")
        #expect(members.allSatisfy { $0.map(\.byteSize) == .success(24) }, "every member gets O's bytes (visit-first): \(members)")
        if visit == .sweepFollowsFirst {
            #expect(turns.reduce(0, +) == 12, "every member left its job over the turns: \(turns)")
            #expect(turns.allSatisfy { $0 <= Self.turnTotalIDsPerTurn }, "no turn moves more than followIDsPerTurn ids across the holders' visits: \(turns)")
            #expect(turns == [4, 4, 4], "H1's visit, its rest with H2's visit, H3's visit: \(turns)")
        }
        await Self.finishHeld(s)
    }
}
