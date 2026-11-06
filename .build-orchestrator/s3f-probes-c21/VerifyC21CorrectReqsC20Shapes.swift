import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

/// Cycle-20 requirements verifier's scratch C2 probes (not for commit). Two rows of the cycle-20 draft's C2 inventory
/// that have no figure ("put to the orchestrator"): `deferBehindVerdict`'s O(E) scan and insert per join, and `move`'s
/// sort of a holder's whole interests when the moved ids fit the turn.
@available(macOS 15.0, iOS 18.0, *)
struct VerifyC21CorrectReqsDeferRun: CustomStringConvertible {
    var applyWait = 0.0
    var turnsWait = 0.0
    var turns: [Double] = []
    var events: [Int] = []
    var joinsAtFollowEnd = 0
    var verdictWaited = false
    var answer = ""
    var purgeWait = -1.0
    var purgeBucket = 0
    var purgeQueue = 0
    var purgeAfterBucket = 0
    var purgeAfterQueue = 0
    var purgeTask: Task<Void, Never>?
    var violations: [String] = []
    var purgeDescription: String {
        "purge wait \(String(format: "%.2f", self.purgeWait)) ms (joins in buckets \(self.purgeBucket), in the queue \(self.purgeQueue) -> \(self.purgeAfterBucket), \(self.purgeAfterQueue)); violations \(self.violations.prefix(2))"
    }
    var description: String {
        let top = self.turns.enumerated().sorted { $0.element > $1.element }.prefix(3).map { "#\($0.offset)=\(String(format: "%.2f", $0.element)) ms (E \(self.events.indices.contains($0.offset) ? self.events[$0.offset] : -1))" }
        return "applyWait \(String(format: "%.2f", self.applyWait)) turnsWait \(String(format: "%.2f", self.turnsWait)) turns \(self.turns.count) max \(String(format: "%.2f", self.turns.max() ?? 0)) top \(top) maxE \(self.events.max() ?? 0) joinsAtFollowEnd \(self.joinsAtFollowEnd) verdictWaited \(self.verdictWaited) answer \(self.answer)"
    }
}

@available(macOS 15.0, iOS 18.0, *)
enum VerifyC21CorrectReqs {
    static func fillers(_ seed: UInt64) -> [ManifestEntry] {
        (0..<(SyncEngine.followFormatsPerTurn + 52)).map { SyncBench.entry(String(format: "f%05d", $0), GeneratedPayload.bytes(seed: seed + UInt64($0), offset: 0, length: 16), policy: .onDemand) }
    }

    static func eventCount(_ engine: isolated SyncEngine) -> Int {
        engine.state.eventsAfterFollow.count
    }

    static func joinsWaiting(_ engine: isolated SyncEngine) -> Int {
        // Cycle 21: a join deferred behind a waiting verdict waits in that verdict's bucket (`joinsBehindVerdicts`).
        engine.state.eventsAfterFollow.filter { if case .join = $0 { true } else { false } }.count
            + engine.state.joinsBehindVerdicts.values.reduce(0) { $0 + $1.count }
    }

    static func settled(_ engine: isolated SyncEngine) -> Bool {
        !engine.followBarrier && !engine.state.followFollowUpScheduled && !engine.state.drainFollowUpScheduled
    }

    static func owed(_ engine: isolated SyncEngine) -> Bool {
        engine.followOwed
    }

    static func hold(_ engine: isolated SyncEngine) {
        engine.holdFollowFollowUps()
        engine.holdDrainFollowUps()
    }

