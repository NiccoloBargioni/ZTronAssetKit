import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

/// The purge's first turn at 10,000 ids (Stage 3 close-out cycle 22, ruling S3-R27 item 12.3, with item 12.5's 10 and
/// 11): the eleven gated cases, each its heartbeat, best of 3, against C2's 10 ms, with the purge's first turn timed
/// inside the actor and recorded (`EngineState.commitTurnMarksForTests`). `purgeWhileOwedTurns` is the twelfth, already
/// in the tree (`BenchSyncReroutes.swift`).
extension ZTronAssetKitBenchmarks.SyncBenchmarks {
    @Test("R-CLN-6: a purge's first turn over 10,000 ids holds the engine's actor at most C2's 10 ms", .timeLimit(.minutes(20)), arguments: PurgeShape.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func purgeTurns(_ shape: PurgeShape) async throws {
        _ = try await SyncBench.purgeTurn(count: 1_000, shape: shape)
        var runs: [PurgeRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.purgeTurn(count: 10_000, shape: shape))
        }
        for run in runs {
            #expect(run.jobsBefore == shape.jobs(10_000) && run.idsBefore == 10_000 && run.interestsBefore == shape.interests(10_000), "setup: \(run)")
            #expect(shape != .retryJobs || run.retrying == 10_000, "setup: every job waited for its retry: \(run)")
            #expect(run.purged && run.jobsAfter == (shape == .userWaiters || shape == .ensures ? 10_000 : 0) && run.violations.isEmpty, "\(run)")
            #expect(run.retriesAfter == 0, "no job's retry deadline is left (S3-R27 item 12.3, e2-A2.5): \(run)")
        }
        let waits = runs.map(\.wait)
        let turns = runs.map(\.turn)
        print("R-CLN-6 purgeTurns \(shape.rawValue) at 10,000: heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms (budget \(Self.c2Budget) ms best); the purge's first turn \(turns) ms, best \(turns.min() ?? .infinity) ms; runs \(runs)")
        #expect((waits.min() ?? .infinity) <= Self.c2Budget, "\(waits)")
    }

    @Test("R-CLN-6: a purge that withdraws 9,000 or more waiting joins holds the engine's actor at most C2's 10 ms", .timeLimit(.minutes(20)), arguments: PurgeJoinsAt.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func purgeJoinsTurns(_ at: PurgeJoinsAt) async throws {
        _ = try await SyncBench.purgeJoins(members: 1_000, at: at, threshold: 800)
        var runs: [PurgeJoinsRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.purgeJoins(members: 10_000, at: at, threshold: 9_000))
        }
        for run in runs {
            #expect(run.purged && run.liveBefore >= 9_000 && run.liveAfter == 0 && run.violations.isEmpty, "setup: the purge withdrew every waiting join: \(run)")
        }
        let waits = runs.map(\.wait)
        let turns = runs.map(\.turn)
        print("R-CLN-6 purgeJoinsTurns \(at.rawValue) at 10,000: heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms (budget \(Self.c2Budget) ms best); the purge's first turn \(turns) ms, best \(turns.min() ?? .infinity) ms; runs \(runs)")
        #expect((waits.min() ?? .infinity) <= Self.c2Budget, "\(waits)")
    }
}

/// The groupings of `SyncBench.purgeTurn` (ruling S3-R27 item 12.3's cases).
enum PurgeShape: String, Sendable, CaseIterable {
    /// (i) One prefetch group of every id, each id with its own content and job.
    case oneGroup
    /// (ii) One one-member prefetch group per id, each id with its own content and job.
    case oneMemberGroups
    /// (i) under a purge of a scope that names every id.
    case oneGroupScope
    /// The shared job at k = 1: every id shares one content, one prefetch group.
    case sharedJob
    /// The shared job at k = 4: four prefetch groups of every id.
    case sharedJobFourGroups
    /// k = 4 over 10,000 jobs: four prefetch groups of every id, each id with its own content and job.
    case fourGroups
    /// One prefetch group of every id, each id's job waiting for its retry after a timeout.
    case retryJobs
    /// A user waiter per id, each id with its own content and job: the purge keeps every job.
    case userWaiters
    /// An `ensureAvailable` of one id per id, each id with its own content and job: the purge keeps every job.
    case ensures

    /// The jobs the shape holds before the purge, for `count` ids.
    func jobs(_ count: Int) -> Int {
        self == .sharedJob || self == .sharedJobFourGroups ? 1 : count
    }

