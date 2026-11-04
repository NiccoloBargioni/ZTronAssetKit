import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The joins a follow's visit waits behind a waiting exit verdict (`deferBehindVerdict`; Stage 3 close-out cycle 21,
/// ruling S3-R26 item 2, `integrate-c21.md` item A): O, the content of zz-o, ends its attempt in a 404 or a timeout while
/// v3's follow is owed, so its verdict waits; v4 maps every member zz-hNN, whose content H downloads (held), to O's
/// content, and each of H's visit's joins onto O waits behind O's verdict. Each runs in both orders (`LaneDropVisit`)
/// and expects the visit-first answers in both.
extension EngineFollowBarrierTests {
    /// The ids a follow turn moves in these tests (`EngineState.followIDsPerTurn`): H's visit spans turns.
    static let deferBucketIDsPerTurn = 4

    /// How O's attempt ends.
    enum DeferBucketEnding: String, Sendable, CaseIterable {
        /// A 404: the verdict fails O's job, and the members join a fresh job of O's content.
        case notFound
        /// A timeout: the verdict retries O's job, and the members join it.
        case timeout
    }

    /// Who wants the members.
    enum DeferBucketWanters: String, Sendable, CaseIterable {
        /// One prefetch group.
        case group
        /// A user waiter for each.
        case users
    }

    /// A-T1's groupings: how O's attempt ends, and who wants the members.
    enum DeferBucketShape: String, Sendable, CaseIterable {
        /// A 404; one prefetch group wants the members.
        case notFoundGroup
        /// A timeout; one prefetch group wants the members.
        case timeoutGroup
        /// A 404; each member has a user waiter.
        case notFoundUsers
        /// A timeout; each member has a user waiter.
        case timeoutUsers

        /// How O's attempt ends.
        var ending: DeferBucketEnding {
            self == .notFoundGroup || self == .notFoundUsers ? .notFound : .timeout
        }

        /// Who wants the members.
        var wanters: DeferBucketWanters {
            self == .notFoundGroup || self == .timeoutGroup ? .group : .users
        }
    }

    /// What `deferBucketSetUp` built.
    @available(macOS 15.0, iOS 18.0, *)
    struct DeferBucket {
        let s: FollowBarrier.Setup
        /// zz-o, on O's 20-byte content.
        let o: ManifestEntry
        /// The members, on H's 16-byte content (v2 and v3).
        let members: [ManifestEntry]
        /// The members on O's content (v4).
        let onO: [ManifestEntry]
        /// zz-o's user waiter.
        let oWaiter: Task<Result<AssetLocation, AssetError>, Never>
        /// The members' prefetch group (`.group`).
        let group: InterestToken?
        /// The members' user waiters (`.users`), in member order.
        let callers: [Task<Result<AssetLocation, AssetError>, Never>]
        /// The engine's events from before O's attempt ends.
        let probe: EventProbe
        let seed: UInt64

        /// The entries of v4, which maps every member to O's content.
        var v4: [ManifestEntry] {
            [self.s.q] + FollowBarrier.fillers(self.seed + 300) + self.onO + [self.o] + EngineFollowBarrierTests.laterFillers(self.seed + 9_000)
        }
    }