    /// PROBE-C21C-C20RSHAPE-DEFER-BEHIND-C2. 10,000 prefetch members share H's 16 bytes (one job, downloading, held); O (a user
    /// waiter) downloads, held, scripted to 404. v3 changes only the leading fillers, so the follow stays owed (its
    /// follow-ups held). O's 404 arrives: its verdict waits for the follow. v4 maps every member to O's content (and
    /// changes the fillers again): H's visit moves the 10,000 ids over the follow's bounded turns, and each join onto O's
    /// content, whose exit verdict waits, is deferred behind that verdict (`addInterest` -> `deferBehindVerdict`), which
    /// scans the waiting events from their end and inserts right after the verdict: O(E) a join. Every held follow and
    /// drain turn is timed inside the actor.
    static func bucketJoins(_ engine: isolated SyncEngine) -> Int {
        engine.state.joinsBehindVerdicts.values.reduce(0) { $0 + $1.count }
    }

    static func queueJoins(_ engine: isolated SyncEngine) -> Int {
        engine.state.eventsAfterFollow.filter { if case .join(let join) = $0 { !join.withdrawn } else { false } }.count
    }

    static func purgeEpoch(_ engine: isolated SyncEngine) -> UInt64 {
        engine.state.purgeEpoch
    }

    /// PROBE-C21C-PURGE-BUCKET / PROBE-C21C-PURGE-QUEUE-JOINS: `deferBehind`'s shape, with a `purge(.all)` once the joins
    /// behind O's waiting verdict reach `threshold` in its bucket (`.bucket`, the follow still owed) or once the follow
    /// ended and the drain's overflow left them as queue events (`.queue`): the purge's own turn withdraws every one
    /// (`withdrawPurgedJoins`), timed by the heartbeat from the purge's call until its withdrawal turn ran.
    enum PurgeAt: String, Sendable, CaseIterable {
        case bucket
        case queue
    }

    static func deferBehind(members count: Int) async throws -> VerifyC21CorrectReqsDeferRun {
        try await Self.deferBehind(members: count, purgeAt: nil)
    }

    static func deferBehind(members count: Int, purgeAt: PurgeAt?, threshold: Int = 9_000) async throws -> VerifyC21CorrectReqsDeferRun {
        let bench = try await SyncBench.followBench()
        let engine = bench.engine
        let source = bench.source
        let oBytes = Data(repeating: 0x6F, count: 16)
        let hBytes = Data(repeating: 0x68, count: 16)
        let o = SyncBench.entry("o", oBytes, policy: .onDemand)
        let members = SyncBench.sharing(count, hBytes)
        let fa = Self.fillers(0x51_000)
        await source.scriptManifest([.fetched(SyncBench.manifestData(fa + members + [o]), etag: ETag(rawValue: "\"v2\""))])
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
        await Self.hold(engine)
        let v3 = try ValidatedManifest(entries: Self.fillers(0x52_000) + members + [o], digest: ContentHash.sha256(of: Data("v3-defer-\(count)".utf8)))
        _ = await engine.applyAndFollow(v3, etag: nil, eviction: nil)
        guard await Self.owed(engine) else {
            throw SyncBenchError.incomplete("setup: v3's follow is not owed")
        }
        await source.release(o.transferID, with: .progress(received: 0, expected: nil))
        while !Task.isCancelled, !(await SyncBench.verdictWaits(engine, o.transferID)) {
            await Task.yield()
        }
        var run = VerifyC21CorrectReqsDeferRun()
        run.verdictWaited = await SyncBench.verdictWaits(engine, o.transferID)
        let v4 = try ValidatedManifest(entries: Self.fillers(0x53_000) + SyncBench.sharing(count, oBytes) + [o], digest: ContentHash.sha256(of: Data("v4-defer-\(count)".utf8)))
        await SyncBench.raiseOwnedTaskPriority(engine)
        run.applyWait = try await SyncBench.longestWait(on: engine) {
            _ = await engine.applyAndFollow(v4, etag: nil, eviction: nil)
        }
        var turns: [Double] = []
        var events: [Int] = []
        var spins = 0
        var followEnded = false
        run.turnsWait = try await SyncBench.longestWait(on: engine) {
            while !Task.isCancelled, !(await Self.settled(engine)) {
                if !followEnded, !(await Self.owed(engine)) {
                    followEnded = true
                    run.joinsAtFollowEnd = await Self.joinsWaiting(engine)
                }
                if let purgeAt, run.purgeWait < 0 {
                    let ready: Bool
                    switch purgeAt {
                    case .bucket:
                        let isOwed = await Self.owed(engine)
                        let joins = await Self.bucketJoins(engine)
                        ready = isOwed && joins >= threshold
                    case .queue:
                        let joins = await Self.queueJoins(engine)
                        ready = followEnded && joins >= threshold
                    }
                    if ready {
                        run.purgeBucket = await Self.bucketJoins(engine)
                        run.purgeQueue = await Self.queueJoins(engine)
                        let epoch = await Self.purgeEpoch(engine)
                        run.purgeWait = try await SyncBench.longestWait(on: engine) {
                            let purge = Task { _ = await engine.purge(.all) }
                            while !Task.isCancelled, await Self.purgeEpoch(engine) == epoch {
                                await Task.yield()
                            }
                            for _ in 0..<200 {
                                await Task.yield()
                            }
                            run.purgeTask = purge
                        }
                        run.purgeAfterBucket = await Self.bucketJoins(engine)
                        run.purgeAfterQueue = await Self.queueJoins(engine)
                    }
                }
                if let turn = await SyncBench.releaseOneHeldFollowOrDrainTurn(engine) {
                    turns.append(turn)
                    events.append(await Self.eventCount(engine))
                } else {
                    spins += 1
                    if spins > 50_000_000 {
                        throw SyncBenchError.incomplete("the follow and its drain never settled")
                    }
                    await Task.yield()
                }
            }
        }
        run.turns = turns
        run.events = events
        await SyncBench.releaseHeldTurns(engine)
        run.violations = await engine.invariantViolations()
        await engine.shutdown()
        let result = await waiter.value
        run.answer = "\(result)"
        _ = await run.purgeTask?.value
        return run
    }

