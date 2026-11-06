import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

/// The purge's in-letter shapes that had no gated case (Stage 3 close-out cycle 23, ruling S3-R28 item 3, from f3 §3.6
/// and its review's must-fix 3 and "must add" 1): each its heartbeat, best of 3, against C2's 10 ms, with the purge's
/// first turn timed inside the actor beside it (`EngineState.commitTurnMarksForTests`), at 10,000 ids with at most four
/// interests on an id.
extension ZTronAssetKitBenchmarks.SyncBenchmarks {
    @Test("R-CLN-6: a purge's first turn over the in-letter shapes at 10,000 ids holds the engine's actor at most C2's 10 ms", .timeLimit(.minutes(20)), arguments: InLetterPurgeShape.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func purgeInLetterTurns(_ shape: InLetterPurgeShape) async throws {
        _ = try await SyncBench.inLetterPurge(count: 1_000, shape: shape)
        var runs: [InLetterPurgeRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.inLetterPurge(count: 10_000, shape: shape))
        }
        for run in runs {
            #expect(run.setUp, "setup: \(run)")
            #expect(run.purged && run.violations.isEmpty && run.after == shape.after(10_000), "\(run)")
        }
        let waits = runs.map(\.wait)
        let turns = runs.map(\.turn)
        print("R-CLN-6 purgeInLetterTurns \(shape.rawValue) at 10,000: heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms (budget \(Self.c2Budget) ms best); the purge's first turn \(turns) ms, best \(turns.min() ?? .infinity) ms; runs \(runs)")
        #expect((waits.min() ?? .infinity) <= Self.c2Budget, "\(waits)")
    }
}

/// S3-R28 item 3's five in-letter purge shapes (10,000 ids; at most four interests on an id).
enum InLetterPurgeShape: String, Sendable, CaseIterable {
    /// A user waiter on each id plus three prefetch groups over every id, each id with its own content: the purge keeps
    /// every job, at the user lane (f3 §3.6).
    case keptUnderThreeGroups
    /// Four prefetch groups over members that share one job: 40,000 joins (four per id) wait behind a verdict for the
    /// follow when the purge withdraws them (f3 §3.6; `purgeJoinsTurns(.bucket)` with four groups).
    case fourGroupJoins
    /// Two groups over every id, each id with its own content, the first at `.prefetch` and the second at `.bulk`
    /// (f3 review must-fix 3, the mixed-lane shape).
    case mixedLaneGroups
    /// Two prefetch groups over every id, each id with its own content, the second registered just before the purge, so
    /// every member's claim is pending when it runs (f3 review must-fix 3, the pending-claims shape).
    case pendingClaimGroups
    /// Four one-member prefetch groups on each id, each id with its own content: 40,000 groups (f3 review "must add" 1).
    case oneMemberGroupsFourPerID

    /// The jobs left once the purge's work is done, for `count` ids: the kept user jobs, the claim-held jobs, or none.
    func after(_ count: Int) -> Int {
        switch self {
        case .keptUnderThreeGroups, .pendingClaimGroups:
            return count
        case .fourGroupJoins, .mixedLaneGroups, .oneMemberGroupsFourPerID:
            return -1
        }
    }
}

/// What `SyncBench.inLetterPurge` measured and read.
struct InLetterPurgeRun: CustomStringConvertible {
    /// The heartbeat's longest wait during the purge.
    var wait = 0.0
    /// The purge's first turn, timed inside the actor.
    var turn = 0.0
    /// Whether the shape was in place before the purge.
    var setUp = false
    /// What the shape held before the purge.
    var before = ""
    /// The jobs left after the purge (-1 where the shape waits for none: every job retired, or the joins' case).
    var after = -1
    var purged = false
    var violations: [String] = []
    var load = ""