    /// The interests the shape's jobs hold before the purge, for `count` ids.
    func interests(_ count: Int) -> Int {
        switch self {
        case .oneGroup, .oneGroupScope, .retryJobs:
            return count
        case .oneMemberGroups, .userWaiters, .ensures:
            return count
        case .sharedJob:
            return 1
        case .sharedJobFourGroups:
            return 4
        case .fourGroups:
            return 4 * count
        }
    }

    /// The (interest, id) pairs the shape's jobs hold before the purge, for `count` ids: a group's registration joins its
    /// members over several turns, so the setup waits for every pair, not only for every interest.
    func pairs(_ count: Int) -> Int {
        self.groups == 4 ? 4 * count : count
    }

    /// The prefetch groups the shape registers over its ids.
    var groups: Int {
        switch self {
        case .oneGroup, .oneGroupScope, .retryJobs, .sharedJob:
            return 1
        case .sharedJobFourGroups, .fourGroups:
            return 4
        case .oneMemberGroups, .userWaiters, .ensures:
            return 0
        }
    }
}

/// What `SyncBench.purgeTurn` measured and read.
struct PurgeRun: CustomStringConvertible {
    /// The heartbeat's longest wait from the purge's call until its jobs are gone (or it returned, for user waiters).
    var wait = 0.0
    /// The purge's first turn, timed inside the actor.
    var turn = 0.0
    var jobsBefore = 0
    var idsBefore = 0
    var interestsBefore = 0
    /// The jobs that waited for a retry before the purge.
    var retrying = 0
    var jobsAfter = -1
    /// The `.retry` deadlines left on the heap after the purge (e2-A2.5's one pass takes the retired jobs' out).
    var retriesAfter = -1
    var purged = false
    var violations: [String] = []
    var load = ""

    var description: String {
        "heartbeat \(String(format: "%.2f", self.wait)) ms, turn \(String(format: "%.2f", self.turn)) ms; jobs \(self.jobsBefore) (ids \(self.idsBefore), interests \(self.interestsBefore), retrying \(self.retrying)) -> \(self.jobsAfter), retry deadlines left \(self.retriesAfter); purged \(self.purged); violations \(self.violations.prefix(2)); load \(self.load)"
    }
}

/// Where `SyncBench.purgeJoins` purges: while the joins wait behind O's verdict in its bucket, the follow still owed
/// (`bucket`), or once the follow ended and the drain left them as queue events (`queue`).
enum PurgeJoinsAt: String, Sendable, CaseIterable {
    case bucket
    case queue
}

/// What `SyncBench.purgeJoins` measured and read.
struct PurgeJoinsRun: CustomStringConvertible {
    var wait = 0.0
    var turn = 0.0
    /// The joins not withdrawn, in buckets and in the queue, before and after the purge.
    var liveBefore = 0
    var liveAfter = -1
    var bucketBefore = 0
    var queueBefore = 0
    var purged = false
    var violations: [String] = []
    var load = ""

