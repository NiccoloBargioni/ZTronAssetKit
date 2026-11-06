import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

/// The C2 pins of Stage 3 close-out cycle 21 (ruling S3-R26 items 2 to 4 and 12; the cycle-20 verifiers' reqs #3,
/// correct #2, correct #5 and reqs #10): the joins a follow's visit defers behind a waiting exit verdict
/// (`deferBehindVerdictTurns`), the drain's visits after verdicts that wait their joins behind the next verdict
/// (`drainVerdictChainTurns`, item 12's answer 5) and the commit's own turn in four groupings (`commitTurns`). Each
/// figure is printed with the host's load averages, which S3-R23 asks for beside every timing figure.
extension ZTronAssetKitBenchmarks.SyncBenchmarks {
    /// C2 of a follow whose visit moves 10,000 ids onto a content whose exit verdict waits (`SyncBench.deferBehind`):
    /// every join waits behind that verdict (`deferBehindVerdict`). Each held follow and drain turn is timed inside the
    /// actor, and the heartbeat covers the apply and every turn; the best of three of each against C2, after a warm-up.
    @Test("R-SYN-11: a follow that defers 10,000 joins behind a waiting exit verdict holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(10)), arguments: DeferBehindShape.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func deferBehindVerdictTurns(_ shape: DeferBehindShape) async throws {
        _ = try await SyncBench.deferBehind(members: 1_000, shape: shape)
        var runs: [DeferBehindRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.deferBehind(members: 10_000, shape: shape))
        }
        for run in runs {
            #expect(run.verdictWaited, "setup: O's verdict waited for the follow: \(run)")
            #expect((run.joinsDuringFollow.max() ?? 0) == 0, "setup: no join entered eventsAfterFollow during the follow (joinsBehindVerdicts holds them): \(run)")
            #expect(run.behindAtFollowEnd == 0 && run.joinsAtFollowEnd == 10_000 - (SyncEngine.eventsAfterFollowPerTurn - 1), "setup: the follow's last turn drained O's bucket into its first batch, behind O's verdict, and the rest wait at the queue's head: \(run)")
            #expect(run.onO == (shape.notFound ? 10_000 : 10_001), "setup: O's content holds every member once the drain is over: \(run)")
            #expect(run.violations.isEmpty, "setup: \(run.violations.prefix(3))")
        }
        let turns = runs.map { $0.turns.max() ?? 0 }
        let waits = runs.map { max($0.applyWait, $0.turnsWait) }
        print("R-SYN-11 deferBehindVerdictTurns \(shape.rawValue) at 10,000: longest held turn \(turns) ms, best \(turns.min() ?? .infinity) ms; heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms (budget \(Self.c2Budget) ms best); runs \(runs)")
        #expect((turns.min() ?? .infinity) <= Self.c2Budget, "longest held turn: \(turns)")
        #expect((waits.min() ?? .infinity) <= Self.c2Budget, "heartbeat: \(waits)")
    }

    /// C2 of the drain's visits after 16 waiting verdicts whose members an apply maps onto the next job's content, whose
    /// own verdict waits later in the batch (ruling S3-R26 item 12's answer 5, candidate 4): `drainVerdictTurns`' shape,
    /// chained (`SyncBench.drainVerdicts`). Each visit's joins wait behind the next verdict (`joinWaitsForVerdict`) and
    /// replay right behind it once it replays, so a drain turn replays up to a turn's ids of joins besides its events and
    /// its visits' moves (`drainEventsAfterFollow`). The follow's and the drain's held turns are released one at a time,
    /// each timed inside the actor, under the heartbeat; the best of three of each against C2, after a warm-up.
    @Test("R-SYN-6: the drain's visits after 16 waiting verdicts that move their members behind the next verdict hold the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(5)), arguments: [500, 625])
    @available(macOS 15.0, iOS 18.0, *)
    func drainVerdictChainTurns(_ perJob: Int) async throws {
        _ = try await SyncBench.drainVerdicts(slots: 16, perJob: 50, chained: true)
        var runs: [DrainVerdictRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.drainVerdicts(slots: 16, perJob: perJob, chained: true))
        }
        for run in runs {
            #expect(run.waitingBefore == 16 && run.heldBefore == 16 * perJob, "setup: the 16 verdicts waited with every member on its job: \(run)")
            #expect(run.mostBehind > 0 && run.heldAfter == 15 * perJob, "setup: the visits' joins waited behind the next verdict, and each job but the first holds the members before it: \(run)")
            #expect(run.violations.isEmpty, "setup: \(run.violations.prefix(3))")
        }
        let turns = runs.map { $0.turns.max() ?? 0 }
        let waits = runs.map(\.wait)
        print("R-SYN-6 drainVerdictChainTurns \(perJob) a job: longest held turn \(turns) ms, best \(turns.min() ?? .infinity) ms; heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms (budget \(Self.c2Budget) ms best); runs \(runs)")
        #expect((turns.min() ?? .infinity) <= Self.c2Budget, "\(perJob) a job, the longest held turn: \(turns)")
        #expect((waits.min() ?? .infinity) <= Self.c2Budget, "\(perJob) a job, the heartbeat: \(waits)")
    }

    /// C2 of `k` moves owed off one holder of 10,000 ids onto `k` publications in flight (`SyncBench.manyMoves`; the
    /// cycle-20 correctness verifier's PROBE-C20C-MANY-MOVES): one follow turn makes them all, at most `followsPerTurn`.
    /// The longest held follow turn, timed inside the actor, best of three against C2, after a warm-up.
    @Test("R-SYN-11: up to followsPerTurn moves owed off one 10,000-id holder hold the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(10)), arguments: [1, 16, 64, 256])
    @available(macOS 15.0, iOS 18.0, *)
    func manyMovesTurns(_ moves: Int) async throws {
        _ = try await SyncBench.manyMoves(count: 1_000, moves: moves)
        var runs: [ManyMovesRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.manyMoves(count: 10_000, moves: moves))
        }
        for run in runs {
            #expect(run.violations.isEmpty, "setup: \(run.violations.prefix(3))")
            #expect(run.publishing == moves && run.owedOffH == moves, "setup: one owed move off H per publication: \(run)")
            #expect(run.firstTurnMoves == moves, "setup: one held turn makes every owed move: \(run)")
        }
        let longest = runs.map(\.longestFollow)
        print("R-SYN-11 manyMovesTurns k=\(moves) off 10,000 ids: longest follow turn \(longest) ms, best \(longest.min() ?? .infinity) ms (budget \(Self.c2Budget) ms best); runs \(runs)")
        #expect((longest.min() ?? .infinity) <= Self.c2Budget, "\(longest)")
    }

    /// C2 of a visit that moves 500 of a holder's 10,000 ids (`SyncBench.partialMove`; the cycle-20 requirements
    /// verifier's PROBE-C20R-PARTIAL-MOVE-C2): the moved ids fit the turn, so the visit takes `move`. With `users`, each
    /// id has a user waiter of its own; without, one prefetch group holds them all. The heartbeat over the apply and its
    /// follow, best of three against C2, after a warm-up.
    @Test("R-SYN-11: a visit that moves 500 of a 10,000-id holder's ids holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(10)), arguments: [false, true])
    @available(macOS 15.0, iOS 18.0, *)
    func partialMoveTurns(_ users: Bool) async throws {
        _ = try await SyncBench.partialMove(members: 1_000, moved: 50, users: users)
        var runs: [PartialMoveRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.partialMove(members: 10_000, moved: 500, users: users))
        }
        for run in runs {
            #expect(run.onO == 501 && run.onH == 9_500, "setup: the visit moved 500 ids onto O and left 9,500 on H: \(run)")
        }
        let waits = runs.map(\.wait)
        print("R-SYN-11 partialMoveTurns users=\(users) 500 of 10,000: heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms (budget \(Self.c2Budget) ms best); runs \(runs)")
        #expect((waits.min() ?? .infinity) <= Self.c2Budget, "\(waits)")
    }

    /// The interest index's own costs (`Job.tokensByID`; ruling S3-R26 item 3's inventory rows), on a job of 10,000 ids
    /// that one prefetch group holds, each id also held by a user waiter of its own (`SyncBench.indexCosts`): the release
    /// of the group's interest (`dropInterest`'s: 10,000 ids each leaving an entry of two holders), `keepInterests`
    /// dropping it on a copy of the job (`jobAtVerdict`'s, which copies the index once), and the freeing of the job with
    /// its index (`removeJob`'s at a commit). Each is timed alone in release, best of three, after a warm-up; the engine's
    /// turns that contain them are `handleReleaseTurns`, `followedLane`'s cases and `concentrationPublicationTurns`.
    @Test("R-SYN-11: the interest index's own upkeep for 10,000 ids stays inside C2's 10 ms", .timeLimit(.minutes(5)))
    @available(macOS 15.0, iOS 18.0, *)
    func indexOwnCosts() async throws {
        _ = SyncBench.indexCosts(count: 1_000)
        var runs: [IndexCostRun] = []
        for _ in 0..<3 {
            runs.append(SyncBench.indexCosts(count: 10_000))
        }
        for run in runs {
            #expect(run.indexedBefore == 10_000 && run.indexedAfter == 10_000 && run.copyIndexed == 10_000, "setup: every id indexed, and each keeps its waiter once the group leaves: \(run)")
        }
        let release = runs.map(\.release).min() ?? .infinity
        let keep = runs.map(\.keepOnCopy).min() ?? .infinity
        let free = runs.map(\.free).min() ?? .infinity
        print("R-SYN-11 indexOwnCosts 10,000 ids: release \(runs.map(\.release)) ms (best \(release)), keepInterests on a copy \(runs.map(\.keepOnCopy)) ms (best \(keep)), freeing \(runs.map(\.free)) ms (best \(free)) (budget \(Self.c2Budget) ms best); runs \(runs)")
        #expect(release <= Self.c2Budget && keep <= Self.c2Budget && free <= Self.c2Budget, "\(runs)")
    }

    /// C2 of a commit that binds and answers 10,000 ids (`SyncBench.commitTurn`; ruling S3-R26 item 4, the cycle-20
    /// verifiers' correct #5 and reqs #10), in four groupings: a user waiter per id, the same with a stalled subscriber,
    /// one prefetch group with a stalled subscriber, and 10,000 one-member prefetch groups. The heartbeat over the commit
    /// is the gate, best of three against C2; the commit's own turn is also timed inside the actor
    /// (`EngineState.commitTurnMarksForTests`), which decides item 4's Phase 2 trigger (7.0 ms).
    @Test("R-SYN-11: a commit that binds and answers 10,000 ids holds the engine's actor at most C2's 10 ms", .timeLimit(.minutes(10)), arguments: CommitShape.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func commitTurns(_ shape: CommitShape) async throws {
        _ = try await SyncBench.commitTurn(count: 1_000, shape: shape)
        var runs: [CommitRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.commitTurn(count: 10_000, shape: shape))
        }
        for run in runs {
            #expect(run.ids == 10_000 && run.interests == shape.interests(10_000) && run.served && run.committed, "setup: the commit bound and answered every id: \(run)")
            #expect(shape.subscribers == 0 || run.buffered >= 10_000, "setup: the stalled subscriber held a slot per id: \(run)")
        }
        let waits = runs.map(\.wait)
        let turns = runs.map(\.turn)
        print("R-SYN-11 commitTurns \(shape.rawValue) at 10,000: heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms (budget \(Self.c2Budget) ms best); the commit's own turn \(turns) ms, best \(turns.min() ?? .infinity) ms (Phase 2 trigger 7.0 ms); runs \(runs)")
        #expect((waits.min() ?? .infinity) <= Self.c2Budget, "\(waits)")
    }

    /// The cost of a second stalled subscriber at a commit of 10,000 user waiters, measured once (ruling S3-R26 item
    /// 12, answer 4): the reference set has one subscriber, so this figure is recorded, not gated; a second stalled
    /// subscriber is outside the bar, by the owner's ruling of 5 Nov; recorded (ruling S3-R27 item 12.1). The setup is
    /// checked as in `commitTurns`.
    @Test("R-SYN-11: a commit that answers 10,000 user waiters with two stalled subscribers, measured once (S3-R26 answer 4)", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func commitTwoStalledSubscribersTurns() async throws {
        _ = try await SyncBench.commitTurn(count: 1_000, shape: .waitersStalledSubscriber, subscribers: 2)
        var runs: [CommitRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.commitTurn(count: 10_000, shape: .waitersStalledSubscriber, subscribers: 2))
        }
        for run in runs {
            #expect(run.ids == 10_000 && run.interests == 10_000 && run.served && run.committed && run.buffered >= 20_000, "setup: the commit answered every waiter and each subscriber held a slot per id: \(run)")
        }
        let waits = runs.map(\.wait)
        let turns = runs.map(\.turn)
        print("R-SYN-11 commitTurns waiters with two stalled subscribers at 10,000 (recorded, not gated): heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms; the commit's own turn \(turns) ms, best \(turns.min() ?? .infinity) ms; runs \(runs)")
    }
}