    var description: String {
        "heartbeat \(String(format: "%.2f", self.wait)) ms, turn \(String(format: "%.2f", self.turn)) ms; before \(self.before); jobs after \(self.after); purged \(self.purged); violations \(self.violations.prefix(2)); load \(self.load)"
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    /// The (interest, id) pairs the job of `transfer` holds.
    static func inLetterHolderPairs(_ engine: isolated SyncEngine, _ transfer: TransferID) -> Int {
        engine.state.jobs[transfer]?.interests.values.reduce(0) { $0 + $1.assets.count } ?? 0
    }

    /// The registering turn of a prefetch group without its join (`recordGroup`): every member's claim is pending, as
    /// it is from `registerGroup`'s turn until the spawned join reaches the member.
    static func inLetterRecordGroup(_ engine: isolated SyncEngine, _ ids: [AssetID]) -> (token: InterestToken, members: [AssetID]) {
        engine.recordGroup(ids, lane: .prefetch)
    }

    /// The join `inLetterRecordGroup` left unspawned.
    static func inLetterSpawnJoin(_ engine: isolated SyncEngine, _ token: InterestToken, _ members: [AssetID]) {
        engine.spawnJoin(token, members: members, lane: .prefetch)
    }

    /// One purge over `count` ids in `shape`.
    static func inLetterPurge(count: Int, shape: InLetterPurgeShape) async throws -> InLetterPurgeRun {
        if shape == .fourGroupJoins {
            let joins = try await SyncBench.inLetterGroupJoins(members: count, groups: 4, threshold: count * 36 / 10)
            var run = InLetterPurgeRun()
            run.wait = joins.wait
            run.turn = joins.turn
            run.setUp = joins.liveBefore >= count * 36 / 10 && joins.liveAfter == 0
            run.before = "live joins \(joins.liveBefore) (bucket \(joins.bucketBefore), queue \(joins.queueBefore)) -> \(joins.liveAfter)"
            run.purged = joins.purged
            run.violations = joins.violations
            run.load = joins.load
            return run
        }
        var run = InLetterPurgeRun()
        let loadBefore = SyncBench.loadAverages()
        let bench = try await SyncBench.scaleBench(members: count, room: nil)
        let engine = bench.engine
        let ids = bench.entries.map(\.identifier)
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        let interests: Int
        switch shape {
        case .keptUnderThreeGroups:
            for id in ids {
                callers.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
            }
            for _ in 0..<3 {
                guard case .success = await engine.registerGroup(ids, lane: .prefetch) else {
                    throw SyncBenchError.incomplete("a prefetch group was refused")
                }
            }
            interests = 4 * count
        case .mixedLaneGroups:
            for lane in [AssetPriority.prefetch, .bulk] {
                guard case .success = await engine.registerGroup(ids, lane: lane) else {
                    throw SyncBenchError.incomplete("a group was refused")
                }
            }
            interests = 2 * count
        case .pendingClaimGroups:
            guard case .success = await engine.registerGroup(ids, lane: .prefetch) else {
                throw SyncBenchError.incomplete("the first prefetch group was refused")
            }
            interests = count
        case .oneMemberGroupsFourPerID:
            for id in ids {
                for _ in 0..<4 {
                    guard case .success = await engine.registerGroup([id], lane: .prefetch) else {
                        throw SyncBenchError.incomplete("a one-member prefetch group was refused")
                    }
                }
            }
            interests = 4 * count
        case .fourGroupJoins:
            throw SyncBenchError.incomplete("unreachable")
        }
        var spins = 0
        while !Task.isCancelled {
            let now = await SyncBench.purgeCounts(engine)
            if now.jobs == count, now.ids == count, now.interests == interests, now.pairs == interests {
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
        run.setUp = before.jobs == count && before.ids == count && before.interests == interests && before.pairs == interests
        run.before = "jobs \(before.jobs), ids \(before.ids), interests \(before.interests), pairs \(before.pairs)"
        var pending: (token: InterestToken, members: [AssetID])?
        if shape == .pendingClaimGroups {
            pending = await SyncBench.inLetterRecordGroup(engine, ids)
        }
        await SyncBench.raiseOwnedTaskPriority(engine)
        let clock = CommitTurnClock()
        await SyncBench.markCommitTurns(engine) { ended in clock.mark(ended) }
        var purged = false
        let keeps = shape.after(count) >= 0
        run.wait = try await SyncBench.longestWait(on: engine) {
            if case .success = await engine.purge(.all) {
                purged = true
            }
            if keeps {
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
        run.after = keeps ? await SyncBench.purgeCounts(engine).jobs : -1
        run.violations = await SyncBench.violations(engine)
        if let pending {
            await SyncBench.inLetterSpawnJoin(engine, pending.token, pending.members)
        }
        await engine.shutdown()
        for caller in callers {
            _ = await caller.value
        }
        run.load = "\(loadBefore) -> \(SyncBench.loadAverages())"
        return run
    }

    /// `purgeJoins(members:at: .bucket, threshold:)` with `groups` prefetch groups over the members, which share H's job:
    /// H's visit defers `groups` joins per member behind O's verdict, and once `threshold` of them wait in O's bucket
    /// while the follow is owed, `purge(.all)` withdraws them; the heartbeat times it from the call until its first turn
    /// ran.
    static func inLetterGroupJoins(members count: Int, groups: Int, threshold: Int) async throws -> PurgeJoinsRun {
        var run = PurgeJoinsRun()
        let loadBefore = SyncBench.loadAverages()
        let bench = try await SyncBench.followBench()
        let engine = bench.engine
        let source = bench.source
        let oBytes = Data(repeating: 0x6F, count: 16)
        let hBytes = Data(repeating: 0x68, count: 16)
        let o = SyncBench.entry("o", oBytes, policy: .onDemand)
        let members = SyncBench.sharing(count, hBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData(SyncBench.leadingFillers(0x61_000) + members + [o]), etag: ETag(rawValue: "\"v2\""))])
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
        for _ in 0..<groups {
            guard case .success = await engine.registerGroup(members.map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("a prefetch group was refused")
            }
        }
        while !Task.isCancelled, await SyncBench.inLetterHolderPairs(engine, holder) < groups * count {
            await Task.yield()
        }
        await SyncBench.holdTurns(engine)
        let v3 = try ValidatedManifest(entries: SyncBench.leadingFillers(0x62_000) + members + [o], digest: ContentHash.sha256(of: Data("v3-group-joins-\(count)".utf8)))
        _ = await engine.applyAndFollow(v3, etag: nil, eviction: nil)
        guard await SyncBench.followOwedNow(engine) else {
            throw SyncBenchError.incomplete("setup: v3's follow is not owed")
        }
        await source.release(o.transferID, with: .progress(received: 0, expected: nil))
        while !Task.isCancelled, !(await SyncBench.verdictWaits(engine, o.transferID)) {
            await Task.yield()
        }
        let v4 = try ValidatedManifest(entries: SyncBench.leadingFillers(0x63_000) + SyncBench.sharing(count, oBytes) + [o], digest: ContentHash.sha256(of: Data("v4-group-joins-\(count)".utf8)))
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
                if !followEnded && live.bucket >= threshold {
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