    /// PROBE-C21C-C20RSHAPE-PARTIAL-MOVE-C2. `count` members share H's 16 bytes (one job, downloading, held), each with a user
    /// waiter (`users`) or all in one prefetch group; O (a user waiter) downloads, held. v3 maps the first `moved` members
    /// to O's content, the rest stay: H's visit moves `moved` ids, which fit the turn's ids, so it takes `move`, which sorts
    /// H's interests by token and each interest's whole ids before it re-routes the moved ones. The heartbeat times the
    /// apply's sync and its whole follow.
    static func partialMove(members count: Int, moved: Int, users: Bool) async throws -> (wait: Double, before: Int, interests: Int, onO: Int, onH: Int) {
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
        let before = await SyncBench.userHolding(engine, holder)
        let v3 = SyncBench.sharing(count, hBytes).enumerated().map { index, entry in index < moved ? SyncBench.entry(entry.identifier.rawValue, oBytes, policy: .onDemand) : entry }
        await SyncBench.raiseOwnedTaskPriority(engine)
        let wait = try await SyncBench.timedApply(bench, v3 + [o], tag: "v3-partial-\(users)-\(moved)-\(count)")
        let onO = await SyncBench.userHolding(engine, o.transferID).ids
        let onH = await SyncBench.userHolding(engine, holder).ids
        await engine.shutdown()
        for caller in callers {
            _ = await caller.value
        }
        _ = await oWaiter.value
        return (wait, before.ids, before.interests, onO, onH)
    }