/// The groupings of `SyncBench.deferBehind`: how the verdict that waits ends, and who wants the moved ids.
enum DeferBehindShape: String, Sendable, CaseIterable {
    /// O gets a 404 (`.resolve`); one prefetch group wants the ids.
    case notFoundGroup
    /// O times out (`.retry`); one prefetch group wants the ids.
    case timeoutGroup
    /// O gets a 404; each id has a user waiter of its own.
    case notFoundUsers
    /// O times out; each id has a user waiter of its own.
    case timeoutUsers

    /// Whether O's attempt ends in a 404.
    var notFound: Bool {
        self == .notFoundGroup || self == .notFoundUsers
    }

    /// Whether each id has a user waiter of its own.
    var users: Bool {
        self == .notFoundUsers || self == .timeoutUsers
    }
}

/// What `SyncBench.deferBehind` measured and read.
struct DeferBehindRun: CustomStringConvertible {
    /// The heartbeat's longest wait over v4's apply, and over the held follow and drain turns.
    var applyWait = 0.0
    var turnsWait = 0.0
    /// Each held follow or drain turn, timed inside the actor.
    var turns: [Double] = []
    /// The waiting events after each held follow turn, the joins behind a verdict included (the queue the visits' joins
    /// went to on `8e1fb24`; `EngineState.joinsBehindVerdicts` since ruling S3-R26 item 2).
    var eventsDuringFollow: [Int] = []
    /// The waiting `.join` events of the queue after each held follow turn that left the follow owed.
    var joinsDuringFollow: [Int] = []
    /// The waiting `.join` events of the queue, and the joins behind a verdict, once the follow's last turn ran.
    var joinsAtFollowEnd = 0
    var behindAtFollowEnd = 0
    /// Whether O's verdict waited for the follow.
    var verdictWaited = false
    /// The ids on O's content's job once the drain is over.
    var onO = 0
    /// The invariants once the drain is over.
    var violations: [String] = []
    /// The host's load averages before and after the run.
    var load = ""

