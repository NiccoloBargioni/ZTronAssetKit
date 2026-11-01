import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// One holder whose ids an apply maps onto two running publications, two ids onto each, while a follow is owed (Stage 3
/// close-out cycle 19; the cycle-18 requirements verifier's finding on the owed moves' walk, `foundInbound`: every RR-14
/// test had holders of one id moving onto one checksummed target). The apply's walk under the outgoing copy
/// (`bringInboundOntoPublications`) records one move per target, each carrying both of the holder's ids for it, and no id
/// twice. Each case runs in both orders (`LaneDropVisit`) with the visit-first answers expected in both.
extension EngineFollowBarrierTests {
    /// What `twoTargets` reads: the answers of the two publications' waiters and of each id's, the moves the walk
    /// recorded off H (sweep-first), and the starts of the contents v4 maps the ids to.
    struct TwoTargetsOutcome {
        /// The waiters of P1 (zz-p) and P2 (zz-q).
        let publishers: [Result<AssetLocation, AssetError>]
        /// The waiters of zz-x1, zz-x2 (moved onto P1's content) and zz-y1, zz-y2 (onto P2's).
        let ids: [Result<AssetLocation, AssetError>]
        /// The moves off H the walk at v4 recorded, by target, with their ids (sweep-first; empty visited first).
        let moves: [TransferID: Set<AssetID>]
        /// The starts of Z1's and Z2's transfers.
        let zStarts: Int
    }

