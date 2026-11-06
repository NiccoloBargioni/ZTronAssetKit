import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// What an owing commit announces (Stage 3 close-out cycle 21, ruling S3-R26 item 1; site 1's commit turn): a commit that
/// owes its re-routes answers each interest only the ids it bound and retires its job untrimmed (`resolveAll`'s
/// `boundOnly`), and announces the ids it bound by the lane of the interests it answered, as a commit that re-routes at
/// once announces them from its trimmed job. Each runs in both orders (`LaneDropVisit`) and expects the same answers in
/// both.
extension EngineFollowBarrierTests {
    /// What `groupKeptCommit` saw.
    struct GroupKeptCommit: CustomStringConvertible {
        /// The ids O's commit announced (`assetAvailable`), in order.
        var announced: [AssetID] = []
        /// The distinct ids the waiting batches owed after O's commit's turn.
        var owed = 0
        /// The moved ids' waiters' bytes, in id order (-1 for a failure).
        var served: [Int64] = []
        /// Whether the group waited for no member at the end.
        var groupDone = false
        /// The invariant violations read after O's commit's turn.
        var violations: [String] = []

        var description: String {
            "announced \(self.announced), owed \(self.owed), served \(self.served), group done \(self.groupDone), violations \(self.violations.prefix(3))"
        }
    }

    /// zz-o, on O's content (16 bytes), is wanted only by a prefetch group on `keptLane`, and zz-a1…zz-a<moved>, on O's
    /// content too, each by a user waiter; v4 maps the zz-a ids to W's content (20 bytes). O downloads, then
    /// publishes, held at its first store unit; v4 is applied (visited first, its follow ends; swept first, it stays
    /// owed), the drain's turns are held, and the publication commits: the store binds zz-o, and the commit owes the
    /// moved ids' re-routes at `idsPerTurn = 4` (1 + moved pass `inboundIDsNow`, 2) or makes them at once at 512. The
    /// subscriber's events are read after the commit's turn; then every held turn runs and W's download completes.
    @available(macOS 15.0, iOS 18.0, *)
    func groupKeptCommit(_ visit: LaneDropVisit, seed: UInt64, moved count: Int, idsPerTurn: Int, keptLane: AssetPriority) async throws -> GroupKeptCommit {
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = idsPerTurn }
        let oBytes = EngineFixture.bytes(seed + 3, count: 16)
        let wBytes = EngineFixture.bytes(seed + 9, count: 20)
        let o = EngineHarness.onDemand("zz-o", oBytes)
        let moved = (1...count).map { EngineHarness.onDemand("zz-a\($0)", oBytes) }
        let movedIDs = Set(moved.map(\.identifier))
        let x = o.transferID
        let w = EngineHarness.onDemand("zz-w", wBytes).transferID
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [o] + moved + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(x, [.hold, .stage(oBytes)])
        await s.harness.source.script(w, [.hold, .stage(wBytes)])
        let subscription = try await engine.subscribe().get()
        let waiters = moved.map { entry in
            let id = entry.identifier
            return Task { await engine.awaitAsset(id, lane: .userInitiated) }
        }
        let group = try await engine.registerGroup([o.identifier], lane: keptLane).get()
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[x]?.state == .downloading && $0.state.jobs[x]?.interests.count == count + 1 }
        }
        let (units, releaser) = try await Self.holdPublications(of: [x], s, bulk: bulk)
        let v4 = [s.q] + FollowBarrier.fillers(seed + 200) + [o] + moved.map { EngineHarness.onDemand($0.identifier.rawValue, wBytes) } + Self.laterFillers(seed + 6_000)
        try await Self.applyHeld(v4, tag: "v4-group-kept-\(seed)", s, visit: visit)
        await engine.readForTests { $0.holdDrainFollowUps() }
        await bulk.release(units[0])
        await engine.awaitCondition { $0.state.jobs[x] == nil }
        var run = GroupKeptCommit()
        let watched = movedIDs.union([o.identifier])
        run.announced = await engine.readForTests { e -> [AssetID] in
            guard let key = e.state.subscribers.keys.max() else {
                return []
            }
            var ids: [AssetID] = []
            while let event = e.state.subscribers[key]?.take() {
                if case .assetAvailable(let id, _) = event, watched.contains(id) {
                    ids.append(id)
                }
            }
            return ids
        }
        let shape = await engine.readForTests { e in Self.rerouteShape(e, w: w, members: movedIDs, tokens: 1) }
        run.owed = shape.owed
        run.violations = shape.violations
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        await bulk.releaseAll()
        while await engine.readForTests({ e in e.followOwed || !e.state.eventsAfterFollow.isEmpty }) {
            _ = await Self.runOneHeldTurn(engine)
        }
        await engine.readForTests { e in
            e.releaseDrainFollowUps()
            e.releaseFollowFollowUps()
        }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[w]?.state == .downloading }
        }
        await s.harness.source.release(w, with: .progress(received: 0, expected: nil))
        for waiter in waiters {
            let result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) }
            run.served.append((try? result.get())?.byteSize ?? -1)
        }
        run.groupDone = await engine.readForTests { $0.state.groups[group]?.pending.isEmpty ?? true }
        withExtendedLifetime(subscription) {}
        await Self.finishHeld(s)
        return run
    }

    // MARK: T-ANNOUNCE-OWED: an owing commit announces by the lane of the interests it answers

    /// O's commit answers zz-o to the group alone, its user waiters all in moved ids: a commit that re-routes at once
    /// trims the waiters' interests first, so its job's lane is the group's, and it announces zz-o only above bulk
    /// (`publishTerminal`); one that owes the re-routes leaves its job untrimmed and announces by the lane of the
    /// interests it answered, the same. The waiters get W's bytes and the group ends in both.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a commit that owes its re-routes announces the ids it bound by the lane of the interests it answers, as one that re-routes at once (F-28, C2)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, [AssetPriority.bulk, .prefetch])
    func owedCommitAnnouncesByTheLaneOfTheInterestsItAnswers(_ visit: LaneDropVisit, keptLane: AssetPriority) async throws {
        let seed: UInt64 = keptLane == .bulk ? 2_027_301 : 2_027_311
        let owed = try await self.groupKeptCommit(visit, seed: seed, moved: 3, idsPerTurn: Self.owedIDsPerTurn, keptLane: keptLane)
        #expect(owed.owed == 3, "setup: at 4 the commit owes the three re-routes: \(owed)")
        let atOnce = try await self.groupKeptCommit(visit, seed: seed, moved: 3, idsPerTurn: 512, keptLane: keptLane)
        #expect(atOnce.owed == 0, "setup: at 512 the commit re-routes at once: \(atOnce)")
        let expected = keptLane > .bulk ? [AssetID("zz-o")] : []
        #expect(owed.announced == expected && atOnce.announced == expected, "zz-o, answered to the group alone, is announced only above bulk, by both commits: \(owed) | \(atOnce)")
        #expect(owed.served == [20, 20, 20] && atOnce.served == owed.served, "the moved ids' waiters get W's bytes: \(owed) | \(atOnce)")
        #expect(owed.groupDone && atOnce.groupDone, "the group waits for no member: \(owed) | \(atOnce)")
        #expect(owed.violations.isEmpty && atOnce.violations.isEmpty, "\(owed.violations.prefix(3)) \(atOnce.violations.prefix(3))")
    }
}
