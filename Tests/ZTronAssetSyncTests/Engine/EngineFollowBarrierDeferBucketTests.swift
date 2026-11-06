import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The joins a follow's visit waits behind a waiting exit verdict (`deferBehindVerdict`; Stage 3 close-out cycle 21,
/// ruling S3-R26 item 2, `integrate-c21.md` item A): O, the content of zz-o, ends its attempt in a 404 or a timeout while
/// v3's follow is owed, so its verdict waits; v4 maps every member zz-hNN, whose content H downloads (held), to O's
/// content, and each of H's visit's joins onto O waits behind O's verdict, in O's bucket (`joinsBehindVerdicts`). Each
/// runs in both orders (`LaneDropVisit`) and expects the visit-first answers in both. The buckets arise swept first
/// only: visited first, v3's follow ended at its apply (`applyHeld`), before O's verdict arrived, which was then given at
/// its arrival, and each test pins that no bucket exists there (`deferBucketApplyV4`).
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
        /// Entries listed after zz-o in every manifest, unchanged.
        let extra: [ManifestEntry]
        /// zz-o's user waiter (`nil` when a one-member prefetch group wants zz-o instead, `oGroup`).
        let oWaiter: Task<Result<AssetLocation, AssetError>, Never>?
        /// The one-member prefetch group that wants zz-o instead of a user waiter.
        let oGroup: InterestToken?
        /// The members' prefetch group (`.group`).
        let group: InterestToken?
        /// The members' user waiters (`.users`), in member order.
        let callers: [Task<Result<AssetLocation, AssetError>, Never>]
        /// The engine's events from before O's attempt ends.
        let probe: EventProbe
        let seed: UInt64

        /// The entries of v4, which maps every member to O's content, and changes the fillers too unless `fillersStay`
        /// (then H's visit's rest alone keeps the follow owed, and its last turn ends the follow).
        func v4(fillersStay: Bool) -> [ManifestEntry] {
            let fillers = fillersStay ? (200, 6_000) : (300, 9_000)
            return [self.s.q] + FollowBarrier.fillers(self.seed + UInt64(fillers.0)) + self.onO + [self.o] + self.extra + EngineFollowBarrierTests.laterFillers(self.seed + UInt64(fillers.1))
        }
    }

    /// O (zz-o, 20 bytes) downloads for zz-o's user waiter (or for a one-member prefetch group, `oByGroup`), held,
    /// scripted to `ending` then its bytes; H (the `count` members' 16 bytes) downloads, held, for `wanters`. v3 changes
    /// only the fillers, so its follow is owed (its turns held) swept first when O's attempt ends: O's verdict waits.
    /// Visited first, the follow ended at v3's apply and the verdict was given at its arrival. `extra` is listed after
    /// zz-o in every manifest, unchanged. With `passV3Members`, one more of v3's follow turns runs swept first before O's
    /// attempt ends, so v3's pass is past the members when v4 is applied and v4's pass alone finds H. With `holdRetry`,
    /// O's next attempt holds too, until the test releases it: with `.timeout`, visited first, that attempt starts at
    /// v4's barrier end when v4's joins leave O user-initiated (T20, `relane`'s `.failed` arm), and otherwise at its
    /// backoff alarm, when the test drives the clock.
    @available(macOS 15.0, iOS 18.0, *)
    func deferBucketSetUp(_ visit: LaneDropVisit, seed: UInt64, ending: DeferBucketEnding, wanters: DeferBucketWanters, members count: Int, oByGroup: Bool = false, extra: [ManifestEntry] = [], passV3Members: Bool = false, holdRetry: Bool = false) async throws -> DeferBucket {
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
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + members + [o] + extra + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let failure: TransferError = ending == .notFound ? .permanentMissing(httpStatus: 404) : .transient(.timedOut, retryAfter: nil)
        await s.harness.source.script(o.transferID, holdRetry ? [.hold, .fail(failure), .hold, .stage(oBytes)] : [.hold, .fail(failure), .stage(oBytes)])
        await s.harness.source.script(h, [.hold, .stage(hBytes)])
        let probe = EventProbe(stream: try await engine.subscribe().get())
        var oWaiter: Task<Result<AssetLocation, AssetError>, Never>?
        var oGroup: InterestToken?
        if oByGroup {
            oGroup = try await engine.registerGroup([o.identifier], lane: .prefetch).get()
        } else {
            oWaiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        }
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
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + members + [o] + extra + Self.laterFillers(seed + 6_000), tag: "v3-defer-bucket-\(seed)", s, visit: visit)
        if passV3Members, visit == .sweepFollowsFirst {
            await Self.runOneFollowTurn(engine)
            let owed = await engine.readForTests { $0.followOwed }
            try #require(owed, "setup: v3's follow is still owed past the members")
        }
        await s.harness.source.release(o.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[o.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[o.transferID]?.state != .downloading }
        }
        return DeferBucket(s: s, o: o, members: members, onO: onO, extra: extra, oWaiter: oWaiter, oGroup: oGroup, group: group, callers: callers, probe: probe, seed: seed)
    }

    /// Applies v4 (`DeferBucket.v4(fillersStay:)`); visited first, the follow ends at the apply, and no join waits behind a
    /// verdict: O's was given at its arrival (the pin that the buckets' state arises swept first only, ruling S3-R26 item
    /// 12's answer 1).
    @available(macOS 15.0, iOS 18.0, *)
    func deferBucketApplyV4(_ b: DeferBucket, _ visit: LaneDropVisit, fillersStay: Bool = false) async throws {
        try await Self.applyHeld(b.v4(fillersStay: fillersStay), tag: "v4-defer-bucket-\(b.seed)", b.s, visit: visit)
        if visit == .followVisitedFirst {
            let none = await b.s.engine.readForTests { e in e.state.joinsBehindVerdicts.isEmpty && e.state.verdictsAfterFollow.isEmpty }
            try #require(none, "visited first, no verdict waits and no join waits behind one")
        }
    }

    /// What one sweep-first held turn of `deferBucket` left.
    struct DeferBucketTurn: Sendable, CustomStringConvertible {
        /// Which held turn ran.
        let kind: HeldTurn
        /// Whether the follow is still owed.
        let owed: Bool
        /// The waiting events: `O` for O's verdict, `join <id>` for a join, `other` for anything else.
        let queue: [String]
        /// The joins registered for the follow (`joinsAfterFollow`).
        let registered: Int
        /// The assets of the joins waiting behind O's verdict, oldest first (`joinsBehindVerdicts`).
        let behind: [AssetID]
        /// The buckets.
        let buckets: Int
        /// The invariants.
        let violations: [String]
        /// What the follow still owes: its passes, its visits, a visit's rest, its owed moves.
        let follow: String

        var description: String {
            "\(self.kind.rawValue) owed=\(self.owed) [\(self.follow)] queue=\(self.queue.prefix(4))(\(self.queue.count)) registered=\(self.registered) behind=\(self.behind.count) buckets=\(self.buckets) violations=\(self.violations.prefix(2))"
        }
    }

    /// Reads what `DeferBucketTurn` holds.
    static func deferBucketTurn(_ e: isolated SyncEngine, _ kind: HeldTurn, o: TransferID) -> DeferBucketTurn {
        let queue = e.state.eventsAfterFollow.map { event -> String in
            switch event {
            case .attemptFailed(let transfer, _, _) where transfer == o:
                return "O"
            case .join(let join):
                return "join \(join.asset)"
            default:
                return "other"
            }
        }
        return DeferBucketTurn(
            kind: kind,
            owed: e.followOwed,
            queue: queue,
            registered: e.state.joinsAfterFollow.values.reduce(0) { $0 + $1.count },
            behind: e.state.joinsBehindVerdicts.first { $0.key.transfer == o }?.value.map(\.join.asset) ?? [],
            buckets: e.state.joinsBehindVerdicts.count,
            violations: e.invariantViolations(),
            follow: "passes \(e.state.followScans.count) visits \(e.state.followOrder.count - e.state.followNext) rest \(e.state.followMoving != nil) moves \(e.inboundOwed)"
        )
    }

    /// Swept first: holds the drain's turns and runs the follow's held turns one at a time, reading each, until the
    /// follow is no longer owed (its last turn ran, with the drain's first batch) or `stop` holds after a turn. Returns
    /// the readings, v4's apply's own turn first.
    @available(macOS 15.0, iOS 18.0, *)
    static func deferBucketTurns(_ b: DeferBucket, until stop: @escaping @Sendable (DeferBucketTurn) -> Bool = { _ in false }) async throws -> [DeferBucketTurn] {
        let engine = b.s.engine
        let o = b.o.transferID
        await engine.readForTests { $0.holdDrainFollowUps() }
        var turns = [await engine.readForTests { e in Self.deferBucketTurn(e, .follow, o: o) }]
        while let last = turns.last, last.owed, !stop(last) {
            try #require(turns.count < 40, "the follow ends within 40 turns: \(turns)")
            let kind = await Self.runOneHeldTurn(engine)
            turns.append(await engine.readForTests { e in Self.deferBucketTurn(e, kind, o: o) })
        }
        return turns
    }

    /// The members' and zz-o's answers once the drain is over (`deferBucket`): each member's bytes served, `-1` for an
    /// error, in member order; zz-o's waiter's answer; and the ids the events report failed.
    struct DeferBucketOutcome {
        let served: [Int64]
        let o: Result<AssetLocation, AssetError>?
        let failed: [AssetID]
        /// The answers of `deferBucketFinish`'s `extra` waiters, in order.
        let extra: [Result<AssetLocation, AssetError>]
    }

    /// Ends `deferBucket`'s scenario: lets the follow and its drain end, then reads every answer. A member of the group
    /// is served once the events report it available, with its stored bytes; zz-o's failure is reported before any
    /// member is (the drain gives O's verdict before the joins behind it; visited first, before v4). The `extra`
    /// waiters' answers are read before the engine shuts down, so none of them is answered `.shutDown`.
    @available(macOS 15.0, iOS 18.0, *)
    func deferBucketFinish(_ b: DeferBucket, extra: [Task<Result<AssetLocation, AssetError>, Never>] = []) async throws -> DeferBucketOutcome {
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
        var oResult: Result<AssetLocation, AssetError>?
        if let waiter = b.oWaiter {
            oResult = await EngineRegressionCycle6Tests.driving([b.s.time], fence: engine) { await EngineHarness.value(of: waiter) }
        }
        var extraResults: [Result<AssetLocation, AssetError>] = []
        for waiter in extra {
            extraResults.append(await EngineRegressionCycle6Tests.driving([b.s.time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        let failed = await b.probe.received.compactMap { event -> AssetID? in
            if case .assetFailed(let id, _, _) = event {
                return id
            }
            return nil
        }
        await b.probe.stop()
        for group in [b.group, b.oGroup].compactMap({ $0 }) {
            await engine.releaseGroup(group)
        }
        await Self.finishHeld(b.s)
        return DeferBucketOutcome(served: served, o: oResult, failed: failed, extra: extraResults)
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
        try await self.deferBucketApplyV4(b, visit)
        if visit == .sweepFollowsFirst {
            let turns = try await Self.deferBucketTurns(b)
            try #require(turns.contains { $0.owed && $0.registered > 0 }, "setup: H's visit's joins wait behind O's verdict during the follow: \(turns)")
            // v4's apply's own turn, then each held follow turn while the follow is owed.
            var previous: [AssetID] = []
            for turn in turns where turn.owed {
                #expect(turn.queue == ["O"], "after every held follow turn the queue holds O's verdict alone: \(turns)")
                #expect(turn.behind.count == turn.registered && turn.buckets == 1, "every waiting join waits in O's bucket: \(turns)")
                #expect(turn.behind.starts(with: previous) && turn.behind.count - previous.count <= Self.deferBucketIDsPerTurn, "O's bucket grows by at most a turn's ids, in arrival order: \(turns)")
                previous = turn.behind
            }
            #expect(turns.allSatisfy { $0.violations.isEmpty }, "the invariants hold after every held turn: \(turns)")
        }
        let outcome = try await self.deferBucketFinish(b)
        #expect(outcome.served == Array(repeating: 20, count: count), "every member is served O's 20 bytes (visit-first): \(outcome.served)")
        switch shape.ending {
        case .notFound:
            #expect(outcome.o.map { (try? $0.get()) == nil } == true, "zz-o's 404 answers its waiter (visit-first): \(String(describing: outcome.o))")
            #expect(outcome.failed == [b.o.identifier], "the 404 reports zz-o alone failed (visit-first): \(outcome.failed)")
        case .timeout:
            #expect(outcome.o.flatMap { try? $0.get() }?.byteSize == 20, "zz-o's retry serves its waiter (visit-first): \(String(describing: outcome.o))")
            #expect(outcome.failed.isEmpty, "nothing is reported failed (visit-first): \(outcome.failed)")
        }
    }

    // MARK: A-T1-place: the drain places a bucket right behind its verdict, newest first

    /// The drain places O's bucket right behind O's verdict, newest first, ahead of a request that waits at the queue's
    /// tail: 20 members, v3's pass past them before v4, and a v4 that changes nothing else, so only v4's pass finds H,
    /// H's visit's rest alone keeps the follow owed, its last turn moves the last four and leaves its drain no ids, and
    /// the drain's first batch gives O's verdict and puts the rest back at the queue's head (`drainEventsAfterFollow`).
    /// zz-x (X's 16 bytes), requested between two follow turns once O's bucket holds joins, waits as a tail join
    /// (`addInterest`). Visited first, the same members and zz-x are served.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: the drain places the joins behind a verdict right behind it, newest first, ahead of a later request (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierPlacesTheJoinsBehindAVerdictRightBehindItNewestFirst(_ visit: LaneDropVisit) async throws {
        let count = 20
        let seed: UInt64 = 2_022_711
        let xBytes = EngineFixture.bytes(seed + 5, count: 16)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let b = try await self.deferBucketSetUp(visit, seed: seed, ending: .notFound, wanters: .users, members: count, extra: [x], passV3Members: true)
        let engine = b.s.engine
        await b.s.harness.source.script(x.transferID, [.stage(xBytes)])
        try await self.deferBucketApplyV4(b, visit, fillersStay: true)
        let xWaiter: Task<Result<AssetLocation, AssetError>, Never>
        if visit == .sweepFollowsFirst {
            let first = try await Self.deferBucketTurns(b) { !$0.behind.isEmpty }
            try #require(first.last?.owed == true, "setup: joins wait in O's bucket while the follow is owed: \(first)")
            xWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
            await engine.awaitCondition { FollowBarrier.joinWaits($0, x) }
            let turns = try await Self.deferBucketTurns(b)
            let last = try #require(turns.last)
            let expected = b.members.reversed().map { "join \($0.identifier)" } + ["join \(x.identifier)"]
            try #require(last.queue.first?.hasPrefix("join zz-h") == true, "setup: the follow's last turn leaves its drain no ids, so the drain's first batch gives O's verdict alone: \(first) \(turns)")
            #expect(last.queue == expected, "O's joins wait right behind its verdict, newest first, ahead of zz-x's: \(last.queue)")
            #expect(last.buckets == 0 && last.violations.isEmpty, "the bucket was placed whole: \(last)")
        } else {
            xWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        }
        let outcome = try await self.deferBucketFinish(b, extra: [xWaiter])
        #expect(outcome.served == Array(repeating: 20, count: count), "every member is served O's 20 bytes (visit-first): \(outcome.served)")
        let xResult = try #require(outcome.extra.first)
        #expect((try? xResult.get())?.byteSize == 16, "zz-x is served X's bytes: \(xResult)")
    }

    // MARK: A-T1-skip: a bucket whose verdict the drain skips

    /// The drain places O's bucket even when it skips O's verdict: a one-member prefetch group wants zz-o, and its release,
    /// once the bucket holds joins, retires O's job, whose verdict the drain then skips (no job at its epoch). The members
    /// join a fresh job of O's content, as visited first, where v4's visit joined them to one after the 404.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: the joins behind a verdict the drain skips still join the content (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierJoinsTheJoinsBehindASkippedVerdict(_ visit: LaneDropVisit) async throws {
        let count = 10
        let b = try await self.deferBucketSetUp(visit, seed: 2_022_721, ending: .notFound, wanters: .users, members: count, oByGroup: true)
        let engine = b.s.engine
        let o = b.o.transferID
        try await self.deferBucketApplyV4(b, visit)
        let oGroup = try #require(b.oGroup)
        if visit == .sweepFollowsFirst {
            let turns = try await Self.deferBucketTurns(b) { !$0.behind.isEmpty }
            try #require(turns.last?.owed == true && turns.last?.behind.isEmpty == false, "setup: joins wait in O's bucket while the follow is owed: \(turns)")
            await engine.releaseGroup(oGroup)
            let skipped = await engine.readForTests { e in
                (
                    verdict: e.state.verdictsAfterFollow[o] == nil,
                    event: e.state.eventsAfterFollow.contains { $0.verdictKey?.transfer == o },
                    bucket: e.state.joinsBehindVerdicts.contains { $0.key.transfer == o && !$0.value.isEmpty }
                )
            }
            try #require(skipped.verdict && skipped.event && skipped.bucket, "setup: O's job is retired, its verdict's event still waits, and so do the joins behind it: \(skipped)")
        }
        let outcome = try await self.deferBucketFinish(b)
        #expect(outcome.served == Array(repeating: 20, count: count), "every member is served by a fresh job of O's content (visit-first): \(outcome.served)")
    }

    // MARK: F-SPACE: the verdict an event gives

    /// `EventAfterFollow.verdictKey` names the attempt of the two events that give an exit verdict, an ENOSPC's and an
    /// attempt's, and no other: the drain places a bucket only behind them, and the purge and the invariants walk it there.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: only an exit verdict's event names the attempt whose joins wait behind it (F-28)")
    func onlyAnExitVerdictsEventNamesItsAttempt() {
        let transfer = EngineHarness.onDemand("zz-k", EngineFixture.bytes(2_022_731, count: 16)).transferID
        let key = VerdictKey(transfer: transfer, epoch: 7)
        #expect(EventAfterFollow.spaceFailure(transfer, epoch: 7, required: 1_000).verdictKey == key, "an ENOSPC's verdict names its attempt")
        #expect(EventAfterFollow.attemptFailed(transfer, epoch: 7, verdict: .resolve(.notFound)).verdictKey == key, "an attempt's verdict names its attempt")
        let others: [EventAfterFollow] = [
            .removal(InterestToken(rawValue: 1), transfer),
            .conditions(edge: false),
            .retryDue(transfer, epoch: 7),
            .throttleAnswers,
        ]
        #expect(others.allSatisfy { $0.verdictKey == nil }, "no other event gives a verdict")
    }

    // MARK: A-T1-space: the joins behind an ENOSPC's waiting verdict

    /// The joins a follow's visit waits behind an ENOSPC's waiting verdict (`.spaceFailure`) follow it at the drain, as
    /// they follow an attempt's (`EventAfterFollow.verdictKey`; `integrate-c21.md`'s T1-space, on the ENOSPC shape of
    /// `barrierLeavesAPassedIdToAPublicationsSpaceRetry`). C (zz-a's 100,000 bytes) publishes for A, a user waiter, and
    /// its placement rename fails ENOSPC while v3's follow is owed, so its verdict waits; the 32 MB volume makes it a
    /// retry, held, whose bytes then fail their checksum. H (zz-h's 16 bytes) downloads for W, a user waiter, held; v4
    /// maps zz-h to C's content, and H's visit's join for W waits in C's bucket, behind the ENOSPC's verdict. Visited
    /// first, the verdict was given at its arrival and v4's visit joined W to C's retry; swept first, the drain gives the
    /// verdict, then the join behind it. Both orders: A and W get the retry's `integrityFailure`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: the joins behind an ENOSPC's waiting verdict join its retry at the drain, as visited first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierJoinsTheJoinsBehindASpaceVerdictToItsRetry(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_022_791
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let hBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        let hOnC = EngineHarness.onDemand("zz-h", cBytes)
        let c = a.transferID
        try #require(hOnC.transferID == c && h.transferID != c, "setup: v4 maps zz-h to C's content")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, h] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(c, [.hold, .stage(cBytes), .hold, .stage(wrong)])
        await s.harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[c]?.state == .downloading }
        }
        let wWaiter = Task { await engine.awaitAsset(h.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[h.transferID]?.state == .downloading }
        let releaser = try await Self.holdPublication(of: c, s, bulk: bulk)
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [a, h] + Self.laterFillers(seed + 6_000), tag: "v3-space-bucket-\(seed)", s, visit: visit)
        // The placement rename of C's verified bytes fails ENOSPC.
        s.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .noSpace))
        if visit == .sweepFollowsFirst {
            // The ENOSPC's free-space read runs one follow turn; the space sweep's own follow-up turns are held.
            await engine.readForTests { $0.holdSpaceSweepFollowUps() }
        }
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.eventsAfterFollow.contains(where: Self.isSpaceFailure) }
        } else {
            // The verdict was given at its arrival, a retry after its backoff: C's retry downloads, held (C verified
            // before, so only the retry downloads again).
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[c]?.state == .downloading }
            }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 300) + [a, hOnC] + Self.laterFillers(seed + 9_000), tag: "v4-space-bucket-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            // The follow's turns run one at a time, the drain's held, until H's visit has waited W's join behind C's
            // ENOSPC verdict, which waits in the queue once.
            await engine.readForTests { $0.holdDrainFollowUps() }
            var turns = 0
            while await engine.readForTests({ e in e.followOwed && !e.state.joinsBehindVerdicts.keys.contains { $0.transfer == c } }) {
                try #require(turns < 40, "setup: H's visit runs within 40 follow turns")
                _ = await Self.runOneHeldTurn(engine)
                turns += 1
            }
            let waiting = await engine.readForTests { e in
                (
                    behind: e.state.joinsBehindVerdicts.first { $0.key.transfer == c }?.value.map(\.join.asset) ?? [],
                    verdicts: e.state.eventsAfterFollow.filter(Self.isSpaceFailure).count,
                    violations: e.invariantViolations()
                )
            }
            try #require(waiting.behind == [h.identifier] && waiting.verdicts == 1 && waiting.violations.isEmpty, "setup: W's join waits behind C's ENOSPC verdict, its one waiting event: \(waiting)")
            await engine.readForTests { e in
                e.releaseFollowFollowUps()
                e.releaseDrainFollowUps()
                e.releaseSpaceSweepFollowUps()
            }
        } else {
            let none = await engine.readForTests { e in e.state.joinsBehindVerdicts.isEmpty && e.state.verdictsAfterFollow.isEmpty }
            try #require(none, "visited first, no verdict waits and no join waits behind one")
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[c]?.state == .downloading && $0.state.jobs[c]?.interests.count == 2 }
        }
        await s.harness.source.release(c, with: .progress(received: 0, expected: nil))
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        #expect(aResult == .failure(.integrityFailure), "A gets the retry's integrity failure (visit-first): \(aResult)")
        #expect(wResult == .failure(.integrityFailure), "W, joined to C's retry (visit-first at v4's visit), gets its integrity failure: \(wResult)")
        await Self.finishHeld(s)
    }

    // MARK: A-T-PURGE: a purge withdraws the joins behind a verdict

    /// A purge of the members, while their joins wait in O's bucket, withdraws them there, as it withdraws the waiting
    /// joins of the queue (`withdrawPurgedJoins`): the group stops waiting for them, and the drain joins nothing for
    /// them. A prefetch group wants the members; O times out, and its retry, held until the drain is over, serves zz-o's
    /// waiter. Visited first, v4's visit had joined the members to O's job at once and re-queued it (T20: zz-o's user
    /// waiter keeps its lane user), so the retry had started at v4's barrier end, and the purge withdrew the group's
    /// interest there. The purge leaves the members in the retry's bound ids
    /// (`Job.assets`; `withdrawPurged` withdraws interests only, as `s3-base`'s `performPurge` did), so a visit-first
    /// engine binds them at the retry's publication, and a swept-first one, whose withdrawn joins join nothing, does
    /// not: that difference is the cycle-21 fixer's observation for the orchestrator (the WP-F draft's cycle 21), not
    /// item A's, and each order's stored set is pinned as it is.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a purge withdraws the joins that wait behind a verdict (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierPurgeWithdrawsTheJoinsBehindAVerdict(_ visit: LaneDropVisit) async throws {
        let count = 10
        let b = try await self.deferBucketSetUp(visit, seed: 2_022_741, ending: .timeout, wanters: .group, members: count, holdRetry: true)
        let engine = b.s.engine
        let o = b.o.transferID
        let group = try #require(b.group)
        let ids = Set(b.members.map(\.identifier))
        try await self.deferBucketApplyV4(b, visit)
        if visit == .sweepFollowsFirst {
            let turns = try await Self.deferBucketTurns(b) { $0.behind.count == count }
            try #require(turns.last?.owed == true && turns.last?.behind.count == count, "setup: every member's join waits in O's bucket while the follow is owed: \(turns)")
        }
        let purged = await engine.purge(.scope(.identifiers(ids)))
        #expect((try? purged.get()) != nil, "the purge completes: \(purged)")
        let after = await engine.readForTests { e in
            (
                registered: e.state.joinsAfterFollow[group] == nil,
                pending: e.state.groups[group].map { Set($0.pending.keys).isDisjoint(with: ids) } ?? true,
                behind: e.state.joinsBehindVerdicts.values.flatMap { $0 },
                violations: e.invariantViolations()
            )
        }
        #expect(after.registered && after.pending, "the group's joins are withdrawn and it waits for no member: \(after.registered) \(after.pending)")
        #expect(after.violations.isEmpty, "\(after.violations.prefix(3))")
        if visit == .sweepFollowsFirst {
            #expect(after.behind.count == count && after.behind.allSatisfy { $0.join.withdrawn }, "every join behind O's verdict is withdrawn in place: \(after.behind.map(\.join.withdrawn))")
        }
        await engine.readForTests { e in
            e.releaseFollowFollowUps()
            e.releaseDrainFollowUps()
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await EngineRegressionCycle6Tests.driving([b.s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[o]?.state == .downloading }
        }
        await b.s.harness.source.release(o, with: .progress(received: 0, expected: nil))
        let oWaiter = try #require(b.oWaiter)
        let oResult = await EngineRegressionCycle6Tests.driving([b.s.time], fence: engine) { await EngineHarness.value(of: oWaiter) }
        #expect((try? oResult.get())?.byteSize == 20, "zz-o's waiter is served by O's retry (visit-first): \(oResult)")
        let held = await engine.readForTests { e in e.state.jobs.values.contains { !$0.assets.isDisjoint(with: ids) } }
        #expect(!held, "no job holds a purged member (visit-first)")
        var stored: [AssetID] = []
        for id in ids.sorted() where await b.s.harness.store.location(for: id, extensions: [], recordingAccess: false) != nil {
            stored.append(id)
        }
        switch visit {
        case .sweepFollowsFirst:
            #expect(stored.isEmpty, "no purged member is stored: their withdrawn joins joined nothing: \(stored)")
        case .followVisitedFirst:
            #expect(stored == ids.sorted(), "O's retry binds the purged members it still holds (the observation): \(stored)")
        }
        await b.probe.stop()
        await engine.releaseGroup(group)
        await Self.finishHeld(b.s)
    }

    // MARK: A-T-FL and A-T-FL': a 429's lane counts the joins behind a verdict that join its job

    /// Whether a later apply maps zz-u from O's content to C's (`lanes`).
    enum BucketLaneMove: String, Sendable, CaseIterable {
        /// v5 maps zz-u to C's content: U's join behind O's verdict joins C at the drain (A-T-FL).
        case toC
        /// No v5: U's join behind O's verdict still joins O (A-T-FL').
        case stays
    }

    /// A 429 of C during an owed follow is decided on the lane the joins behind a waiting verdict give C: those that join
    /// C at the drain count, the others do not (`followedLane`). C (1 MB, zz-b) downloads for P, a prefetch waiter; O
    /// (zz-o, 20 bytes) for zz-o's user waiter, timing out while v3's follow is owed, so its verdict waits, its retry held
    /// (visited first it started at v4's barrier end: v4's visit joined U to O's job and re-queued it, T20); H (zz-u's
    /// 16 bytes) for U, a user waiter. v4 maps zz-u to O's content: H's visit's join for U waits in O's bucket. With
    /// `.toC`, v5 maps zz-u to C's content: the drain re-routes U's join there (`replayJoin`). Then C gets a 429 with
    /// Retry-After 60 s, above the user lane's 30 s cap. Visited
    /// first, U's interest was on C's job at the 429 with `.toC` (v5's visit moved it from O's retry), so C was user work:
    /// nothing was throttled, C failed, and P and U were answered `serverUnavailable`; with `.stays` it was on O's retry,
    /// C was prefetch work, the origin was throttled, C's retry served P, and O's retry, started before the 429, served U
    /// and zz-o's waiter. Swept first with `.stays`, O's retry starts at the drain, on the live throttle the 429 left, and
    /// U and zz-o's waiter are answered `serverUnavailable` (60 s is above the user lane's cap): the answer for the live
    /// gate at the decision, a difference ruling S3-R17 item 2 makes non-blocking (a residual risk; this test its probe).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 during an owed follow counts the joins behind a waiting verdict that join its content, and no other (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, BucketLaneMove.allCases)
    func barrierDecidesA429OnTheLaneTheJoinsBehindAVerdictGive(_ visit: LaneDropVisit, _ move: BucketLaneMove) async throws {
        let seed: UInt64 = move == .toC ? 2_022_751 : 2_022_761
        let (s, _) = try await FollowBarrier.setUp(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = Data(repeating: 0xC6, count: 1_000_000)
        let oBytes = EngineFixture.bytes(seed + 3, count: 20)
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let o = EngineHarness.onDemand("zz-o", oBytes)
        let u = EngineHarness.onDemand("zz-u", hBytes)
        let uOnO = EngineHarness.onDemand("zz-u", oBytes)
        let uOnC = EngineHarness.onDemand("zz-u", cBytes)
        try #require(uOnO.transferID == o.transferID && uOnC.transferID == b.transferID, "setup: v4 maps zz-u to O's content, v5 to C's")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [b, o, u] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(b.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(cBytes)])
        await s.harness.source.script(o.transferID, [.hold, .fail(.transient(.timedOut, retryAfter: nil)), .hold, .stage(oBytes)])
        await s.harness.source.script(u.transferID, [.hold, .stage(hBytes)])
        let pWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        let oWaiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        let uWaiter = Task { await engine.awaitAsset(u.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                e.state.conditions != nil && [b, o, u].allSatisfy { e.state.jobs[$0.transferID]?.state == .downloading }
            }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [b, o, u] + Self.laterFillers(seed + 6_000), tag: "v3-bucket-lane-\(seed)", s, visit: visit)
        await s.harness.source.release(o.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[o.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[o.transferID]?.state != .downloading }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 300) + [b, o, uOnO] + Self.laterFillers(seed + 9_000), tag: "v4-bucket-lane-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            try await Self.runFollowTurns(engine, until: { e in e.state.joinsBehindVerdicts.values.contains { $0.contains { $0.join.asset == u.identifier } } }, "H's visit's join for U waits in O's bucket")
        }
        if move == .toC {
            try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 400) + [b, o, uOnC] + Self.laterFillers(seed + 12_000), tag: "v5-bucket-lane-\(seed)", s, visit: visit)
        }
        if visit == .sweepFollowsFirst {
            let waiting = await engine.readForTests { e in
                (owed: e.followOwed, behind: e.state.joinsBehindVerdicts.values.contains { $0.contains { $0.join.asset == u.identifier } }, lane: e.state.jobs[b.transferID]?.lane)
            }
            try #require(waiting.owed && waiting.behind && waiting.lane == .prefetch, "setup: U's join waits behind O's verdict, the follow is owed, and C's job is prefetch work: \(waiting)")
        } else {
            let lane = await engine.readForTests { $0.state.jobs[b.transferID]?.lane }
            try #require(lane == (move == .toC ? .userInitiated : .prefetch), "setup: visited first, U's interest is on C's job only with `.toC`: \(String(describing: lane))")
        }
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        let throttleAtArrival = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        // O's retry, held at its start, starts unthrottled: at v4's barrier end visited first (T20), at the drain swept
        // first with `.toC`. Swept first with `.stays` the live throttle answers its waiters at the drain instead.
        if move == .toC || visit == .followVisitedFirst {
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[o.transferID]?.state == .downloading }
            }
            await s.harness.source.release(o.transferID, with: .progress(received: 0, expected: nil))
        }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        let oResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: oWaiter) }
        switch move {
        case .toC:
            #expect(throttleAtArrival == nil, "the 429 beyond the user lane's cap throttles nothing: U's join made C user work (visit-first `.exhausted`): \(String(describing: throttleAtArrival))")
            Self.expectServerUnavailable(pResult, "P is answered serverUnavailable with C's deferral to the next run (visit-first)")
            Self.expectServerUnavailable(uResult, "U is answered serverUnavailable with C's deferral to the next run (visit-first)")
            #expect((try? oResult.get())?.byteSize == 20, "zz-o's waiter is served by O's retry (visit-first): \(oResult)")
        case .stays:
            #expect(throttleAtArrival != nil, "the 429 throttles the origin for prefetch work: U's join joins O, not C (visit-first): \(String(describing: throttleAtArrival))")
            #expect((try? pResult.get())?.byteSize == Int64(cBytes.count), "P is served by C's retry once the throttle ends (visit-first): \(pResult)")
            switch visit {
            case .followVisitedFirst:
                #expect((try? uResult.get())?.byteSize == 20, "U is served by O's retry, started before the 429: \(uResult)")
                #expect((try? oResult.get())?.byteSize == 20, "zz-o's waiter is served by O's retry, started before the 429: \(oResult)")
            case .sweepFollowsFirst:
                Self.expectServerUnavailable(uResult, "U is answered serverUnavailable by the live throttle at O's retry's start (S3-R17 item 2)")
                Self.expectServerUnavailable(oResult, "zz-o's waiter is answered serverUnavailable by the live throttle at O's retry's start (S3-R17 item 2)")
            }
        }
        await Self.finishHeld(s)
    }

    // MARK: A-F-K1, A-F-K3: the invariants of the joins behind a verdict

    /// The invariants report a bucket without exactly one waiting event of its verdict, an empty bucket, and a join behind
    /// a verdict whose decision instant is past the world history (`followBarrierViolations`, clauses K1 and K3), each
    /// alone. Moved to an attempt whose verdict waits nowhere, a bucket's joins are also missing from the recount, which
    /// counts them at their verdict's place (K2). Swept first only: the state needs a join behind a waiting verdict.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: the invariants report joins behind a verdict that waits nowhere or past the world history (F-28)", .timeLimit(.minutes(3)))
    func invariantsReportTheJoinsBehindAVerdictOutOfPlace() async throws {
        let b = try await self.deferBucketSetUp(.sweepFollowsFirst, seed: 2_022_771, ending: .timeout, wanters: .users, members: 4)
        let engine = b.s.engine
        let o = b.o.transferID
        try await self.deferBucketApplyV4(b, .sweepFollowsFirst)
        let turns = try await Self.deferBucketTurns(b) { !$0.behind.isEmpty }
        try #require(turns.last?.owed == true && turns.last?.behind.isEmpty == false && turns.last?.violations.isEmpty == true, "setup: joins wait in O's bucket while the follow is owed: \(turns)")
        let key = try #require(await engine.readForTests { e in e.state.joinsBehindVerdicts.keys.first { $0.transfer == o } })
        let shape = await engine.readForTests { e in (registered: e.state.joinsAfterFollow.count, views: e.state.worldHistory.count) }
        let k1 = "1 verdicts hold joins behind them without exactly one waiting event"
        let empty = await engine.violations { $0.joinsBehindVerdicts[VerdictKey(transfer: key.transfer, epoch: key.epoch + 1)] = [] }
        #expect(empty == [k1], "an empty bucket: \(empty)")
        let twice = await engine.violations { state in
            let again = state.eventsAfterFollow.filter { $0.verdictKey == key }
            let stamps = Array(state.eventStamps.prefix(again.count))
            state.eventsAfterFollow.append(contentsOf: again)
            state.eventStamps.append(contentsOf: stamps)
        }
        #expect(twice == [k1], "a bucket whose verdict waits twice: \(twice)")
        let moved = await engine.violations { state in
            let bucket = state.joinsBehindVerdicts.removeValue(forKey: key)
            state.joinsBehindVerdicts[VerdictKey(transfer: key.transfer, epoch: key.epoch + 1)] = bucket
        }
        #expect(moved == ["\(shape.registered) interests' joins wait for the follow, 0 with their event", k1], "a bucket whose verdict waits nowhere: \(moved)")
        let late = await engine.violations { state in
            let views = state.worldHistory.count
            if let first = state.joinsBehindVerdicts[key]?.first {
                state.joinsBehindVerdicts[key]?[0] = JoinBehindVerdict(join: first.join, stamp: WorldStamp(at: first.stamp.at, view: views, serial: first.stamp.serial))
            }
        }
        #expect(late == ["1 joins wait behind verdicts with decision instants over \(shape.views) views"], "a join whose decision instant is past the world history: \(late)")
        _ = try await self.deferBucketFinish(b)
    }

    // MARK: A-T-SD: shutdown with joins behind a verdict

    /// Shutdown while joins wait behind O's verdict clears every follow table, the buckets included
    /// (`drainEverything`), and answers zz-o's waiter and every member's `shutDown`. O times out; the members are user
    /// waiters; O's retry holds at the source (`holdRetry`). Visited first, the follow had ended, and v4's visit had moved
    /// the members onto O's job and re-queued it (T20), so its retry, started at v4's barrier end, waits held with zz-o's
    /// waiter and every member until the shutdown (the set-up check). Unheld, that retry could serve them before the
    /// shutdown's first turn, an interleaving the test does not order (cycle 22's flake, ruling S3-R28 item 2).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: shutdown with joins behind a waiting verdict clears them and answers their waiters (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func shutdownClearsTheJoinsBehindAVerdict(_ visit: LaneDropVisit) async throws {
        let count = 10
        let b = try await self.deferBucketSetUp(visit, seed: 2_022_781, ending: .timeout, wanters: .users, members: count, holdRetry: true)
        let engine = b.s.engine
        try await self.deferBucketApplyV4(b, visit)
        if visit == .followVisitedFirst {
            let o = await engine.readForTests { e in e.state.jobs[b.o.transferID].map { (state: $0.state, interests: $0.interests.count) } }
            try #require(o?.state == .downloading && o?.interests == count + 1, "setup: visited first, v4's visit re-queued O (T20), and its held retry holds zz-o's waiter and every member: \(String(describing: o))")
        }
        if visit == .sweepFollowsFirst {
            let behind = await engine.readForTests { e in e.state.joinsBehindVerdicts.values.reduce(0) { $0 + $1.count } }
            try #require(behind > 0, "setup: v4's apply's own turn deferred joins behind O's verdict")
        }
        await engine.shutdown()
        let tables = await engine.readForTests { e in
            [
                e.state.eventsAfterFollow.count, e.state.eventStamps.count, e.state.worldHistory.count, e.state.followStamps.count,
                e.state.verdictsAfterFollow.count, e.state.joinsAfterFollow.count, e.state.joinsBehindVerdicts.count,
            ]
        }
        #expect(tables.allSatisfy { $0 == 0 }, "every follow table is empty, the buckets included: \(tables)")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        let oWaiter = try #require(b.oWaiter)
        #expect(await oWaiter.value == .failure(.shutDown), "zz-o's waiter is answered shutDown")
        var answers: [Result<AssetLocation, AssetError>] = []
        for caller in b.callers {
            answers.append(await caller.value)
        }
        #expect(answers.allSatisfy { $0 == .failure(.shutDown) }, "every member's waiter is answered shutDown: \(answers)")
        await b.probe.stop()
    }
}