    var description: String {
        "turns \(self.turns.count) longest \(String(format: "%.2f", self.turns.max() ?? 0)) ms; apply \(String(format: "%.2f", self.applyWait)) ms, turns' heartbeat \(String(format: "%.2f", self.turnsWait)) ms; most events during the follow \(self.eventsDuringFollow.max() ?? 0), most queued joins \(self.joinsDuringFollow.max() ?? 0); joins at the follow's end \(self.joinsAtFollowEnd) queued, \(self.behindAtFollowEnd) behind a verdict; on O \(self.onO); load \(self.load)"
    }
}

/// What `SyncBench.manyMoves` measured and read.
struct ManyMovesRun: CustomStringConvertible {
    /// Each held follow or drain turn, timed inside the actor, with its kind.
    var turns: [(kind: String, ms: Double)] = []
    /// The users' publications held at the store.
    var publishing = 0
    /// The moves owed after v4's apply, and those off H.
    var owedAfterV4 = 0
    var owedOffH = 0
    /// The moves the first held follow turn made (the owed moves it took off the queue).
    var firstTurnMoves = 0
    /// H's ids after v3's apply.
    var hAfterV3 = 0
    /// The invariants once the follow and its drain are over.
    var violations: [String] = []
    /// The host's load averages before and after the run.
    var load = ""

    /// The longest held follow turn.
    var longestFollow: Double {
        self.turns.filter { $0.kind == "follow" }.map(\.ms).max() ?? 0
    }

    var description: String {
        "publishing \(self.publishing); H ids after v3 \(self.hAfterV3); owed after v4 \(self.owedAfterV4) (off H \(self.owedOffH)); first turn's moves \(self.firstTurnMoves); longest follow turn \(String(format: "%.2f", self.longestFollow)) ms over \(self.turns.count) turns; load \(self.load)"
    }
}

/// What `SyncBench.partialMove` measured and read.
struct PartialMoveRun: CustomStringConvertible {
    /// The heartbeat's longest wait over the apply and its follow.
    var wait = 0.0
    /// The ids on O's job and on H's after the follow.
    var onO = 0
    var onH = 0
    /// The host's load averages before and after the run.
    var load = ""

    var description: String {
        "wait \(String(format: "%.2f", self.wait)) ms; on O \(self.onO), on H \(self.onH); load \(self.load)"
    }
}