    /// PROBE-C21C-C20RSHAPE-PARTIAL-MOVE-TURNS: `partialMove`'s shape with the follow's turns held. The apply's own wait (which
    /// runs the follow's first turn) and each later follow or drain turn are timed one by one, so the longest hold is
    /// attributed to the apply or to the turn of H's visit (`move`).
    static func partialMoveHeld(members count: Int, moved: Int, users: Bool) async throws -> (applyWait: Double, turns: [Double], onO: Int, onH: Int) {
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
        let manifest = try ValidatedManifest(entries: v3 + [o], digest: ContentHash.sha256(of: Data("v3-partial-held-\(users)-\(moved)-\(count)".utf8)))
        await Self.hold(engine)
        await SyncBench.raiseOwnedTaskPriority(engine)
        let applyWait = try await SyncBench.longestWait(on: engine) {
            _ = await engine.applyAndFollow(manifest, etag: nil, eviction: nil)
        }
        var turns: [Double] = []
        var turnSpins = 0
        while !Task.isCancelled, !(await Self.settled(engine)) {
            if let turn = await SyncBench.releaseOneHeldFollowOrDrainTurn(engine) {
                turns.append(turn)
            } else {
                turnSpins += 1
                if turnSpins > 50_000_000 {
                    throw SyncBenchError.incomplete("the follow and its drain never settled")
                }
                await Task.yield()
            }
        }
        await SyncBench.releaseHeldTurns(engine)
        let onO = await SyncBench.userHolding(engine, o.transferID).ids
        let onH = await SyncBench.userHolding(engine, holder).ids
        await engine.shutdown()
        for caller in callers {
            _ = await caller.value
        }
        _ = await oWaiter.value
        return (applyWait, turns, onO, onH)
    }
}

extension ZTronAssetKitBenchmarks {
    @Suite("VerifyC21CorrectReqsC2Probes", .serialized)
    struct VerifyC21CorrectReqsC2Probes {
        @Test("PROBE-C21C-C20RSHAPE-DEFER-BEHIND-C2", .timeLimit(.minutes(10)))
        @available(macOS 15.0, iOS 18.0, *)
        func deferBehindTurns() async throws {
            let warm = try await VerifyC21CorrectReqs.deferBehind(members: 1_000)
            print("PROBE-C21C-C20RSHAPE-DEFER-BEHIND-C2 warm-up 1,000: \(warm) load \(Self.load())")
            var runs: [VerifyC21CorrectReqsDeferRun] = []
            for index in 0..<3 {
                let before = Self.load()
                let run = try await VerifyC21CorrectReqs.deferBehind(members: 10_000)
                print("PROBE-C21C-C20RSHAPE-DEFER-BEHIND-C2 10,000 run \(index): \(run) load \(before) -> \(Self.load())")
                runs.append(run)
            }
            let best = runs.map { max($0.applyWait, $0.turnsWait) }.min() ?? .infinity
            let bestTurn = runs.map { $0.turns.max() ?? 0 }.min() ?? .infinity
            print("PROBE-C21C-C20RSHAPE-DEFER-BEHIND-C2 best heartbeat \(best) ms, best longest held turn \(bestTurn) ms (c2Budget \(SyncBenchmarks.c2Budget))")
            #expect(runs.allSatisfy { $0.verdictWaited && $0.joinsAtFollowEnd >= 10_000 }, "setup: \(runs)")
            #expect(bestTurn <= SyncBenchmarks.c2Budget, "longest held turn \(bestTurn) ms")
        }

        @Test("PROBE-C21C-PURGE-JOINS", .timeLimit(.minutes(15)), arguments: VerifyC21CorrectReqs.PurgeAt.allCases)
        @available(macOS 15.0, iOS 18.0, *)
        func purgeJoinsTurns(_ at: VerifyC21CorrectReqs.PurgeAt) async throws {
            let warm = try await VerifyC21CorrectReqs.deferBehind(members: 1_000, purgeAt: at, threshold: 800)
            print("PROBE-C21C-PURGE-JOINS \(at.rawValue) warm-up 1,000: \(warm.purgeDescription) load \(Self.load())")
            var waits: [Double] = []
            for index in 0..<3 {
                let before = Self.load()
                let run = try await VerifyC21CorrectReqs.deferBehind(members: 10_000, purgeAt: at)
                print("PROBE-C21C-PURGE-JOINS \(at.rawValue) 10,000 run \(index): \(run.purgeDescription); answer \(run.answer.prefix(60)) load \(before) -> \(Self.load())")
                #expect(run.purgeWait >= 0, "setup: the purge ran at the threshold: \(run)")
                #expect(run.violations.isEmpty, "invariants: \(run.violations.prefix(3))")
                waits.append(run.purgeWait)
            }
            print("PROBE-C21C-PURGE-JOINS \(at.rawValue): purge waits \(waits) ms, best \(waits.min() ?? -1) ms (c2Budget \(SyncBenchmarks.c2Budget))")
            #expect((waits.min() ?? .infinity) <= SyncBenchmarks.c2Budget, "\(waits)")
        }