    /// P1 (zz-p, 16 bytes) and P2 (zz-q, 24 bytes), a user waiter each, publish bytes that fail their checksum, both held
    /// at their first store unit; H (100 kB) holds zz-x1, zz-x2, zz-y1 and zz-y2, a user waiter each, and downloads. v3
    /// maps the x ids to P1's content and the y ids to P2's; v4 maps them on, the x ids to Z1 (48 bytes) and the y ids to
    /// Z2 (56 bytes), both while the publications are held. Visited first, v3's visit superseded H and joined each id to
    /// its publication, and v4's visit passed both publishing jobs, so each publication's integrity failure answered its
    /// ids; Z1 and Z2 never started. Behind the barrier, v4's walk under v3's copy finds H giving two ids to each
    /// publication. Five transfer slots, two reserved for user work, so the three jobs download at once.
    @available(macOS 15.0, iOS 18.0, *)
    func twoTargets(_ visit: LaneDropVisit, seed: UInt64) async throws -> TwoTargetsOutcome {
        let tuning = SyncTuning(maxConcurrentTransfers: 5, reservedInteractiveSlots: 2)
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed, tuning: tuning)
        let engine = s.engine
        let p1Bytes = EngineFixture.bytes(seed + 3, count: 16)
        let p2Bytes = EngineFixture.bytes(seed + 4, count: 24)
        let wrong1 = EngineFixture.bytes(seed + 5, count: 16)
        let wrong2 = EngineFixture.bytes(seed + 6, count: 24)
        let hBytes = EngineFixture.bytes(seed + 7, count: 100_000)
        let z1Bytes = EngineFixture.bytes(seed + 8, count: 48)
        let z2Bytes = EngineFixture.bytes(seed + 9, count: 56)
        let p1 = EngineHarness.onDemand("zz-p", p1Bytes)
        let p2 = EngineHarness.onDemand("zz-q", p2Bytes)
        let xNames = ["zz-x1", "zz-x2"]
        let yNames = ["zz-y1", "zz-y2"]
        let onH = (xNames + yNames).map { EngineHarness.onDemand($0, hBytes) }
        let onP = xNames.map { EngineHarness.onDemand($0, p1Bytes) } + yNames.map { EngineHarness.onDemand($0, p2Bytes) }
        let onZ = xNames.map { EngineHarness.onDemand($0, z1Bytes) } + yNames.map { EngineHarness.onDemand($0, z2Bytes) }
        let holder = try #require(onH.first?.transferID)
        let z1 = try #require(onZ.first?.transferID)
        let z2 = try #require(onZ.last?.transferID)
        try #require(Set(onH.map(\.transferID)).count == 1 && Set([p1.transferID, p2.transferID, holder, z1, z2]).count == 5, "setup: five contents, the four ids on H's")
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [p1, p2] + onH + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(p1.transferID, [.hold, .stage(wrong1)])
        await s.harness.source.script(p2.transferID, [.hold, .stage(wrong2)])
        await s.harness.source.script(holder, [.hold, .stage(hBytes)])
        await s.harness.source.script(z1, [.stage(z1Bytes)])
        await s.harness.source.script(z2, [.stage(z2Bytes)])
        var publishers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for publisher in [p1, p2] {
            let id = publisher.identifier
            publishers.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
            let transfer = publisher.transferID
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[transfer]?.state == .downloading }
            }
        }
        var waiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for entry in onH {
            let id = entry.identifier
            waiters.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
        }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[holder]?.interests.count == 4 && $0.state.jobs[holder]?.state == .downloading }
        }
        // Both publications begin, held at their first store unit, before either apply.
        await engine.awaitCondition { !$0.state.storeWorkInFlight }
        await bulk.setHolding(true)
        var units: [Int] = []
        for publisher in [p1, p2] {
            await s.harness.source.release(publisher.transferID, with: .progress(received: 0, expected: nil))
            let transfer = publisher.transferID
            await engine.awaitCondition { $0.state.jobs[transfer]?.state == .verifying }
            try await bulk.requireHeldUnits(atLeast: units.count + 1)
            units.append(try #require(await bulk.heldUnits.first { !units.contains($0) }))
        }
        let held = units
        let releaser = Task {
            while !Task.isCancelled {
                await bulk.waitForHeldUnits(atLeast: held.count + 1)
                for other in await bulk.heldUnits where !held.contains(other) {
                    await bulk.release(other)
                }
            }
        }
        try await Self.applyHeld([s.q] + fillers + [p1, p2] + onP + later, tag: "v3-two-\(seed)", s, visit: visit)
        try await Self.applyHeld([s.q] + fillers + [p1, p2] + onZ + later, tag: "v4-two-\(seed)", s, visit: visit)
        var moves: [TransferID: Set<AssetID>] = [:]
        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { e in
                e.state.inboundMoves[e.state.inboundNext...].filter { $0.holder == holder }.map { (target: $0.target, ids: $0.ids) }
            }
            for move in owed {
                try #require(moves[move.target] == nil, "setup: one move per target: \(owed)")
                moves[move.target] = move.ids
            }
        }
        // Both publications resume and fail their integrity checks.
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        let ends = [p1.transferID, p2.transferID]
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { e in ends.allSatisfy { e.state.verdictsAfterFollow[$0] != nil || e.state.jobs[$0] == nil } }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        } else {
            await engine.awaitCondition { e in ends.allSatisfy { e.state.jobs[$0] == nil } }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        var publisherResults: [Result<AssetLocation, AssetError>] = []
        for waiter in publishers {
            publisherResults.append(await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        var results: [Result<AssetLocation, AssetError>] = []
        for waiter in waiters {
            results.append(await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        let zStarts = await s.harness.source.starts.filter { $0.id == z1 || $0.id == z2 }.count
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return TwoTargetsOutcome(publishers: publisherResults, ids: results, moves: moves, zStarts: zStarts)
    }

    /// One holder giving two ids to each of two publications gets each id its publication's outcome (`twoTargets`): the
    /// walk records one move per publication, each with both of its ids (sweep-first), and visited first v3's visit had
    /// joined each id to its publication.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: ids one holder gives to two running publications get each its publication's outcome, one owed move per publication (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierMovesOneHoldersIDsOntoTwoPublications(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.twoTargets(visit, seed: 1_919_402)
        #expect(outcome.publishers.allSatisfy { $0 == .failure(.integrityFailure) }, "each publication's waiter gets its integrity failure: \(outcome.publishers)")
        let wrong = outcome.ids.enumerated().filter { $0.element != .failure(.integrityFailure) }
        #expect(wrong.isEmpty, "each id gets its publication's integrity failure (visit-first); \(wrong.count) do not: \(wrong.map { "\($0.offset): \($0.element)" }); moves \(outcome.moves)")
        #expect(outcome.zStarts == 0, "no id reaches Z1 or Z2: \(outcome.zStarts)")
        guard visit == .sweepFollowsFirst else {
            return
        }
        let sizes = outcome.moves.values.map(\.count).sorted()
        #expect(outcome.moves.count == 2 && sizes == [2, 2], "the walk records one move per publication, each with both of its ids: \(outcome.moves)")
    }
}
