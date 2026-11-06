import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch probe (s3f close-out verification, cycle 19, requirements lens). Never committed.
///
/// PROBE-C19R-TWO-HOLDER-TURN: the bound of S3-R22 item 1 is per follow turn ("at most `followIDsPerTurn` ids they
/// move", `continueFollow`), but `barrierMovesASharedContentsIDsOverBoundedTurns` counts only the members leaving one
/// holder per turn. Shape: two holders, H1 (zz-a00…05, 16 bytes) and H2 (zz-b00…05, 20 bytes), a prefetch waiter per
/// member, both downloading (held); O (zz-o, 24 bytes) has a user waiter and downloads (held). The bound is set to 4
/// (`EngineState.followIDsPerTurn`). v3 maps all twelve members to O's content. Sweep-first, O's 404 arrives before the
/// follow's first follow-up turn: its attempt's end owes two moves (H1 -> O, H2 -> O, six ids each) and makes
/// `inboundIDsNow` (2) of them; the follow's turns make the rest, each turn counting the members that left either
/// holder. Visited first, v3's visit moved every member onto O's job at the apply and the 404 answered them all.
@Suite("VerifyC19ReqsTurnTotal", .serialized)
struct VerifyC19ReqsTurnTotal {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier
    typealias T = EngineFollowBarrierTests

    static let bound = 4

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C19R-TWO-HOLDER-TURN", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func twoHolderTurn(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_919_952
        let tuning = SyncTuning(maxConcurrentTransfers: 5, reservedInteractiveSlots: 2)
        let (s, _) = try await T.setUpHeldPublications(seed: seed, tuning: tuning)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = Self.bound }
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
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + onH1 + onH2 + [o] + T.laterFillers(seed + 3_000), etag: "v2")
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
            await T.membersLeft(engine, on: h1, members: ids) + T.membersLeft(engine, on: h2, members: ids)
        }
        try await T.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + onO + [o] + T.laterFillers(seed + 6_000), tag: "v3-two-holder-\(seed)", s, visit: visit)
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
                await T.runOneFollowTurn(engine)
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
        let starts = await s.harness.source.starts.filter { $0.id == h1 || $0.id == h2 || $0.id == o.transferID }.count
        print("PROBE-C19R-TWO-HOLDER-TURN \(visit): moves owed at O's end \(moveSizes); members left per turn \(turns); O \(oResult); members not 404 \(members.filter { $0 != .failure(.notFound) }.count); starts \(starts)")
        #expect(oResult == .failure(.notFound), "O's waiter gets its 404: \(oResult)")
        #expect(members.allSatisfy { $0 == .failure(.notFound) }, "every member gets O's 404 (visit-first): \(members)")
        if visit == .sweepFollowsFirst {
            #expect(moveSizes.sorted() == [6, 6], "setup: O's attempt's end owes one move per holder: \(moveSizes)")
            #expect(turns.reduce(0, +) == 12, "every member left its job over the turns: \(turns)")
            #expect(turns.allSatisfy { $0 <= Self.bound }, "no follow turn moves more than followIDsPerTurn = \(Self.bound) ids across the holders: \(turns)")
        }
        await T.finishHeld(s)
    }

    /// PROBE-C19R-THREE-HOLDER-VISITS: three holders' visits in the follow's turns, H1 (six members, 16 bytes), H2 and
    /// H3 (three each, 20 and 22 bytes), a prefetch waiter per member, all downloading (held); O (zz-o, 24 bytes) has a
    /// user waiter and downloads (held). The bound is 4. v3 maps all twelve members to O's content. Sweep-first, the
    /// follow's turns visit the three holders; each turn counts the members that left any holder. O's bytes arrive once
    /// the follow ended. Visited first, v3's visit moved every member onto O's job at the apply.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C19R-THREE-HOLDER-VISITS", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func threeHolderVisits(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_919_962
        let tuning = SyncTuning(maxConcurrentTransfers: 6, reservedInteractiveSlots: 2)
        let (s, _) = try await T.setUpHeldPublications(seed: seed, tuning: tuning)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = Self.bound }
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
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + before + [o] + T.laterFillers(seed + 3_000), etag: "v2")
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
                sum += await T.membersLeft(engine, on: holder, members: ids)
            }
            return sum
        }
        try await T.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + onO + [o] + T.laterFillers(seed + 6_000), tag: "v3-three-holders-\(seed)", s, visit: visit)
        var turns: [Int] = []
        if visit == .sweepFollowsFirst {
            var now = await left()
            try #require(now == 12, "setup: no member moved before the follow's turns: \(now)")
            while await engine.readForTests({ $0.followOwed }) {
                try #require(turns.count < 16, "the follow ends within 16 turns: \(turns)")
                await T.runOneFollowTurn(engine)
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
        let holderStarts = await s.harness.source.starts.filter { held.contains($0.id) }.count
        print("PROBE-C19R-THREE-HOLDER-VISITS \(visit): members left per turn \(turns); O \(oResult.map(\.byteSize)); members not served 24 bytes \(members.filter { $0.map(\.byteSize) != .success(24) }.count); holder starts \(holderStarts)")
        #expect((try? oResult.get())?.byteSize == 24, "O's waiter is served: \(oResult)")
        #expect(members.allSatisfy { $0.map(\.byteSize) == .success(24) }, "every member gets O's bytes (visit-first): \(members)")
        if visit == .sweepFollowsFirst {
            #expect(turns.reduce(0, +) == 12, "every member left its job over the turns: \(turns)")
            #expect(turns.allSatisfy { $0 <= Self.bound }, "no follow turn moves more than followIDsPerTurn = \(Self.bound) ids across the holders' visits: \(turns)")
        }
        await T.finishHeld(s)
    }
}