/// What `SyncBench.indexCosts` measured and read.
struct IndexCostRun: CustomStringConvertible {
    /// The release of the group's interest, `keepInterests` dropping it on a copy, and the job's freeing, in ms.
    var release = 0.0
    var keepOnCopy = 0.0
    var free = 0.0
    /// The ids indexed before the release, after it, and on the copy after `keepInterests`.
    var indexedBefore = 0
    var indexedAfter = 0
    var copyIndexed = 0
    /// The host's load averages before and after the run.
    var load = ""

    var description: String {
        "release \(String(format: "%.3f", self.release)) ms, keep on a copy \(String(format: "%.3f", self.keepOnCopy)) ms, free \(String(format: "%.3f", self.free)) ms; indexed \(self.indexedBefore) -> \(self.indexedAfter), copy \(self.copyIndexed); load \(self.load)"
    }
}

/// The groupings of `SyncBench.commitTurn` (ruling S3-R26 item 4; `integrate-c21.md` item C's pins).
enum CommitShape: String, Sendable, CaseIterable {
    /// A user waiter per id.
    case waiters
    /// A user waiter per id, and a subscriber that reads nothing.
    case waitersStalledSubscriber
    /// One prefetch group of every id, and a subscriber that reads nothing.
    case groupStalledSubscriber
    /// One one-member prefetch group per id.
    case manyGroups

    /// The interests H's job holds at the commit, for `count` ids.
    func interests(_ count: Int) -> Int {
        self == .groupStalledSubscriber ? 1 : count
    }

    /// The stalled subscribers the shape registers.
    var subscribers: Int {
        self == .waitersStalledSubscriber || self == .groupStalledSubscriber ? 1 : 0
    }
}

/// What `SyncBench.commitTurn` measured and read.
struct CommitRun: CustomStringConvertible {
    /// The heartbeat's longest wait over the commit.
    var wait = 0.0
    /// The commit's own turn, timed inside the actor.
    var turn = 0.0
    /// H's ids and interests before the commit.
    var ids = 0
    var interests = 0
    /// Whether every caller was answered with a location, or every group's members were, and H's job is gone.
    var served = false
    var committed = false
    /// The events the stalled subscribers buffered.
    var buffered = 0
    /// The host's load averages before and after the run.
    var load = ""

    var description: String {
        "heartbeat \(String(format: "%.2f", self.wait)) ms, turn \(String(format: "%.2f", self.turn)) ms; ids \(self.ids), interests \(self.interests); served \(self.served), committed \(self.committed), buffered \(self.buffered); load \(self.load)"
    }
}

/// An engine as `SyncBench.followBench` builds it, with a stepped bulk executor so a publication can be held at its
/// first store unit.
@available(macOS 15.0, iOS 18.0, *)
struct HeldPublicationBench {
    let bench: FollowBench
    let bulk: SteppedBlockingExecutor
    /// The engine's clock (and the store's): a purge waits out the deletion grace on it (`awaitReclaim`).
    let time: ManualTimeSource
}

/// A thread-safe record of the commit turn's marks (`EngineState.commitTurnMarksForTests`).
@available(macOS 15.0, iOS 18.0, *)
final class CommitTurnClock: Sendable {
    private let marks = Mutex<(began: ContinuousClock.Instant?, longest: Duration)>((nil, .zero))

    /// Records a mark: a begin starts a span, an end closes it and keeps the longest.
    func mark(_ ended: Bool) {
        let now = ContinuousClock.now
        self.marks.withLock { marks in
            if ended {
                if let began = marks.began {
                    marks.longest = max(marks.longest, now - began)
                }
                marks.began = nil
            } else {
                marks.began = now
            }
        }
    }