        @Test("PROBE-C21C-C20RSHAPE-PARTIAL-MOVE-C2", .timeLimit(.minutes(10)), arguments: [false, true])
        @available(macOS 15.0, iOS 18.0, *)
        func partialMoveTurns(_ users: Bool) async throws {
            _ = try await VerifyC21CorrectReqs.partialMove(members: 1_000, moved: 500, users: users)
            var waits: [Double] = []
            for index in 0..<3 {
                let before = Self.load()
                let run = try await VerifyC21CorrectReqs.partialMove(members: 10_000, moved: 500, users: users)
                print("PROBE-C21C-C20RSHAPE-PARTIAL-MOVE-C2 users \(users) 10,000 moved 500 run \(index): \(run) load \(before) -> \(Self.load())")
                #expect(run.before == 10_000 && run.onO == 501 && run.onH == 9_500, "setup: \(run)")
                waits.append(run.wait)
            }
            print("PROBE-C21C-C20RSHAPE-PARTIAL-MOVE-C2 users \(users): waits \(waits) best \(waits.min() ?? .infinity) ms (c2Budget \(SyncBenchmarks.c2Budget))")
            #expect((waits.min() ?? .infinity) <= SyncBenchmarks.c2Budget, "\(waits)")
        }

        @Test("PROBE-C21C-C20RSHAPE-PARTIAL-MOVE-TURNS", .timeLimit(.minutes(10)), arguments: [false, true])
        @available(macOS 15.0, iOS 18.0, *)
        func partialMoveHeldTurns(_ users: Bool) async throws {
            _ = try await VerifyC21CorrectReqs.partialMoveHeld(members: 1_000, moved: 500, users: users)
            var longest: [Double] = []
            for index in 0..<3 {
                let before = Self.load()
                let run = try await VerifyC21CorrectReqs.partialMoveHeld(members: 10_000, moved: 500, users: users)
                let top = run.turns.enumerated().sorted { $0.element > $1.element }.prefix(3).map { "#\($0.offset)=\(String(format: "%.2f", $0.element))" }
                print("PROBE-C21C-C20RSHAPE-PARTIAL-MOVE-TURNS users \(users) 10,000 moved 500 run \(index): applyWait \(String(format: "%.2f", run.applyWait)) ms, \(run.turns.count) held turns, top \(top), onO \(run.onO) onH \(run.onH) load \(before) -> \(Self.load())")
                #expect(run.onO == 501 && run.onH == 9_500, "setup: \(run.onO) \(run.onH)")
                longest.append(max(run.applyWait, run.turns.max() ?? 0))
            }
            print("PROBE-C21C-C20RSHAPE-PARTIAL-MOVE-TURNS users \(users): longest \(longest) best \(longest.min() ?? .infinity) ms (c2Budget \(SyncBenchmarks.c2Budget))")
            #expect((longest.min() ?? .infinity) <= SyncBenchmarks.c2Budget, "\(longest)")
        }

        static func load() -> String {
            var loads = [Double](repeating: 0, count: 3)
            _ = getloadavg(&loads, 3)
            return loads.map { String(format: "%.2f", $0) }.joined(separator: " ")
        }
    }
}
