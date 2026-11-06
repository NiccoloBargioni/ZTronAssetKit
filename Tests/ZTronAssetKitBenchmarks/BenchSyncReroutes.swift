import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

/// The C2 pins of the bounded re-routes (Stage 3 close-out cycle 21, ruling S3-R26 item 1; `integrate-rr21.md`'s pins):
/// a commit whose re-routes do not fit its turn owes them as one batch, which the drain makes at most a drain turn's ids
/// (512) a turn. Each held turn is timed inside the actor (`releaseOneHeldFollowOrDrainTurn`), and the heartbeat covers
/// the commit, what happens while the batch is owed, and the drain's turns up to the last answer; each figure is printed
/// with the host's load averages (S3-R23).
extension ZTronAssetKitBenchmarks.SyncBenchmarks {
    /// C2 of a commit whose 10,000 moved-away ids v4 maps each to a content of its own (`SyncBench.commitReroute`,
    /// `.divergent`): the commit owes them as one batch and re-routes none in its own turn, and the drain makes them over
    /// 20 turns of at most 512 ids, each creating the jobs of its ids' contents. The best of three of the heartbeat and
    /// of the longest held turn against C2, after a warm-up.
    @Test("R-SYN-11: a commit that re-routes 10,000 ids each to a content of its own owes them, and the drain makes them holding the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func commitRerouteDivergentTurns() async throws {
        _ = try await SyncBench.commitReroute(count: 1_000, shape: .divergent)
        var runs: [CommitRerouteBenchRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.commitReroute(count: 10_000, shape: .divergent))
        }
        for run in runs {
            #expect(run.committed && run.served && run.madeAtCommit == 0 && run.batchesAtCommit == 1 && run.owedAtCommit == 10_000, "setup: the commit bound K, answered its waiter, re-routed none of the 10,000 ids and owed them as one batch: \(run)")
            #expect(run.made.count == 20 && run.made.allSatisfy { $0 <= 512 } && run.rerouted == 10_000 && run.violations.isEmpty, "setup: the drain made the batch in 20 turns of at most 512 ids, each id onto its content's job: \(run)")
        }
        let waits = runs.map(\.wait)
        let turns = runs.map(\.longestTurn)
        let commits = runs.map(\.commitTurn)
        print("R-SYN-11 commitRerouteDivergentTurns at 10,000: heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms; longest held turn \(turns) ms, best \(turns.min() ?? .infinity) ms; the commit's own turn \(commits) ms (budget \(Self.c2Budget) ms best); runs \(runs)")
        #expect((waits.min() ?? .infinity) <= Self.c2Budget, "the heartbeat: \(waits)")
        #expect((turns.min() ?? .infinity) <= Self.c2Budget, "the held turns: \(turns)")
    }

    /// C2 of owed re-routes onto a content the store holds (RR21-PRESENT-PRUNE's figure), for one prefetch group of the
    /// 10,000 ids: each member is answered present as the drain re-routes it, and D's content gets no job.
    @Test("R-SYN-11: owed re-routes of a 10,000-member group onto a present content are answered holding the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func groupMovedToBound() async throws {
        try await Self.commitRerouteTurns(.groupToBound, label: "a 10,000-member group moved onto a present content")
    }

    /// C2 of owed re-routes whose ids the copy no longer lists (T21), for a group and for user waiters: the drain ends
    /// each interest, 512 ids a turn, the group dropping its members in place (item C's C10) and each waiter answered
    /// `.notFound`.
    @Test("R-SYN-11: owed re-routes of 10,000 ids v4 dropped end their interests holding the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(10)), arguments: [CommitRerouteShape.delistedGroup, .delistedWaiters])
    @available(macOS 15.0, iOS 18.0, *)
    func groupDelistedAll(_ shape: CommitRerouteShape) async throws {
        try await Self.commitRerouteTurns(shape, label: "10,000 ids v4 dropped")
    }

    /// C2 of a commit at the fit edge for a 10,000-member prefetch group (`critic-commit-window.md`'s fit case, in the
    /// commit's turn): 255 of its members share H's content with K, and v4 drops them while H publishes, so K's location
    /// and the 255 re-routes fit `inboundIDsNow` and the commit's own turn ends the 255 interests (T21), the group
    /// dropping each member in place; its other 9,744 members wait on G's content.
    @Test("R-SYN-11: a commit that ends the interests of 255 delisted members of a 10,000-member group in its own turn holds the engine's actor at most C2's 10 ms", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func groupDelistedFit() async throws {
        try await Self.commitRerouteTurns(.delistedGroupFit, label: "255 delisted members of a 10,000-member group, at the fit edge")
    }

    /// C2 of a purge of everything while a 10,000-pair batch of prefetch re-routes waits (`withdrawPurgedJoins`' arm:
    /// `removeAll(where:)`, the sort of the removed items, and `dropGroupMember` for each).
    @Test("R-SYN-11: a purge while 10,000 re-routes are owed holds the engine's actor at most C2's 10 ms", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func purgeWhileOwedTurns() async throws {
        try await Self.commitRerouteTurns(.purgeWhileOwed, label: "a purge of everything while 10,000 re-routes are owed")
    }

    /// C2 of a commit at the fit edge (rr21-T1-fit's figure): K's location and `inboundIDsNow - 1` re-routes, each onto a
    /// content of its own, fit the commit's turn and are made in it; one more, and the commit owes them all, which one
    /// drain turn makes. Item C's `commitTurns` is re-measured after it.
    @Test("R-SYN-11: a commit at the fit edge re-routes at once or owes, holding the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func commitFitBoundaryTurns() async throws {
        let edge = SyncEngine.followIDsPerTurn / 2
        _ = try await SyncBench.commitReroute(count: edge - 1, shape: .divergent)
        var atOnce: [CommitRerouteBenchRun] = []
        var owing: [CommitRerouteBenchRun] = []
        for _ in 0..<3 {
            atOnce.append(try await SyncBench.commitReroute(count: edge - 1, shape: .divergent))
            owing.append(try await SyncBench.commitReroute(count: edge, shape: .divergent))
        }
        for run in atOnce {
            #expect(run.committed && run.served && run.batchesAtCommit == 0 && run.madeAtCommit == edge - 1 && run.violations.isEmpty, "setup: K's location and \(edge - 1) re-routes fit inboundIDsNow (\(edge)), and the commit makes them: \(run)")
        }
        for run in owing {
            #expect(run.committed && run.served && run.batchesAtCommit == 1 && run.owedAtCommit == edge && run.madeAtCommit == 0 && run.made == [edge] && run.rerouted == edge && run.violations.isEmpty, "setup: one more re-route passes inboundIDsNow, so the commit owes them all and one drain turn makes them: \(run)")
        }
        for (label, runs) in [("at once", atOnce), ("owed", owing)] {
            let waits = runs.map(\.wait)
            let turns = runs.map(\.longestTurn)
            let commits = runs.map(\.commitTurn)
            print("R-SYN-11 commitFitBoundaryTurns \(label): heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms; longest held turn \(turns) ms, best \(turns.min() ?? .infinity) ms; the commit's own turn \(commits) ms (budget \(Self.c2Budget) ms best); runs \(runs)")
            #expect((waits.min() ?? .infinity) <= Self.c2Budget, "\(label), the heartbeat: \(waits)")
            #expect((turns.min() ?? .infinity) <= Self.c2Budget, "\(label), the held turns: \(turns)")
        }
    }

    /// Runs `SyncBench.commitReroute` once at 1,000 ids and three times at 10,000, checks every run's setup
    /// (`CommitRerouteShape.setupIssues`), and gates the best of the three heartbeats, and of the three longest held
    /// turns, against C2.
    @available(macOS 15.0, iOS 18.0, *)
    static func commitRerouteTurns(_ shape: CommitRerouteShape, label: String) async throws {
        _ = try await SyncBench.commitReroute(count: 1_000, shape: shape)
        var runs: [CommitRerouteBenchRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.commitReroute(count: 10_000, shape: shape))
        }
        for run in runs {
            let issues = shape.setupIssues(run, count: 10_000)
            #expect(issues.isEmpty, "setup, \(shape.rawValue): \(issues); \(run)")
        }
        let waits = runs.map(\.wait)
        let turns = runs.map(\.longestTurn)
        let commits = runs.map(\.commitTurn)
        let during = runs.map(\.during)
        let lanes = runs.compactMap(\.lane)
        print("R-SYN-11 \(shape.rawValue), \(label), at 10,000: heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms; longest held turn \(turns) ms, best \(turns.min() ?? .infinity) ms; the commit's own turn \(shape.superseded ? "not timed inside the actor (an exit, no commit: the heartbeat covers it)" : "\(commits) ms"); while owed \(during) ms; followedLane \(lanes) ms (budget \(Self.c2Budget) ms best); runs \(runs)")
        #expect((waits.min() ?? .infinity) <= Self.c2Budget, "the heartbeat: \(waits)")
        #expect((turns.min() ?? .infinity) <= Self.c2Budget, "the held turns: \(turns)")
    }
}

/// The groupings of `SyncBench.commitReroute`: who wants the moved ids, where v4 maps them, and what happens while their
/// re-routes are owed.
enum CommitRerouteShape: String, Sendable, CaseIterable {
    /// Every moved id to a content of its own, one prefetch group of every id (`commitRerouteDivergentTurns`,
    /// `commitFitBoundaryTurns`).
    case divergent
    /// Every moved id to D's content (its download held), a user waiter per id, and 511 more user requests for moved ids
    /// that join behind the owed batch (`commitRerouteWaitersTurns`).
    case waiters
    /// A user waiter per id, which v4 keeps on H's content: the commit binds and answers them all and owes nothing
    /// (`commitWaitersBoundTurns`).
    case waitersBound
    /// Every moved id to D's content, two prefetch groups of every id (`commitTwoTokensTurns`).
    case twoTokens
    /// Every moved id to D's content, which the store holds (D's own id was fetched), a user waiter per id
    /// (`userMovedToBound`).
    case userToBound
    /// The same, one prefetch group of every id (`groupMovedToBound`).
    case groupToBound
    /// v4 drops every moved id, one prefetch group of every id (`groupDelistedAll`).
    case delistedGroup
    /// v4 drops every moved id, a user waiter per id (`groupDelistedAll`).
    case delistedWaiters
    /// 255 members on H's content, which v4 drops, and the group's other members on G's content (its download held),
    /// one prefetch group of K and every member: K's location and the 255 re-routes fit the commit's turn
    /// (`groupDelistedFit`).
    case delistedGroupFit
    /// Every moved id to D's content, one prefetch group; while the batch is owed, P's publication begins (its binding
    /// waits for the batch) and v5 and v6 are applied (`applyWhileOwedLayers`).
    case appliesWhileOwed
    /// Every moved id to D's content, one prefetch group; D's own id, wanted by a prefetch group of its own, downloads,
    /// and, while the batch is owed, v5 and v6 are applied and D's attempt ends in a 429 (`lane429WhileOwed`).
    case rateLimitWhileOwed
    /// Every moved id to D's content, one prefetch group; while the batch is owed, everything is purged, the manual clock
    /// moved past the deletion grace the store's purge waits out (`purgeWhileOwedTurns`).
    case purgeWhileOwed
    /// Every moved id to D's content (its download held), a user waiter per id, and K to a content of its own (E, its
    /// download held): no record wants H's bytes, so the store refuses H's publication (`.superseded`), and its exit
    /// owes every re-route, K's with the members' (site 3, `supersede`; `supersededUserTurns`).
    case supersededWaiters
    /// Every moved id to D's content (its download held), each a claim of a forced sync's run, which stays in flight:
    /// the commit owes the run's items (`runSuperseded`).
    case runMovedAway
    /// As `runMovedAway`, and K to a content of its own (E, its download held): the store refuses H's publication, and
    /// its exit owes every re-route (`runSuperseded`).
    case runSuperseded
    /// As `runMovedAway`, onto D's content, which the store holds (D's own id was fetched): each owed run item is
    /// answered present at the drain, its claim released and the asset counted fetched, the run's progress offered
    /// (`answerPresent`, `countRunFetched`, `offerRunProgress`; `runSuperseded`).
    case runToBound

    /// Whether every moved id has a user waiter; the run's shapes claim them for a run, the other shapes want them by
    /// prefetch groups.
    var waiters: Bool {
        self == .waiters || self == .waitersBound || self == .userToBound || self == .delistedWaiters || self == .supersededWaiters
    }

    /// Whether the moved ids are a forced sync's run's claims, on entries the run fetches.
    var run: Bool {
        self == .runMovedAway || self == .runSuperseded || self == .runToBound
    }

    /// Whether v4 maps K off H's content too, so that the store refuses H's publication (site 3).
    var superseded: Bool {
        self == .supersededWaiters || self == .runSuperseded
    }

    /// The prefetch groups of every id.
    var groups: Int {
        self.waiters || self.run ? 0 : (self == .twoTokens ? 2 : 1)
    }

    /// Whether the store holds D's content before H's commit.
    var present: Bool {
        self == .userToBound || self == .groupToBound || self == .runToBound
    }

    /// Whether the manifest lists D's own id.
    var listsD: Bool {
        self.present || self == .rateLimitWhileOwed
    }

    /// Whether v5 and v6 are applied while the batch is owed.
    var applies: Bool {
        self == .appliesWhileOwed || self == .rateLimitWhileOwed
    }

    /// What a run of `count` ids should have read and done, as the shape says; empty when it did.
    func setupIssues(_ run: CommitRerouteBenchRun, count: Int) -> [String] {
        var issues: [String] = []
        func need(_ held: Bool, _ what: String) {
            if !held {
                issues.append(what)
            }
        }
        if self.superseded {
            need(run.committed, "the store refused H's publication, and its exit ended H's job")
        } else {
            need(run.committed && run.served, "the commit bound K and answered its waiter")
        }
        need(run.violations.isEmpty, "no invariant violation")
        if self == .delistedGroupFit {
            need(run.batchesAtCommit == 0 && run.owedAtCommit == 0, "the commit owes nothing: K and the 255 re-routes fit its turn")
            need(run.pendingAtCommit == count - SyncEngine.followIDsPerTurn / 2, "the group waits for G's \(count - SyncEngine.followIDsPerTurn / 2) members only after the commit: \(run.pendingAtCommit)")
            return issues
        }
        if self == .waitersBound {
            need(run.batchesAtCommit == 0 && run.owedAtCommit == 0, "the commit owes nothing")
            need(run.answered == count, "the commit answers every waiter")
            return issues
        }
        let owed = count + (self.superseded ? 1 : 0)
        need(run.madeAtCommit == 0 && run.batchesAtCommit == 1 && run.owedAtCommit == owed, "the commit (or the exit) makes no re-route and owes the \(owed) ids as one batch")
        need(run.made.allSatisfy { $0 <= SyncEngine.followIDsPerTurn } && run.made.reduce(0, +) == run.owedBeforeDrain, "the drain makes the batch at most a drain turn's ids a turn")
        switch self {
        case .divergent, .waiters, .twoTokens, .appliesWhileOwed, .rateLimitWhileOwed, .supersededWaiters:
            need(run.rerouted == count, "every moved id ends on its v4 content's job")
        case .runMovedAway, .runSuperseded:
            need(run.rerouted == count && run.runOnHolder == nil && run.runOnTarget == count, "the run claims nothing on H and every moved id on D's job")
        case .runToBound:
            need(run.runFetched == count && run.runOnHolder == nil && run.runOnTarget == 0 && !run.targetJob, "the run counts every moved id fetched from the store, claims nothing on H or D, and D's content gets no job")
        case .userToBound:
            need(run.answered == count && !run.targetJob, "the store answers every waiter, and D's content gets no job")
        case .groupToBound:
            need(run.groupsAnswered && !run.targetJob, "the group is answered present, and D's content gets no job")
        case .delistedGroup:
            need(run.groupsAnswered, "the group stops waiting for every member")
        case .delistedWaiters:
            need(run.notFound == count, "every waiter is answered .notFound")
        case .delistedGroupFit:
            break
        case .purgeWhileOwed:
            need(run.owedBeforeDrain == 0 && run.groupsAnswered, "the purge withdraws every owed re-route, and the group stops waiting for its members")
        case .waitersBound:
            break
        }
        switch self {
        case .waiters:
            need(run.joinsBehind >= 511, "511 joins wait behind the batch")
        case .twoTokens:
            need(run.pairsAtCommit == 2 * count, "the batch owes two tokens an id")
        case .appliesWhileOwed:
            need(run.layers == [2] && run.publishing, "the batch has two layers, and P published at both applies")
        case .rateLimitWhileOwed:
            need(run.layers == [2] && run.throttled && run.lane != nil, "the batch has two layers, and D's 429 throttles the origin")
        default:
            break
        }
        return issues
    }
}

/// What `SyncBench.commitReroute` measured and read.
struct CommitRerouteBenchRun: CustomStringConvertible {
    /// The heartbeat's longest wait over the commit, over what happens while the batch is owed, and over the held turns
    /// after it, up to the last answer.
    var commit = 0.0
    var during = 0.0
    var drain = 0.0
    /// The commit's own turn, timed inside the actor.
    var commitTurn = 0.0
    /// Each held turn after the commit, timed inside the actor.
    var turns: [Double] = []
    /// The distinct ids each held turn re-routed, for the turns that re-routed any.
    var made: [Int] = []
    /// The moved ids the commit's own turn re-routed, the distinct ids and the pairs owed, and the batches after it.
    var madeAtCommit = 0
    var owedAtCommit = 0
    var pairsAtCommit = 0
    var batchesAtCommit = 0
    /// The distinct ids owed when the drain's turns were released.
    var owedBeforeDrain = 0
    /// The moved ids on their v4 contents' jobs at the end.
    var rerouted = 0
    /// Whether H's job was gone after the commit, and K's user waiter was answered with a location.
    var committed = false
    var served = false
    /// The moved ids' user waiters answered with a location, and with `.notFound`.
    var answered = 0
    var notFound = 0
    /// Whether every group had no member left to answer at the end.
    var groupsAnswered = false
    /// The members the groups still waited for after the commit (`.delistedGroupFit`).
    var pendingAtCommit = 0
    /// Whether D's content had a job after a held turn (`.userToBound`, `.groupToBound`, `.runToBound`).
    var targetJob = false
    /// The run's claims on H's job at the end (`nil`: none) and on D's, and the ids it counted fetched over the drain
    /// (the run's shapes).
    var runOnHolder: Int?
    var runOnTarget = 0
    var runFetched = 0
    /// The joins waiting behind the batch (`.waiters`).
    var joinsBehind = 0
    /// Each owed batch's layers before the replay, and whether P's job was in the layers' jobs at an attempt's end.
    var layers: [Int] = []
    var publishing = false
    /// The median of 21 `followedLane` calls on D's job while the batch was owed, in milliseconds, and whether the 429
    /// throttled the origin (`.rateLimitWhileOwed`).
    var lane: Double?
    var throttled = false
    /// The invariant violations after the commit and at the end.
    var violations: [String] = []
    /// The host's load averages before and after the run.
    var load = ""

    /// The heartbeat's longest wait over the whole window.
    var wait: Double {
        max(self.commit, self.during, self.drain)
    }

    /// The longest held turn, timed inside the actor.
    var longestTurn: Double {
        self.turns.max() ?? 0
    }

    var description: String {
        let ms = { (value: Double) in String(format: "%.2f", value) }
        return "heartbeat commit \(ms(self.commit)) ms, while owed \(ms(self.during)) ms, drain \(ms(self.drain)) ms; commit turn \(ms(self.commitTurn)) ms; \(self.turns.count) held turns, longest \(ms(self.longestTurn)) ms; made at the commit \(self.madeAtCommit), owed \(self.owedAtCommit) ids, \(self.pairsAtCommit) pairs in \(self.batchesAtCommit) batches, \(self.owedBeforeDrain) at the drain; made per turn \(self.made); re-routed \(self.rerouted); committed \(self.committed), served \(self.served), answered \(self.answered), notFound \(self.notFound), groups answered \(self.groupsAnswered), D's job \(self.targetJob), joins behind \(self.joinsBehind), run claims on H \(self.runOnHolder.map(String.init) ?? "none"), on D \(self.runOnTarget), fetched \(self.runFetched), layers \(self.layers), publishing \(self.publishing), followedLane \(self.lane.map(ms) ?? "-") ms, throttled \(self.throttled); violations \(self.violations.prefix(3)); load \(self.load)"
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    /// A commit that re-routes `count` moved-away ids (Stage 3 close-out cycle 21, ruling S3-R26 item 1;
    /// `integrate-rr21.md`'s pins at site 1): K and `count` members share H's 16 bytes, one job, downloading (held),
    /// wanted as `shape` says, K by a user waiter too. H's download is released with the bulk executor holding, so its
    /// publication waits at its first store unit; v4 maps the members as `shape` says and is applied, its follow ended.
    /// Then the follow's and the drain's turns are held, the unit is released, and the heartbeat times the turns until
    /// H's job is gone and every answer its commit owed is resumed (`SyncBench.commitUnanswered`), while the engine's
    /// seam times the commit's own turn inside the actor. What `shape` does while the
    /// batch is owed runs in a window of its own; then the held turns are released one at a time, each timed inside the
    /// actor, under the heartbeat, until the drain is over and, for `.userToBound`, the store answered every waiter.
    static func commitReroute(count: Int, shape: CommitRerouteShape) async throws -> CommitRerouteBenchRun {
        var run = CommitRerouteBenchRun()
        let loadBefore = SyncBench.loadAverages()
        var tuning = SyncTuning()
        // No preemption: a user download must not cancel D's or P's held attempt.
        tuning.preemptLowerLanes = false
        let held = try await SyncBench.heldPublicationBench(tuning: tuning)
        let engine = held.bench.engine
        let source = held.bench.source
        let store = held.bench.store
        let bulk = held.bulk
        let time = held.time
        let hBytes = Data(repeating: 0x68, count: 16)
        let dBytes = Data(repeating: 0x64, count: 16)
        let pBytes = Data(repeating: 0x70, count: 16)
        let kept = SyncBench.entry("k", hBytes, policy: .onDemand)
        // At the fit edge, K and H's members are `inboundIDsNow`; the group's other members share G's content.
        let onH = shape == .delistedGroupFit ? SyncEngine.followIDsPerTurn / 2 - 1 : count
        let members = SyncBench.sharing(onH, hBytes, policy: shape.run ? .standard : .onDemand)
        let gBytes = Data(repeating: 0x67, count: 16)
        let elsewhere = shape == .delistedGroupFit ? (0..<(count - 1 - onH)).map { SyncBench.entry(String(format: "g%05d", $0), gBytes, policy: .onDemand) } : []
        let d = SyncBench.entry("d", dBytes, policy: .onDemand)
        let p = SyncBench.entry("p", pBytes, policy: .onDemand)
        let extra = (shape.listsD ? [d] : []) + (shape == .appliesWhileOwed ? [p] : [])
        // K's own content where v4 maps K off H's (site 3).
        let own = SyncBench.entry("k", Data(repeating: 0x65, count: 17), policy: .onDemand)
        let holder = kept.transferID
        await source.scriptManifest([.fetched(SyncBench.manifestData([kept] + members + extra + elsewhere), etag: ETag(rawValue: "\"v2\""))])
        var runSync: Task<SyncOutcome, Never>?
        var spins = 0
        if shape.run {
            // The members are the claims of a forced sync's run, which stays in flight while H's download is held.
            await source.script(holder, [.hold, .stage(hBytes)])
            runSync = Task { await engine.sync(.force) }
            while !Task.isCancelled, (await SyncBench.runClaims(engine, on: holder) ?? 0) < onH {
                spins += 1
                if spins > 50_000_000 {
                    throw SyncBenchError.incomplete("setup: the run never claimed the members on H: \(String(describing: await SyncBench.runClaims(engine, on: holder)))")
                }
                await Task.yield()
            }
        } else {
            guard await engine.sync(.force).isComplete else {
                throw SyncBenchError.incomplete("the second sync did not complete")
            }
        }
        try await store.flush(.ordered)
        if shape.present {
            await source.script(d.transferID, [.stage(dBytes)])
            guard case .success = await engine.awaitAsset(d.identifier, lane: .userInitiated) else {
                throw SyncBenchError.incomplete("setup: D's content was not fetched")
            }
            try await store.flush(.ordered)
        }
        if !shape.run {
            await source.script(holder, [.hold, .stage(hBytes)])
        }
        switch shape {
        case .rateLimitWhileOwed:
            await source.script(d.transferID, [.hold, .fail(.transient(.throttled, retryAfter: nil))])
        case .appliesWhileOwed:
            await source.script(p.transferID, [.hold, .stage(pBytes)])
            await source.script(d.transferID, [.hold])
        case .waiters, .twoTokens, .purgeWhileOwed, .runMovedAway:
            await source.script(d.transferID, [.hold])
        case .supersededWaiters, .runSuperseded:
            await source.script(d.transferID, [.hold])
            await source.script(own.transferID, [.hold])
        case .delistedGroupFit:
            if let away = elsewhere.first {
                await source.script(away.transferID, [.hold])
            }
        case .divergent, .waitersBound, .userToBound, .groupToBound, .delistedGroup, .delistedWaiters, .runToBound:
            break
        }
        let waiter = Task { await engine.awaitAsset(kept.identifier, lane: .userInitiated) }
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        if shape.waiters {
            for entry in members {
                let id = entry.identifier
                callers.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
            }
        }
        var groups: [InterestToken] = []
        for _ in 0..<shape.groups {
            guard case .success(let token) = await engine.registerGroup(([kept] + members + elsewhere).map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("the prefetch group was refused")
            }
            groups.append(token)
        }
        var others: [TransferID] = []
        if shape == .rateLimitWhileOwed {
            guard case .success = await engine.registerGroup([d.identifier], lane: .prefetch) else {
                throw SyncBenchError.incomplete("D's prefetch group was refused")
            }
            others.append(d.transferID)
        }
        if let away = elsewhere.first {
            others.append(away.transferID)
        }
        var pWaiter: Task<Result<AssetLocation, AssetError>, Never>?
        if shape == .appliesWhileOwed {
            pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .userInitiated) }
            others.append(p.transferID)
        }
        let interests = shape.waiters ? count + 1 : 1 + shape.groups + (shape.run ? 1 : 0)
        spins = 0
        while !Task.isCancelled {
            let now = await SyncBench.userHolding(engine, holder)
            if now.ids == onH + 1, now.interests == interests, await SyncBench.isRunning(engine, holder), await SyncBench.allRunning(engine, others) {
                break
            }
            spins += 1
            if spins > 5_000_000 {
                throw SyncBenchError.incomplete("setup: H never held every id: \(now)")
            }
            await Task.yield()
        }
        await bulk.setHolding(true)
        await source.release(holder, with: .progress(received: 0, expected: nil))
        await bulk.waitForHeldUnits(atLeast: 1)
        guard let unit = await bulk.heldUnits.first else {
            throw SyncBenchError.incomplete("H's publication is not held at the store")
        }
        let releaser = SyncBench.releasing(bulk, except: unit)
        let moved: [ManifestEntry]
        let v4: [ManifestEntry]
        switch shape {
        case .divergent:
            moved = (0..<count).map { index in
                SyncBench.entry(String(format: "s%05d", index), GeneratedPayload.bytes(seed: 0x52_000 + UInt64(index), offset: 0, length: 16), policy: .onDemand)
            }
            v4 = [kept] + moved
        case .waitersBound:
            // v4 changes only an id nobody wants: every member stays on H's content.
            moved = []
            v4 = [kept] + members + [SyncBench.entry("zf", Data(repeating: 0x7A, count: 16), policy: .onDemand)]
        case .delistedGroup, .delistedWaiters:
            moved = []
            v4 = [kept]
        case .delistedGroupFit:
            moved = []
            v4 = [kept] + elsewhere
        case .waiters, .twoTokens, .userToBound, .groupToBound, .appliesWhileOwed, .rateLimitWhileOwed, .purgeWhileOwed:
            moved = SyncBench.sharing(count, dBytes)
            v4 = [kept] + moved + extra
        case .supersededWaiters:
            moved = SyncBench.sharing(count, dBytes)
            v4 = [own] + moved + extra
        case .runMovedAway, .runToBound:
            moved = SyncBench.sharing(count, dBytes, policy: .standard)
            v4 = [kept] + moved + extra
        case .runSuperseded:
            moved = SyncBench.sharing(count, dBytes, policy: .standard)
            v4 = [own] + moved + extra
        }
        if shape.run {
            // A forced sync would join the run in flight: v4 goes through the engine's apply path.
            let manifest = try ValidatedManifest(entries: v4, digest: ContentHash.sha256(of: Data("v4-\(shape.rawValue)-\(count)".utf8)))
            let applied = await engine.applyAndFollow(manifest, etag: nil, eviction: nil)
            guard case .success = applied else {
                throw SyncBenchError.incomplete("setup: v4 was not applied: \(applied)")
            }
        } else {
            await source.scriptManifest([.fetched(SyncBench.manifestData(v4), etag: ETag(rawValue: "\"v4\""))])
            // The sync ends with the engine (its run may wait for the re-routed downloads); only its apply matters here.
            _ = Task { await engine.sync(.force) }
        }
        spins = 0
        while !Task.isCancelled, !(shape.run ? await SyncBench.followAndDrainOver(engine) : await SyncBench.appliedAndFollowed(engine, etag: "\"v4\"")) {
            spins += 1
            if spins > 50_000_000 {
                throw SyncBenchError.incomplete("setup: v4 was never applied and followed: \(await SyncBench.followShape(engine))")
            }
            await Task.yield()
        }
        releaser.cancel()
        _ = await releaser.value
        await SyncBench.holdTurns(engine)
        await SyncBench.raiseOwnedTaskPriority(engine)
        let clock = CommitTurnClock()
        await SyncBench.markCommitTurns(engine) { ended in clock.mark(ended) }
        run.commit = try await SyncBench.longestWait(on: engine) {
            await bulk.setHolding(false)
            await bulk.releaseAll()
            while !Task.isCancelled, await SyncBench.commitUnanswered(engine, holder) {
                await bulk.releaseAll()
                await Task.yield()
            }
        }
        run.commitTurn = clock.longest
        await SyncBench.markCommitTurns(engine, nil)
        run.committed = !(await SyncBench.jobExists(engine, holder))
        let atCommit = await SyncBench.rerouteState(engine, moved)
        run.madeAtCommit = atCommit.made
        run.owedAtCommit = atCommit.owed
        run.batchesAtCommit = atCommit.batches
        run.pairsAtCommit = await SyncBench.owedPairs(engine)
        run.pendingAtCommit = await SyncBench.groupsPending(engine, groups)
        run.violations += atCommit.violations
        switch shape {
        case .waiters:
            // 511 more user requests for moved ids, which wait behind the owed batch as joins.
            for entry in members.prefix(511) {
                let id = entry.identifier
                callers.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
            }
            spins = 0
            while !Task.isCancelled, await SyncBench.joinsBehindReroutes(engine) < 511 {
                spins += 1
                if spins > 50_000_000 {
                    throw SyncBenchError.incomplete("setup: the joins never waited behind the batch: \(await SyncBench.followShape(engine))")
                }
                await Task.yield()
            }
            run.joinsBehind = await SyncBench.joinsBehindReroutes(engine)
        case .appliesWhileOwed:
            // P's publication begins and its binding waits for the owed re-routes (`inboundBlocks`), so P's job publishes
            // at both applies.
            await source.release(p.transferID, with: .progress(received: 0, expected: nil))
            spins = 0
            while !Task.isCancelled, !(await SyncBench.publishingNow(engine, p.transferID)) {
                spins += 1
                if spins > 50_000_000 {
                    throw SyncBenchError.incomplete("setup: P never published: \(await SyncBench.followShape(engine))")
                }
                await Task.yield()
            }
            run.during = try await SyncBench.longestWait(on: engine) {
                try await SyncBench.applyTwice(v4, engine: engine)
            }
            let layers = await SyncBench.owedLayers(engine)
            run.layers = layers.counts
            run.publishing = layers.ends.contains(p.transferID)
        case .rateLimitWhileOwed:
            run.during = try await SyncBench.longestWait(on: engine) {
                try await SyncBench.applyTwice(v4, engine: engine)
            }
            run.layers = await SyncBench.owedLayers(engine).counts
            run.lane = await SyncBench.followedLaneMedian(engine, d.transferID, calls: 21)
            let rateLimit = try await SyncBench.longestWait(on: engine) {
                await source.release(d.transferID, with: .progress(received: 0, expected: nil))
                while !Task.isCancelled, !(await SyncBench.throttledNow(engine)) {
                    await Task.yield()
                }
            }
            run.during = max(run.during, rateLimit)
            run.throttled = await SyncBench.throttledNow(engine)
        case .purgeWhileOwed:
            // The store's purge waits out the deletion grace of the blobs it dooms (`awaitReclaim`) on the bench's manual
            // clock, which a ticker moves to each next deadline while the purge runs.
            run.during = try await SyncBench.longestWait(on: engine) {
                let ticker = Task {
                    while !Task.isCancelled {
                        if let next = time.nextDeadline {
                            time.advance(to: next)
                        }
                        await Task.yield()
                    }
                }
                _ = await engine.purge(.all)
                ticker.cancel()
                _ = await ticker.value
            }
        case .divergent, .waitersBound, .twoTokens, .userToBound, .groupToBound, .delistedGroup, .delistedWaiters, .delistedGroupFit, .supersededWaiters, .runMovedAway, .runSuperseded, .runToBound:
            break
        }
        var owed = await SyncBench.owedReroutes(engine)
        run.owedBeforeDrain = owed
        let fetchedBefore = await SyncBench.runFetched(engine)
        var made: [Int] = []
        var targetJob = false
        run.drain = try await SyncBench.longestWait(on: engine) {
            run.turns = try await SyncBench.releaseTurnsUntilSettled(engine) { _ in
                let now = await SyncBench.owedReroutes(engine)
                if owed - now > 0 {
                    made.append(owed - now)
                }
                owed = now
                if shape.present, await SyncBench.jobExists(engine, d.transferID) {
                    targetJob = true
                }
            }
            if shape == .userToBound {
                // The window ends at the last answer: an owned task reads each waiter's location from the store.
                var waits = 0
                while !Task.isCancelled, await SyncBench.waitersLeft(engine) > 0 {
                    waits += 1
                    if waits > 50_000_000 {
                        throw SyncBenchError.incomplete("the store never answered every waiter: \(await SyncBench.waitersLeft(engine)) left")
                    }
                    await Task.yield()
                }
            }
        }
        run.made = made
        run.targetJob = targetJob
        if shape.run {
            run.runOnHolder = await SyncBench.runClaims(engine, on: holder)
            run.runOnTarget = await SyncBench.runClaims(engine, on: d.transferID) ?? 0
            run.runFetched = await SyncBench.runFetched(engine) - fetchedBefore
        }
        let end = await SyncBench.rerouteState(engine, moved)
        run.rerouted = end.made
        run.violations += end.violations
        run.groupsAnswered = await SyncBench.groupsAnswered(engine, groups)
        await engine.shutdown()
        if case .success = await waiter.value {
            run.served = true
        }
        for caller in callers.prefix(count) {
            switch await caller.value {
            case .success:
                run.answered += 1
            case .failure(.notFound):
                run.notFound += 1
            case .failure:
                break
            }
        }
        for caller in callers.dropFirst(count) {
            _ = await caller.value
        }
        _ = await pWaiter?.value
        _ = await runSync?.value
        run.load = "\(loadBefore) -> \(SyncBench.loadAverages())"
        return run
    }

    /// Releases every unit `bulk` holds but `unit`, as they come, until cancelled: the store's other work runs while one
    /// publication waits at its first unit.
    static func releasing(_ bulk: SteppedBlockingExecutor, except unit: Int) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                await bulk.waitForHeldUnits(atLeast: 2)
                for other in await bulk.heldUnits where other != unit {
                    await bulk.release(other)
                }
            }
        }
    }

    /// Applies v5 and v6, `v4` with an id nobody wants changed each time, through the engine's apply path while re-routes
    /// are owed: each apply adds a layer to every owed batch (`layerOwedReroutes`), and its follow, which owes no visit,
    /// ends in the apply's turn and makes the drain's first batch there. A forced sync would join v4's run, still in
    /// flight: a run settles only once the barrier is down (`checkRunSettled`).
    static func applyTwice(_ v4: [ManifestEntry], engine: SyncEngine) async throws {
        for round in 5...6 {
            let filler = SyncBench.entry("zf", Data(repeating: UInt8(round), count: 16), policy: .onDemand)
            let manifest = try ValidatedManifest(entries: v4 + [filler], digest: ContentHash.sha256(of: Data("v\(round)-while-owed".utf8)))
            let applied = await engine.applyAndFollow(manifest, etag: nil, eviction: nil)
            guard case .success = applied else {
                throw SyncBenchError.incomplete("setup: v\(round) was not applied: \(applied)")
            }
        }
    }

    /// Whether `transfer`'s job publishes (verifying or committing).
    static func publishingNow(_ engine: isolated SyncEngine, _ transfer: TransferID) -> Bool {
        engine.state.jobs[transfer].map { $0.state == .verifying || $0.state == .committing } ?? false
    }

    /// Whether every one of `transfers` has a job that runs.
    static func allRunning(_ engine: isolated SyncEngine, _ transfers: [TransferID]) -> Bool {
        transfers.allSatisfy { SyncBench.isRunning(engine, $0) }
    }

    /// The members `groups` still wait for, together.
    static func groupsPending(_ engine: isolated SyncEngine, _ groups: [InterestToken]) -> Int {
        groups.reduce(0) { total, token in total + (engine.state.groups[token]?.pending.count ?? 0) }
    }

    /// The distinct ids every waiting batch of re-routes owes.
    static func owedReroutes(_ engine: isolated SyncEngine) -> Int {
        var owed: Set<AssetID> = []
        for event in engine.state.eventsAfterFollow {
            if case .reroutes(let batch) = event {
                owed.formUnion(batch.items.elements.lazy.map(\.asset))
            }
        }
        return owed.count
    }

    /// The (id, token) pairs every waiting batch of re-routes owes.
    static func owedPairs(_ engine: isolated SyncEngine) -> Int {
        engine.state.eventsAfterFollow.reduce(0) { total, event in
            if case .reroutes(let batch) = event {
                return total + batch.items.count
            }
            return total
        }
    }

    /// Each waiting batch's layers, and the jobs at an attempt's end in any of them.
    static func owedLayers(_ engine: isolated SyncEngine) -> (counts: [Int], ends: Set<TransferID>) {
        var counts: [Int] = []
        var ends: Set<TransferID> = []
        for event in engine.state.eventsAfterFollow {
            if case .reroutes(let batch) = event {
                counts.append(batch.layers.count)
                for layer in batch.layers {
                    ends.formUnion(layer.ends.keys)
                }
            }
        }
        return (counts, ends)
    }

    /// The `.join` events that wait after the first waiting batch of re-routes.
    static func joinsBehindReroutes(_ engine: isolated SyncEngine) -> Int {
        let events = engine.state.eventsAfterFollow
        guard let first = events.firstIndex(where: { if case .reroutes = $0 { true } else { false } }) else {
            return 0
        }
        return events[(first + 1)...].count { if case .join = $0 { true } else { false } }
    }

    /// Whether a throttle of the origin is in force.
    static func throttledNow(_ engine: isolated SyncEngine) -> Bool {
        !engine.state.throttles.isEmpty
    }

    /// The engine's waiters still waiting.
    static func waitersLeft(_ engine: isolated SyncEngine) -> Int {
        engine.state.waiters.count
    }

    /// The run's claims on `transfer`'s job, `nil` when it claims none there (or no run is in flight).
    static func runClaims(_ engine: isolated SyncEngine, on transfer: TransferID) -> Int? {
        engine.state.run?.outstanding[transfer]?.count
    }

    /// The ids the run in flight counted fetched; 0 with none.
    static func runFetched(_ engine: isolated SyncEngine) -> Int {
        engine.state.run?.fetched ?? 0
    }

    /// Whether no follow is owed, no drain turn is scheduled and no apply is in flight.
    static func followAndDrainOver(_ engine: isolated SyncEngine) -> Bool {
        !engine.followBarrier && !engine.state.drainFollowUpScheduled && engine.state.appliesInFlight == 0
    }

    /// The `moved` entries whose content's job holds their id, the distinct ids owed, the waiting batches of re-routes,
    /// and the invariant violations.
    static func rerouteState(_ engine: isolated SyncEngine, _ moved: [ManifestEntry]) -> (made: Int, owed: Int, batches: Int, violations: [String]) {
        let made = moved.count { engine.state.jobs[$0.transferID]?.assets.contains($0.identifier) ?? false }
        let batches = engine.state.eventsAfterFollow.count { if case .reroutes = $0 { true } else { false } }
        return (made, SyncBench.owedReroutes(engine), batches, engine.invariantViolations())
    }
}