    /// The longest closed span, in milliseconds.
    var longest: Double {
        SyncBench.milliseconds(self.marks.withLock { $0.longest })
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    /// `count` changed on-demand entries of their own 16-byte contents that sort before the scenarios' ids: a follow's
    /// first turn formats `followFormatsPerTurn` of them and stops before the scenario's entries, so it stays owed.
    static func leadingFillers(_ seed: UInt64) -> [ManifestEntry] {
        (0..<(SyncEngine.followFormatsPerTurn + 52)).map { SyncBench.entry(String(format: "f%05d", $0), GeneratedPayload.bytes(seed: seed + UInt64($0), offset: 0, length: 16), policy: .onDemand) }
    }

    /// Holds the follow's and the drain's follow-up turns.
    static func holdTurns(_ engine: isolated SyncEngine) {
        engine.holdFollowFollowUps()
        engine.holdDrainFollowUps()
    }

    /// Whether no follow is owed, the barrier is down and no follow or drain turn is scheduled.
    static func turnsSettled(_ engine: isolated SyncEngine) -> Bool {
        !engine.followBarrier && !engine.state.followFollowUpScheduled && !engine.state.drainFollowUpScheduled
    }

    /// The waiting events, the waiting `.join` events among them, and the joins that wait behind a verdict
    /// (`EngineState.joinsBehindVerdicts`), which the drain replays as `.join` events.
    static func waitingEvents(_ engine: isolated SyncEngine) -> (events: Int, joins: Int, behind: Int) {
        let events = engine.state.eventsAfterFollow
        return (events.count, events.filter { if case .join = $0 { true } else { false } }.count, SyncBench.joinsBehindVerdicts(engine))
    }

    /// The engine's invariants, from inside the actor.
    static func violations(_ engine: isolated SyncEngine) -> [String] {
        engine.invariantViolations()
    }

    /// Releases every held follow or drain turn, one at a time, each timed inside the actor, until the follow and its
    /// drain are over; `perTurn` reads the engine after each.
    static func releaseTurnsUntilSettled(_ engine: SyncEngine, perTurn: (Bool) async -> Void = { _ in }) async throws -> [Double] {
        var turns: [Double] = []
        var spins = 0
        while !Task.isCancelled, !(await SyncBench.turnsSettled(engine)) {
            let follow = await SyncBench.followWaiting(engine)
            if let turn = await SyncBench.releaseOneHeldFollowOrDrainTurn(engine) {
                turns.append(turn)
                await perTurn(follow)
            } else {
                spins += 1
                if spins > 50_000_000 {
                    throw SyncBenchError.incomplete("the follow and its drain never settled: \(await SyncBench.followShape(engine))")
                }
                await Task.yield()
            }
        }
        return turns
    }

    /// The joins a follow's visit defers behind a waiting exit verdict (Stage 3 close-out cycle 21, ruling S3-R26 item 2;
    /// the cycle-20 requirements verifier's PROBE-C20R-DEFER-BEHIND-C2): `count` members share H's 16 bytes, one job,
    /// downloading (held), wanted by one prefetch group or each by a user waiter (`shape`); O (a user waiter) downloads,
    /// held, scripted to a 404 or a timeout. v3 changes only the leading fillers, so the follow stays owed (its follow-ups
    /// held), and O's attempt ends: its verdict waits for the follow. v4 maps every member to O's content (and changes the
    /// fillers again): H's visit moves the `count` ids over the follow's bounded turns, and each join onto O's content
    /// waits behind O's verdict (`addInterest`, `deferBehindVerdict`). The heartbeat times v4's apply and then every held
    /// follow and drain turn, each also timed inside the actor.
    static func deferBehind(members count: Int, shape: DeferBehindShape) async throws -> DeferBehindRun {
        var run = DeferBehindRun()
        let loadBefore = SyncBench.loadAverages()
        let bench = try await SyncBench.followBench()
        let engine = bench.engine
        let source = bench.source
        let oBytes = Data(repeating: 0x6F, count: 16)
        let hBytes = Data(repeating: 0x68, count: 16)
        let o = SyncBench.entry("o", oBytes, policy: .onDemand)
        let members = SyncBench.sharing(count, hBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData(SyncBench.leadingFillers(0x51_000) + members + [o]), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the second sync did not complete")
        }
        try await bench.store.flush(.ordered)
        let holder = members[0].transferID
        let failure: TransferError = shape.notFound ? .permanentMissing(httpStatus: 404) : .transient(.timedOut, retryAfter: nil)
        await source.script(o.transferID, [.hold, .fail(failure), .stage(oBytes)])
        await source.script(holder, [.hold, .stage(hBytes)])
        let waiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        while !Task.isCancelled, !(await SyncBench.isRunning(engine, o.transferID)) {
            await Task.yield()
        }
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        if shape.users {
            for entry in members {
                let id = entry.identifier
                callers.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
            }
        } else {
            guard case .success = await engine.registerGroup(members.map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("the prefetch group was refused")
            }
        }
        var spins = 0
        while !Task.isCancelled {
            let now = await SyncBench.userHolding(engine, holder)
            if now.ids == count, now.interests == (shape.users ? count : 1), await SyncBench.isRunning(engine, holder) {
                break
            }
            spins += 1
            if spins > 5_000_000 {
                throw SyncBenchError.incomplete("setup: H never held every id: \(now)")
            }
            await Task.yield()
        }
        await SyncBench.holdTurns(engine)
        let v3 = try ValidatedManifest(entries: SyncBench.leadingFillers(0x52_000) + members + [o], digest: ContentHash.sha256(of: Data("v3-defer-\(shape.rawValue)-\(count)".utf8)))
        _ = await engine.applyAndFollow(v3, etag: nil, eviction: nil)
        guard await SyncBench.followOwedNow(engine) else {
            throw SyncBenchError.incomplete("setup: v3's follow is not owed")
        }
        await source.release(o.transferID, with: .progress(received: 0, expected: nil))
        while !Task.isCancelled, !(await SyncBench.verdictWaits(engine, o.transferID)) {
            await Task.yield()
        }
        run.verdictWaited = await SyncBench.verdictWaits(engine, o.transferID)
        let v4 = try ValidatedManifest(entries: SyncBench.leadingFillers(0x53_000) + SyncBench.sharing(count, oBytes) + [o], digest: ContentHash.sha256(of: Data("v4-defer-\(shape.rawValue)-\(count)".utf8)))
        await SyncBench.raiseOwnedTaskPriority(engine)
        run.applyWait = try await SyncBench.longestWait(on: engine) {
            _ = await engine.applyAndFollow(v4, etag: nil, eviction: nil)
        }
        var followEnded = false
        var eventsDuringFollow: [Int] = []
        var joinsDuringFollow: [Int] = []
        var joinsAtFollowEnd = 0
        var behindAtFollowEnd = 0
        var turns: [Double] = []
        run.turnsWait = try await SyncBench.longestWait(on: engine) {
            turns = try await SyncBench.releaseTurnsUntilSettled(engine) { follow in
                guard follow, !followEnded else {
                    return
                }
                let waiting = await SyncBench.waitingEvents(engine)
                eventsDuringFollow.append(waiting.events + waiting.behind)
                if !(await SyncBench.followOwedNow(engine)) {
                    followEnded = true
                    joinsAtFollowEnd = waiting.joins
                    behindAtFollowEnd = waiting.behind
                } else {
                    joinsDuringFollow.append(waiting.joins)
                }
            }
        }
        run.turns = turns
        run.eventsDuringFollow = eventsDuringFollow
        run.joinsDuringFollow = joinsDuringFollow
        run.joinsAtFollowEnd = joinsAtFollowEnd
        run.behindAtFollowEnd = behindAtFollowEnd
        await SyncBench.releaseHeldTurns(engine)
        run.onO = await SyncBench.holding(engine, o.transferID).ids
        run.violations = await SyncBench.violations(engine)
        await engine.shutdown()
        _ = await waiter.value
        for caller in callers {
            _ = await caller.value
        }
        run.load = "\(loadBefore) -> \(SyncBench.loadAverages())"
        return run
    }

    /// An engine as `followBench` builds it, with a stepped bulk executor (not holding) and `tuning`.
    static func heldPublicationBench(tuning: SyncTuning = SyncTuning()) async throws -> HeldPublicationBench {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let conditions = FakeDeviceConditionsSource()
        let capacity = StoragePolicy().reserveFreeBytes + (64 << 20)
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: capacity, opportunisticCapacity: capacity)
        )
        let bulk = SteppedBlockingExecutor(holding: false)
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: bulk,
            time: time,
            random: SeededRandom(seed: 0x12),
            conditions: conditions,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        let configuration = StoreConfiguration(
            location: .applicationSupport,
            policy: StoragePolicy(minimumResidency: 0, deletionGrace: 60),
            legacy: LegacyMigrationPolicy(enabled: false),
            limits: ManifestLimits(),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
        let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: tuning))
        let xBytes = Data(repeating: 0x78, count: 2_000)
        let x = SyncBench.entry("x", xBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData([x]), etag: ETag(rawValue: "\"v1\""))])
        await source.script(x.transferID, [.stage(xBytes)])
        _ = try await engine.start().get()
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the setup sync did not complete")
        }
        return HeldPublicationBench(bench: FollowBench(engine: engine, source: source, store: store, fileSystem: fileSystem), bulk: bulk, time: time)
    }

    /// `k` moves owed off one holder onto `k` publications in flight (Stage 3 close-out cycle 21, ruling S3-R26 item 3;
    /// the cycle-20 correctness verifier's PROBE-C20C-MANY-MOVES): H, `count` prefetch members sharing one content,
    /// downloads (held); `k` user waiters U_i on contents of their own publish, held at their first store unit. v3 maps
    /// H's first `k` members each to one U_i's content (the follow is held, H not visited: the leading fillers change at
    /// each apply); v4 (the same mapping, other fillers) is applied while H's visit is owed, so its walk finds one move off
    /// H per publication (`bringInboundOntoPublications`). Each held follow or drain turn is timed inside the actor.
    static func manyMoves(count: Int, moves k: Int) async throws -> ManyMovesRun {
        var run = ManyMovesRun()
        let loadBefore = SyncBench.loadAverages()
        // No preemption: the user downloads must not cancel H's held attempt.
        let held = try await SyncBench.heldPublicationBench(tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 1, preemptLowerLanes: false))
        let engine = held.bench.engine
        let source = held.bench.source
        let bulk = held.bulk
        let hBytes = Data(repeating: 0x68, count: 16)
        let names = (0..<count).map { String(format: "zz-h%05d", $0) }
        let onH = names.map { SyncBench.entry($0, hBytes, policy: .onDemand) }
        let uBytes = (0..<k).map { GeneratedPayload.bytes(seed: 0x61_000 + UInt64($0), offset: 0, length: 20 + $0 % 7) }
        let users = (0..<k).map { SyncBench.entry(String(format: "zz-u%03d", $0), uBytes[$0], policy: .onDemand) }
        let movedH = (0..<count).map { index in index < k ? SyncBench.entry(names[index], uBytes[index], policy: .onDemand) : onH[index] }
        let hTransfer = onH[0].transferID
        let userTransfers = users.map(\.transferID)
        guard Set(userTransfers).count == k, !userTransfers.contains(hTransfer) else {
            throw SyncBenchError.incomplete("setup: the users' contents are not distinct")
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(SyncBench.leadingFillers(0x62_000) + onH + users), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the second sync did not complete")
        }
        try await held.bench.store.flush(.ordered)
        await source.script(hTransfer, [.hold, .hold, .hold, .stage(hBytes)])
        for (user, bytes) in zip(users, uBytes) {
            await source.script(user.transferID, [.stage(bytes)])
        }
        guard case .success = await engine.registerGroup(onH.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled {
            let now = await SyncBench.holding(engine, hTransfer)
            if now.ids == count, await SyncBench.isRunning(engine, hTransfer), await SyncBench.storeIdle(engine) {
                break
            }
            await Task.yield()
        }
        await bulk.setHolding(true)
        let waiters = users.map { user in Task { await engine.awaitAsset(user.identifier, lane: .userInitiated) } }
        var spins = 0
        while !Task.isCancelled, await SyncBench.verifying(engine, userTransfers) < k {
            spins += 1
            if spins > 50_000_000 {
                throw SyncBenchError.incomplete("setup: the users' publications never all began: \(await SyncBench.verifying(engine, userTransfers)) of \(k)")
            }
            await Task.yield()
        }
        await bulk.waitForHeldUnits(atLeast: k)
        let heldUnits = Set(await bulk.heldUnits)
        let releaser = Task {
            while !Task.isCancelled {
                await bulk.waitForHeldUnits(atLeast: heldUnits.count + 1)
                for other in await bulk.heldUnits where !heldUnits.contains(other) {
                    await bulk.release(other)
                }
            }
        }
        run.publishing = await SyncBench.verifying(engine, userTransfers)
        guard try await SyncBench.applyHeldFollow(engine, SyncBench.leadingFillers(0x63_000) + movedH + users, tag: "v3-many-\(count)-\(k)") else {
            throw SyncBenchError.incomplete("setup: v3's follow is not owed")
        }
        run.hAfterV3 = await SyncBench.holding(engine, hTransfer).ids
        guard try await SyncBench.applyHeldFollow(engine, SyncBench.leadingFillers(0x64_000) + movedH + users, tag: "v4-many-\(count)-\(k)") else {
            throw SyncBenchError.incomplete("setup: v4's follow is not owed")
        }
        (run.owedAfterV4, run.owedOffH) = await SyncBench.owedMoves(engine, off: hTransfer)
        await SyncBench.holdTurns(engine)
        await SyncBench.raiseOwnedTaskPriority(engine)
        var first = true
        while !Task.isCancelled, await SyncBench.barrierUp(engine) {
            let follow = await SyncBench.followWaiting(engine)
            let owedBefore = await SyncBench.owedMoves(engine, off: hTransfer).total
            if let turn = await SyncBench.releaseOneHeldFollowOrDrainTurn(engine) {
                run.turns.append((follow ? "follow" : "drain", turn))
                if first, follow {
                    first = false
                    run.firstTurnMoves = owedBefore - (await SyncBench.owedMoves(engine, off: hTransfer).total)
                }
            } else {
                await Task.yield()
            }
            if run.turns.count > 400 {
                throw SyncBenchError.incomplete("the follow and its drain did not end within 400 turns")
            }
        }
        await SyncBench.releaseHeldTurns(engine)
        while !Task.isCancelled, !(await SyncBench.turnsSettled(engine)) {
            await Task.yield()
        }
        run.violations = await SyncBench.violations(engine)
        releaser.cancel()
        _ = await releaser.value
        await bulk.setHolding(false)
        await bulk.releaseAll()
        await engine.shutdown()
        for waiter in waiters {
            _ = await waiter.value
        }
        run.load = "\(loadBefore) -> \(SyncBench.loadAverages())"
        return run
    }

    /// Whether no store work is in flight.
    static func storeIdle(_ engine: isolated SyncEngine) -> Bool {
        !engine.state.storeWorkInFlight
    }

    /// How many of `transfers` are verifying (their publication began).
    static func verifying(_ engine: isolated SyncEngine, _ transfers: [TransferID]) -> Int {
        transfers.filter { engine.state.jobs[$0]?.state == .verifying }.count
    }

    /// The owed moves (`EngineState.inboundMoves[inboundNext...]`), and those off `holder`.
    static func owedMoves(_ engine: isolated SyncEngine, off holder: TransferID) -> (total: Int, off: Int) {
        let owed = engine.state.inboundMoves[engine.state.inboundNext...]
        return (owed.count, owed.filter { $0.holder == holder }.count)
    }

    /// A visit that moves `moved` of a holder's `count` ids (Stage 3 close-out cycle 21, ruling S3-R26 item 3; the
    /// cycle-20 requirements verifier's PROBE-C20R-PARTIAL-MOVE-C2): the members share H's 16 bytes (one job,
    /// downloading, held), each with a user waiter (`users`) or all in one prefetch group; O (a user waiter) downloads,
    /// held. v3 maps the first `moved` members to O's content: H's visit moves `moved` ids, which fit the turn's ids, so it
    /// takes `move`. The heartbeat times the apply's sync and its whole follow.
    static func partialMove(members count: Int, moved: Int, users: Bool) async throws -> PartialMoveRun {
        var run = PartialMoveRun()
        let loadBefore = SyncBench.loadAverages()
        let bench = try await SyncBench.followBench()
        let engine = bench.engine
        let source = bench.source
        let oBytes = Data(repeating: 0x6F, count: 16)
        let hBytes = Data(repeating: 0x68, count: 16)
        let o = SyncBench.entry("o", oBytes, policy: .onDemand)
        let members = SyncBench.sharing(count, hBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData(members + [o]), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the second sync did not complete")
        }
        try await bench.store.flush(.ordered)
        let holder = members[0].transferID
        await source.script(o.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        await source.script(holder, [.hold, .stage(hBytes)])
        let oWaiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        while !Task.isCancelled, !(await SyncBench.isRunning(engine, o.transferID)) {
            await Task.yield()
        }
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        if users {
            for entry in members {
                let id = entry.identifier
                callers.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
            }
        } else {
            guard case .success = await engine.registerGroup(members.map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("the prefetch group was refused")
            }
        }
        var spins = 0
        while !Task.isCancelled {
            let now = await SyncBench.userHolding(engine, holder)
            if now.ids == count, now.interests == (users ? count : 1), await SyncBench.isRunning(engine, holder) {
                break
            }
            spins += 1
            if spins > 5_000_000 {
                throw SyncBenchError.incomplete("setup: H never held every id: \(now)")
            }
            await Task.yield()
        }
        let v3 = SyncBench.sharing(count, hBytes).enumerated().map { index, entry in index < moved ? SyncBench.entry(entry.identifier.rawValue, oBytes, policy: .onDemand) : entry }
        await SyncBench.raiseOwnedTaskPriority(engine)
        run.wait = try await SyncBench.timedApply(bench, v3 + [o], tag: "v3-partial-\(users)-\(moved)-\(count)")
        run.onO = await SyncBench.userHolding(engine, o.transferID).ids
        run.onH = await SyncBench.userHolding(engine, holder).ids
        await engine.shutdown()
        for caller in callers {
            _ = await caller.value
        }
        _ = await oWaiter.value
        run.load = "\(loadBefore) -> \(SyncBench.loadAverages())"
        return run
    }

    /// A job of `count` ids that one prefetch group holds, each id also held by a user waiter of its own, and the index's
    /// own costs on it, each timed alone (Stage 3 close-out cycle 21, ruling S3-R26 item 3): `keepInterests` dropping the
    /// group on a copy (the copy's index is copied once, then 10,000 ids released), the group's release in place
    /// (`setInterest(nil)`, what `dropInterest` does), and the freeing of the job, its index with it.
    static func indexCosts(count: Int) -> IndexCostRun {
        var run = IndexCostRun()
        let loadBefore = SyncBench.loadAverages()
        let entry = SyncBench.entry("index-h", Data(repeating: 0x69, count: 16), policy: .onDemand)
        let ids = (0..<count).map { AssetID(String(format: "index-%05d", $0)) }
        var job: Job? = Job(transfer: entry.transferID, entry: entry, identity: entry.contentIdentity, assets: Set(ids), state: .queued, epoch: 1, queuedAt: MonotonicInstant(nanoseconds: 0))
        let group = InterestToken(rawValue: 1)
        job?.setInterest(JobInterest(lane: .prefetch, kind: .prefetch, assets: Set(ids)), for: group)
        for (index, id) in ids.enumerated() {
            job?.setInterest(JobInterest(lane: .userInitiated, kind: .waiter, assets: [id]), for: InterestToken(rawValue: UInt64(index) + 2))
        }
        run.indexedBefore = job?.tokensByID.count ?? 0
        let clock = ContinuousClock()
        var copy = job
        var started = clock.now
        copy?.keepInterests { token, _ in token != group }
        run.keepOnCopy = SyncBench.milliseconds(clock.now - started)
        run.copyIndexed = copy?.tokensByID.values.filter { $0.tokens.count == 1 }.count ?? 0
        copy = nil
        started = clock.now
        job?.setInterest(nil, for: group)
        run.release = SyncBench.milliseconds(clock.now - started)
        run.indexedAfter = job?.tokensByID.values.filter { $0.tokens.count == 1 }.count ?? 0
        started = clock.now
        job = nil
        run.free = SyncBench.milliseconds(clock.now - started)
        run.load = "\(loadBefore) -> \(SyncBench.loadAverages())"
        return run
    }

    /// A commit that binds and answers `count` ids (Stage 3 close-out cycle 21, ruling S3-R26 item 4;
    /// `integrate-c21.md` item C's pins): the ids share H's 16 bytes, one job, downloading (held), wanted as `shape`
    /// says, with `subscribers` subscribers that read nothing. H's download is released with the bulk executor holding,
    /// so its publication waits at its first store unit; then the unit is released, and the heartbeat times the turns
    /// until H's job is gone and every answer its commit owed is resumed (`commitUnanswered`), while the engine's seam
    /// times the commit's own turn inside the actor.
    static func commitTurn(count: Int, shape: CommitShape, subscribers: Int? = nil) async throws -> CommitRun {
        var run = CommitRun()
        let loadBefore = SyncBench.loadAverages()
        let held = try await SyncBench.heldPublicationBench()
        let engine = held.bench.engine
        let source = held.bench.source
        let bulk = held.bulk
        let hBytes = Data(repeating: 0x68, count: 16)
        let members = SyncBench.sharing(count, hBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData(members), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the second sync did not complete")
        }
        try await held.bench.store.flush(.ordered)
        let holder = members[0].transferID
        await source.script(holder, [.hold, .stage(hBytes)])
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        var groups: [InterestToken] = []
        switch shape {
        case .waiters, .waitersStalledSubscriber:
            for entry in members {
                let id = entry.identifier
                callers.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
            }
        case .groupStalledSubscriber:
            guard case .success(let token) = await engine.registerGroup(members.map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("the prefetch group was refused")
            }
            groups.append(token)
        case .manyGroups:
            for entry in members {
                guard case .success(let token) = await engine.registerGroup([entry.identifier], lane: .prefetch) else {
                    throw SyncBenchError.incomplete("a one-member prefetch group was refused")
                }
                groups.append(token)
            }
        }
        var spins = 0
        while !Task.isCancelled {
            let now = await SyncBench.userHolding(engine, holder)
            if now.ids == count, now.interests == shape.interests(count), await SyncBench.isRunning(engine, holder) {
                break
            }
            spins += 1
            if spins > 5_000_000 {
                throw SyncBenchError.incomplete("setup: H never held every id: \(now)")
            }
            await Task.yield()
        }
        let before = await SyncBench.userHolding(engine, holder)
        run.ids = before.ids
        run.interests = before.interests
        var subscriptions: [AsyncStream<AssetEvent>] = []
        for _ in 0..<(subscribers ?? shape.subscribers) {
            subscriptions.append(try await engine.subscribe().get())
        }
        await bulk.setHolding(true)
        await source.release(holder, with: .progress(received: 0, expected: nil))
        await bulk.waitForHeldUnits(atLeast: 1)
        await SyncBench.raiseOwnedTaskPriority(engine)
        let clock = CommitTurnClock()
        await SyncBench.markCommitTurns(engine) { ended in clock.mark(ended) }
        run.wait = try await SyncBench.longestWait(on: engine) {
            await bulk.setHolding(false)
            await bulk.releaseAll()
            while !Task.isCancelled, await SyncBench.commitUnanswered(engine, holder) {
                await bulk.releaseAll()
                await Task.yield()
            }
        }
        run.turn = clock.longest
        await SyncBench.markCommitTurns(engine, nil)
        run.committed = !(await SyncBench.jobExists(engine, holder))
        run.buffered = await engine.introspect().bufferedEvents
        withExtendedLifetime(subscriptions) {}
        var served = true
        for caller in callers {
            if case .success = await caller.value {
                continue
            }
            served = false
        }
        let answered = await SyncBench.groupsAnswered(engine, groups)
        run.served = served && answered
        await engine.shutdown()
        run.load = "\(loadBefore) -> \(SyncBench.loadAverages())"
        return run
    }

    /// Whether `transfer` has a job, or a resolution still owes its callers answers (`EngineState.owedAnswers`): a
    /// commit's window ends once its last caller is resumed, so the answer follow-ups' turns are timed under its
    /// heartbeat too (Stage 3 close-out cycle 21, ruling S3-R26 item 4's Phase 2, `integrate-c21.md` C12).
    static func commitUnanswered(_ engine: isolated SyncEngine, _ transfer: TransferID) -> Bool {
        engine.state.jobs[transfer] != nil || engine.state.owedAnswers.count > engine.state.owedAnswersHead
    }

    /// Sets or clears the commit turn's marks (`EngineState.commitTurnMarksForTests`).
    static func markCommitTurns(_ engine: isolated SyncEngine, _ marks: (@Sendable (Bool) -> Void)?) {
        engine.state.commitTurnMarksForTests = marks
    }

    /// Whether every one of `groups` has no member left to answer.
    static func groupsAnswered(_ engine: isolated SyncEngine, _ groups: [InterestToken]) -> Bool {
        groups.allSatisfy { engine.state.groups[$0]?.pending.isEmpty ?? true }
    }
}