    var description: String {
        "heartbeat \(String(format: "%.2f", self.wait)) ms, turn \(String(format: "%.2f", self.turn)) ms; live joins \(self.liveBefore) (bucket \(self.bucketBefore), queue \(self.queueBefore)) -> \(self.liveAfter); purged \(self.purged); violations \(self.violations.prefix(2)); load \(self.load)"
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    /// The `.retry` deadlines on the heap.
    static func retryDeadlines(_ engine: isolated SyncEngine) -> Int {
        engine.state.heap.entries.filter { deadline in
            if case .retry = deadline.reason {
                return true
            }
            return false
        }.count
    }

    /// The jobs, their ids, their interests and the jobs waiting for a retry.
    static func purgeCounts(_ engine: isolated SyncEngine) -> (jobs: Int, ids: Int, interests: Int, retrying: Int, pairs: Int) {
        let jobs = engine.state.jobs.values
        let retrying = jobs.filter { if case .failed(.at) = $0.state { true } else { false } }.count
        let pairs = jobs.reduce(0) { total, job in job.interests.values.reduce(total) { $0 + $1.assets.count } }
        return (jobs.count, jobs.reduce(0) { $0 + $1.assets.count }, jobs.reduce(0) { $0 + $1.interests.count }, retrying, pairs)
    }

    /// A purge over `count` ids in `shape` (ruling S3-R27 item 12.3): `scaleBench`'s engine (three attempts run and hold,
    /// the others wait in the queue), or, for the shared job, every id mapped to one content; the heartbeat times the
    /// purge from its call until every job is gone (until it returned, for user waiters, whose jobs stay); the purge's
    /// first turn is timed inside the actor.
    static func purgeTurn(count: Int, shape: PurgeShape) async throws -> PurgeRun {
        var run = PurgeRun()
        let loadBefore = SyncBench.loadAverages()
        let bench = try await SyncBench.scaleBench(members: count, room: nil)
        let engine = bench.engine
        var ids = bench.entries.map(\.identifier)
        if shape == .sharedJob || shape == .sharedJobFourGroups {
            let bytes = GeneratedPayload.bytes(seed: 0x11_000, offset: 0, length: bench.size)
            let entries = SyncBench.sharing(count, bytes)
            ids = entries.map(\.identifier)
            await bench.source.scriptManifest([.fetched(SyncBench.manifestData(entries), etag: ETag(rawValue: "\"v2\""))])
            guard await engine.sync(.force).isComplete else {
                throw SyncBenchError.incomplete("the shared manifest's sync did not complete")
            }
        }
        if shape == .retryJobs {
            for entry in bench.entries {
                await bench.source.script(entry.transferID, [.fail(.transient(.timedOut, retryAfter: nil)), .hold])
            }
        }
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        var ensures: [Task<Result<AvailabilityReport, AssetError>, Never>] = []
        switch shape {
        case .oneMemberGroups:
            for id in ids {
                guard case .success = await engine.registerGroup([id], lane: .prefetch) else {
                    throw SyncBenchError.incomplete("a one-member prefetch group was refused")
                }
            }
        case .userWaiters:
            for id in ids {
                callers.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
            }
        case .ensures:
            for id in ids {
                ensures.append(Task { await engine.ensureAvailable(scope: .identifiers([id])) })
            }
        case .oneGroup, .oneGroupScope, .retryJobs, .sharedJob, .sharedJobFourGroups, .fourGroups:
            for _ in 0..<shape.groups {
                guard case .success = await engine.registerGroup(ids, lane: .prefetch) else {
                    throw SyncBenchError.incomplete("the prefetch group was refused")
                }
            }
        }
        var spins = 0
        while !Task.isCancelled {
            let now = await SyncBench.purgeCounts(engine)
            if now.jobs == shape.jobs(count), now.ids == count, now.interests == shape.interests(count), now.pairs == shape.pairs(count), shape != .retryJobs || now.retrying == count {
                break
            }
            spins += 1
            if spins > 50_000_000 {
                throw SyncBenchError.incomplete("setup: the jobs never reached the shape: \(now)")
            }
            await Task.yield()
        }
        await engine.waitForAllHandles()
        let before = await SyncBench.purgeCounts(engine)
        (run.jobsBefore, run.idsBefore, run.interestsBefore, run.retrying) = (before.jobs, before.ids, before.interests, before.retrying)
        let request: PurgeRequest = shape == .oneGroupScope ? .scope(.identifiers(Set(ids))) : .all
        await SyncBench.raiseOwnedTaskPriority(engine)
        let clock = CommitTurnClock()
        await SyncBench.markCommitTurns(engine) { ended in clock.mark(ended) }
        var purged = false
        run.wait = try await SyncBench.longestWait(on: engine) {
            if case .success = await engine.purge(request) {
                purged = true
            }
            if shape == .userWaiters || shape == .ensures {
                for _ in 0..<200 {
                    await Task.yield()
                }
                return
            }
            var spins = 0
            while !Task.isCancelled, !(await SyncBench.noJobs(engine)) {
                spins += 1
                if spins > 50_000_000 {
                    throw SyncBenchError.incomplete("the purge never removed every job")
                }
                await Task.yield()
            }
        }
        run.turn = clock.longest
        await SyncBench.markCommitTurns(engine, nil)
        run.purged = purged
        run.jobsAfter = await SyncBench.purgeCounts(engine).jobs
        run.retriesAfter = await SyncBench.retryDeadlines(engine)
        run.violations = await SyncBench.violations(engine)
        await engine.shutdown()
        for caller in callers {
            _ = await caller.value
        }
        for ensure in ensures {
            _ = await ensure.value
        }
        run.load = "\(loadBefore) -> \(SyncBench.loadAverages())"
        return run
    }

    /// The waiting joins not withdrawn: in the verdicts' buckets and in the queue.
    static func liveJoins(_ engine: isolated SyncEngine) -> (bucket: Int, queue: Int) {
        let bucket = engine.state.joinsBehindVerdicts.values.reduce(0) { total, joins in
            total + joins.filter { !$0.join.withdrawn }.count
        }
        let queue = engine.state.eventsAfterFollow.filter { if case .join(let join) = $0 { !join.withdrawn } else { false } }.count
        return (bucket, queue)
    }

    /// The engine's purge epoch.
    static func purgeEpochNow(_ engine: isolated SyncEngine) -> UInt64 {
        engine.state.purgeEpoch
    }

    /// PURGE-JOINS' shape (the cycle-21 correctness verifier's PROBE-C21C-PURGE-JOINS; `deferBehind(.notFoundGroup)`):
    /// `count` prefetch members share H's 16 bytes (one job, downloading, held); O, a user waiter, downloads, held, and
    /// 404s while v3's follow is owed, so its verdict waits; v4 maps every member to O's content, and H's visit defers each
    /// join behind O's verdict. Once `threshold` joins wait in O's bucket (`bucket`), or in the queue after the follow
    /// ended (`queue`), `purge(.all)` withdraws them: the heartbeat times it from the call until its first turn ran.
    static func purgeJoins(members count: Int, at: PurgeJoinsAt, threshold: Int) async throws -> PurgeJoinsRun {
        var run = PurgeJoinsRun()
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
        await source.script(o.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        await source.script(holder, [.hold, .stage(hBytes)])
        let waiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        while !Task.isCancelled, !(await SyncBench.isRunning(engine, o.transferID)) {
            await Task.yield()
        }
        guard case .success = await engine.registerGroup(members.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, await SyncBench.holding(engine, holder).ids < count {
            await Task.yield()
        }
        await SyncBench.holdTurns(engine)
        let v3 = try ValidatedManifest(entries: SyncBench.leadingFillers(0x52_000) + members + [o], digest: ContentHash.sha256(of: Data("v3-purge-joins-\(count)".utf8)))
        _ = await engine.applyAndFollow(v3, etag: nil, eviction: nil)
        guard await SyncBench.followOwedNow(engine) else {
            throw SyncBenchError.incomplete("setup: v3's follow is not owed")
        }
        await source.release(o.transferID, with: .progress(received: 0, expected: nil))
        while !Task.isCancelled, !(await SyncBench.verdictWaits(engine, o.transferID)) {
            await Task.yield()
        }
        let v4 = try ValidatedManifest(entries: SyncBench.leadingFillers(0x53_000) + SyncBench.sharing(count, oBytes) + [o], digest: ContentHash.sha256(of: Data("v4-purge-joins-\(count)".utf8)))
        await SyncBench.raiseOwnedTaskPriority(engine)
        _ = await engine.applyAndFollow(v4, etag: nil, eviction: nil)
        var followEnded = false
        var spins = 0
        var purgeTask: Task<Bool, Never>?
        let clock = CommitTurnClock()
        while !Task.isCancelled, !(await SyncBench.turnsSettled(engine)) {
            if !followEnded, !(await SyncBench.followOwedNow(engine)) {
                followEnded = true
            }
            if purgeTask == nil {
                let live = await SyncBench.liveJoins(engine)
                let ready: Bool
                switch at {
                case .bucket:
                    ready = !followEnded && live.bucket >= threshold
                case .queue:
                    ready = followEnded && live.queue >= threshold
                }
                if ready {
                    run.bucketBefore = live.bucket
                    run.queueBefore = live.queue
                    run.liveBefore = live.bucket + live.queue
                    let epoch = await SyncBench.purgeEpochNow(engine)
                    await SyncBench.markCommitTurns(engine) { ended in clock.mark(ended) }
                    run.wait = try await SyncBench.longestWait(on: engine) {
                        purgeTask = Task {
                            if case .success = await engine.purge(.all) {
                                return true
                            }
                            return false
                        }
                        while !Task.isCancelled, await SyncBench.purgeEpochNow(engine) == epoch {
                            await Task.yield()
                        }
                        for _ in 0..<200 {
                            await Task.yield()
                        }
                    }
                    run.turn = clock.longest
                    await SyncBench.markCommitTurns(engine, nil)
                    let after = await SyncBench.liveJoins(engine)
                    run.liveAfter = after.bucket + after.queue
                }
            }
            if await SyncBench.releaseOneHeldFollowOrDrainTurn(engine) == nil {
                spins += 1
                if spins > 50_000_000 {
                    throw SyncBenchError.incomplete("the follow and its drain never settled")
                }
                await Task.yield()
            }
        }
        await SyncBench.releaseHeldTurns(engine)
        run.violations = await SyncBench.violations(engine)
        run.purged = await purgeTask?.value ?? false
        await engine.shutdown()
        _ = await waiter.value
        run.load = "\(loadBefore) -> \(SyncBench.loadAverages())"
        return run
    }
}