    /// O (zz-o, 20 bytes) downloads for zz-o's user waiter, held, scripted to `ending` then its bytes; H (the `count`
    /// members' 16 bytes) downloads, held, for `wanters`. v3 changes only the fillers, so its follow is owed (its turns
    /// held) sweep-first when O's attempt ends: O's verdict waits. Visited first, the follow ended at v3's apply and the
    /// verdict was given at its arrival.
    @available(macOS 15.0, iOS 18.0, *)
    func deferBucketSetUp(_ visit: LaneDropVisit, seed: UInt64, ending: DeferBucketEnding, wanters: DeferBucketWanters, members count: Int) async throws -> DeferBucket {
        let (s, _) = try await FollowBarrier.setUp(seed: seed)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = Self.deferBucketIDsPerTurn }
        let oBytes = EngineFixture.bytes(seed + 3, count: 20)
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let o = EngineHarness.onDemand("zz-o", oBytes)
        let names = (0..<count).map { String(format: "zz-h%02d", $0) }
        let members = names.map { EngineHarness.onDemand($0, hBytes) }
        let onO = names.map { EngineHarness.onDemand($0, oBytes) }
        let h = try #require(members.first).transferID
        try #require(onO.allSatisfy { $0.transferID == o.transferID } && h != o.transferID, "setup: v4 maps every member to O's content")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + members + [o] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let failure: TransferError = ending == .notFound ? .permanentMissing(httpStatus: 404) : .transient(.timedOut, retryAfter: nil)
        await s.harness.source.script(o.transferID, [.hold, .fail(failure), .stage(oBytes)])
        await s.harness.source.script(h, [.hold, .stage(hBytes)])
        let probe = EventProbe(stream: try await engine.subscribe().get())
        let oWaiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[o.transferID]?.state == .downloading }
        }
        var group: InterestToken?
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        switch wanters {
        case .group:
            group = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        case .users:
            for entry in members {
                let id = entry.identifier
                callers.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
            }
        }
        let interests = wanters == .group ? 1 : count
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                e.state.jobs[h]?.state == .downloading && e.state.jobs[h]?.assets.count == count && e.state.jobs[h]?.interests.count == interests
            }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + members + [o] + Self.laterFillers(seed + 6_000), tag: "v3-defer-bucket-\(seed)", s, visit: visit)
        await s.harness.source.release(o.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[o.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[o.transferID]?.state != .downloading }
        }
        return DeferBucket(s: s, o: o, members: members, onO: onO, oWaiter: oWaiter, group: group, callers: callers, probe: probe, seed: seed)
    }

    /// What one sweep-first held turn of `deferBucket` left.
    struct DeferBucketTurn: Sendable, CustomStringConvertible {
        /// Which held turn ran.
        let kind: HeldTurn
        /// Whether the follow is still owed.
        let owed: Bool
        /// The waiting events: `O` for O's verdict, `join` for a join, `other` for anything else.
        let queue: [String]
        /// The joins registered for the follow (`joinsAfterFollow`).
        let registered: Int
        /// The invariants.
        let violations: [String]

        var description: String {
            "\(self.kind.rawValue) owed=\(self.owed) queue=\(self.queue.prefix(4))(\(self.queue.count)) registered=\(self.registered) violations=\(self.violations.prefix(2))"
        }
    }

    /// Reads what `DeferBucketTurn` holds.
    static func deferBucketTurn(_ e: isolated SyncEngine, _ kind: HeldTurn, o: TransferID) -> DeferBucketTurn {
        let queue = e.state.eventsAfterFollow.map { event -> String in
            switch event {
            case .attemptFailed(let transfer, _, _) where transfer == o:
                return "O"
            case .join:
                return "join"
            default:
                return "other"
            }
        }
        return DeferBucketTurn(
            kind: kind,
            owed: e.followOwed,
            queue: queue,
            registered: e.state.joinsAfterFollow.values.reduce(0) { $0 + $1.count },
            violations: e.invariantViolations()
        )
    }

    /// The members' and zz-o's answers once the drain is over (`deferBucket`): each member's bytes served, `-1` for an
    /// error, in member order; zz-o's waiter's answer; and the ids the events report failed.
    struct DeferBucketOutcome {
        let served: [Int64]
        let o: Result<AssetLocation, AssetError>
        let failed: [AssetID]
    }

    /// Ends `deferBucket`'s scenario: lets the follow and its drain end, then reads every answer. A member of the group
    /// is served once the events report it available, with its stored bytes; zz-o's failure is reported before any member
    /// is (the drain gives O's verdict before the joins behind it; visited first, before v4).
    @available(macOS 15.0, iOS 18.0, *)
    func deferBucketFinish(_ b: DeferBucket) async throws -> DeferBucketOutcome {
        let engine = b.s.engine
        await engine.readForTests { e in
            e.releaseFollowFollowUps()
            e.releaseDrainFollowUps()
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        var served: [Int64] = []
        if b.group != nil {
            let probe = b.probe
            for entry in b.members {
                let id = entry.identifier
                _ = await EngineRegressionCycle6Tests.driving([b.s.time], fence: engine) {
                    await probe.next { event in
                        if case .assetAvailable(let available, _) = event {
                            return available == id
                        }
                        return false
                    }
                }
                let stored = await b.s.harness.store.location(for: id, extensions: [], recordingAccess: false)
                served.append(stored?.byteSize ?? -1)
            }
        } else {
            for caller in b.callers {
                let result = await EngineRegressionCycle6Tests.driving([b.s.time], fence: engine) { await EngineHarness.value(of: caller) }
                served.append((try? result.get())?.byteSize ?? -1)
            }
        }
        let oResult = await EngineRegressionCycle6Tests.driving([b.s.time], fence: engine) { await EngineHarness.value(of: b.oWaiter) }
        let failed = await b.probe.received.compactMap { event -> AssetID? in
            if case .assetFailed(let id, _, _) = event {
                return id
            }
            return nil
        }
        await b.probe.stop()
        if let group = b.group {
            await engine.releaseGroup(group)
        }
        await Self.finishHeld(b.s)
        return DeferBucketOutcome(served: served, o: oResult, failed: failed)
    }

    // MARK: A-T1: the joins behind a waiting verdict wait outside the queue

    /// A follow's visit that moves the members onto O's content, whose verdict waits, leaves the queue holding O's verdict
    /// alone after every held follow turn: each join waits behind the verdict in O's bucket (`joinsBehindVerdicts`),
    /// which grows by at most a turn's ids, in arrival order, and the drain places the bucket behind the verdict. Visited
    /// first, the verdict was given at its arrival and v4's visit joined the members at once: every member is served
    /// O's 20 bytes, and a 404 reports zz-o alone failed.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: the joins a follow defers behind a waiting exit verdict wait outside the queue, a turn's ids at a time (C2, F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, DeferBucketShape.allCases)
    func barrierWaitsTheJoinsBehindAVerdictOutsideTheQueue(_ visit: LaneDropVisit, _ shape: DeferBucketShape) async throws {
        let count = 10
        let b = try await self.deferBucketSetUp(visit, seed: 2_022_701, ending: shape.ending, wanters: shape.wanters, members: count)
        let engine = b.s.engine
        let o = b.o.transferID
        try await Self.applyHeld(b.v4, tag: "v4-defer-bucket-\(b.seed)", b.s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.holdDrainFollowUps() }
            var turns = [await engine.readForTests { e in Self.deferBucketTurn(e, .follow, o: o) }]
            while turns.last?.owed == true {
                try #require(turns.count < 40, "the follow ends within 40 turns: \(turns)")
                let kind = await Self.runOneHeldTurn(engine)
                turns.append(await engine.readForTests { e in Self.deferBucketTurn(e, kind, o: o) })
            }
            try #require(turns.contains { $0.owed && $0.registered > 0 }, "setup: H's visit's joins wait behind O's verdict during the follow: \(turns)")
            // v4's apply's own turn, then each held follow turn while the follow is owed.
            var previous = 0
            for turn in turns where turn.owed {
                #expect(turn.queue == ["O"], "after every held follow turn the queue holds O's verdict alone: \(turns)")
                #expect(turn.registered >= previous && turn.registered - previous <= Self.deferBucketIDsPerTurn, "a follow turn defers at most a turn's ids: \(turns)")
                previous = turn.registered
            }
            #expect(turns.allSatisfy { $0.violations.isEmpty }, "the invariants hold after every held turn: \(turns)")
        }
        let outcome = try await self.deferBucketFinish(b)
        #expect(outcome.served == Array(repeating: 20, count: count), "every member is served O's 20 bytes (visit-first): \(outcome.served)")
        switch shape.ending {
        case .notFound:
            #expect((try? outcome.o.get()) == nil, "zz-o's 404 answers its waiter (visit-first): \(outcome.o)")
            #expect(outcome.failed == [b.o.identifier], "the 404 reports zz-o alone failed (visit-first): \(outcome.failed)")
        case .timeout:
            #expect((try? outcome.o.get())?.byteSize == 20, "zz-o's retry serves its waiter (visit-first): \(outcome.o)")
            #expect(outcome.failed.isEmpty, "nothing is reported failed (visit-first): \(outcome.failed)")
        }
    }
}
