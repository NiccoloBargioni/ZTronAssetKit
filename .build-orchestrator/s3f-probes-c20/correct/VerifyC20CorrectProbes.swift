import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 20, correctness lens). Never committed.
///
/// PROBE-C20C-DEFER-BEHIND: a follow's visit that moves ids onto a job whose exit verdict waits defers each join behind
/// that verdict (`deferBehindVerdict`), which scans the waiting events back to the verdict (`lastIndex`) and inserts the
/// join right after it (an O(E) shift), once per id: a turn of `followIDsPerTurn` ids costs O(ids x E), and E grows by
/// one per join deferred. Shape: T (zz-t0, zz-t1, 16 B, a user waiter each) downloads; H, `count` prefetch members of one
/// group sharing 16 B, downloads. v3 moves zz-t1 to a content of its own (T holds a moved id); T's attempt times out, so
/// its verdict waits (`waits`). v4 maps every H member to T's content: H's visit, over the follow's held turns, moves
/// 512 ids a turn onto T, each behind T's waiting verdict. Each held follow or drain turn is timed inside the actor.
/// The control (`waits == false`) leaves T downloading, so the same joins land on T in place.
///
/// PROBE-C20C-DRAIN-BOUND-ALL: the cycle-19 PROBE-C19C-DRAIN-BOUND shape, with the drain's follow-up turns held and
/// counted as well as the follow's (the cycle-19 probe counted the follow's turns and the drain turn only).
@Suite("VerifyC20Correct", .serialized)
struct VerifyC20Correct {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier
    typealias T = EngineFollowBarrierTests

    struct TurnFigure: CustomStringConvertible, Sendable {
        let kind: String
        let ms: Double
        let cpu: Double
        let eventsBefore: Int
        let eventsAfter: Int
        let hLeft: Int

        var description: String {
            "\(self.kind) \(String(format: "%.2f", self.ms))ms cpu \(String(format: "%.2f", self.cpu))ms E\(self.eventsBefore)->\(self.eventsAfter) H\(self.hLeft)"
        }
    }

    struct DeferRun: CustomStringConvertible, Sendable {
        var turns: [TurnFigure] = []
        var applyWait: Double = 0
        var peakJoinsOnT = 0
        var violations: [String] = []
        var t0Answer = ""

        var longestFollow: Double {
            self.turns.filter { $0.kind == "follow" }.map(\.ms).max() ?? 0
        }

        var longestFollowCPU: Double {
            self.turns.filter { $0.kind == "follow" }.map(\.cpu).max() ?? 0
        }

        var description: String {
            "apply window \(String(format: "%.2f", self.applyWait)) ms; longest follow turn \(String(format: "%.2f", self.longestFollow)) ms (thread CPU \(String(format: "%.2f", self.longestFollowCPU)) ms); peak joins waiting for T \(self.peakJoinsOnT); t0 \(self.t0Answer); violations \(self.violations.prefix(2)); turns \(self.turns)"
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func milliseconds(_ span: Duration) -> Double {
        Double(span.components.seconds) * 1_000 + Double(span.components.attoseconds) / 1e15
    }

    /// Releases exactly one held follow or drain turn, timed inside the actor, and holds the next ones again.
    @available(macOS 15.0, iOS 18.0, *)
    static func timedTurn(_ engine: SyncEngine, holder: TransferID) async -> TurnFigure {
        await engine.awaitCondition { $0.state.followFollowUpWaiting || $0.state.drainFollowUpWaiting }
        return await engine.readForTests { e in
            let before = e.state.eventsAfterFollow.count
            let follow = e.state.followFollowUpWaiting
            let clock = ContinuousClock()
            let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let start = clock.now
            if follow {
                e.releaseFollowFollowUps()
            } else {
                e.releaseDrainFollowUps()
            }
            let span = clock.now - start
            let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6
            e.holdFollowFollowUps()
            e.holdDrainFollowUps()
            return TurnFigure(kind: follow ? "follow" : "drain", ms: VerifyC20Correct.milliseconds(span), cpu: cpu, eventsBefore: before, eventsAfter: e.state.eventsAfterFollow.count, hLeft: e.state.jobs[holder]?.assets.count ?? 0)
        }
    }

    /// A heartbeat that calls into `engine` back to back while `work` runs; the longest wait in ms.
    @available(macOS 15.0, iOS 18.0, *)
    static func longestWait(on engine: SyncEngine, during work: () async throws -> Void) async throws -> Double {
        let heartbeat = Task(priority: .high) {
            let clock = ContinuousClock()
            var longest = Duration.zero
            while !Task.isCancelled {
                let before = clock.now
                _ = await engine.readForTests { $0.state.jobs.count }
                longest = max(longest, clock.now - before)
            }
            return longest
        }
        let outcome: Result<Void, any Error>
        do {
            try await work()
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        heartbeat.cancel()
        let longest = await heartbeat.value
        try outcome.get()
        return VerifyC20Correct.milliseconds(longest)
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func deferBehind(count: Int, waits: Bool, seed: UInt64) async throws -> DeferRun {
        let (s, _) = try await T.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let tBytes = EngineFixture.bytes(seed + 3, count: 16)
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let t1Own = EngineFixture.bytes(seed + 5, count: 18)
        let t0 = EngineHarness.onDemand("zz-t0", tBytes)
        let t1 = EngineHarness.onDemand("zz-t1", tBytes)
        let t1Moved = EngineHarness.onDemand("zz-t1", t1Own)
        let names = (0..<count).map { String(format: "zz-h%05d", $0) }
        let onH = names.map { EngineHarness.onDemand($0, hBytes) }
        let onT = names.map { EngineHarness.onDemand($0, tBytes) }
        let tTransfer = t0.transferID
        let hTransfer = try #require(onH.first?.transferID)
        try #require(t1.transferID == tTransfer && onT.first?.transferID == tTransfer && hTransfer != tTransfer && t1Moved.transferID != tTransfer, "setup: contents")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + onH + [t0, t1] + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let timeout = TransferError.transient(.timedOut, retryAfter: nil)
        await s.harness.source.script(tTransfer, [.hold, .fail(timeout), .stage(tBytes)])
        await s.harness.source.script(hTransfer, [.hold, .stage(hBytes)])
        await s.harness.source.script(t1Moved.transferID, [.stage(t1Own)])
        let w0 = Task { await engine.awaitAsset(t0.identifier, lane: .userInitiated) }
        let w1 = Task { await engine.awaitAsset(t1.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[tTransfer]?.state == .downloading && $0.state.jobs[tTransfer]?.interests.count == 2 }
        }
        let group = await engine.registerGroup(onH.map(\.identifier), lane: .prefetch)
        guard case .success = group else {
            Issue.record("setup: the group was refused: \(group)")
            return DeferRun()
        }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[hTransfer]?.assets.count == count && $0.state.jobs[hTransfer]?.state == .downloading }
        }
        try await T.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + onH + [t0, t1Moved] + T.laterFillers(seed + 6_000), tag: "v3-defer-\(count)-\(waits)-\(seed)", s, visit: .sweepFollowsFirst)
        if waits {
            await s.harness.source.release(tTransfer, with: .progress(received: 0, expected: nil))
            await engine.awaitCondition { $0.state.verdictsAfterFollow[tTransfer] != nil }
        }
        var run = DeferRun()
        let v4 = [s.q] + FollowBarrier.fillers(seed + 200) + onT + [t0, t1Moved] + T.laterFillers(seed + 6_000)
        run.applyWait = try await Self.longestWait(on: engine) {
            try await T.applyHeld(v4, tag: "v4-defer-\(count)-\(waits)-\(seed)", s, visit: .sweepFollowsFirst)
        }
        await engine.readForTests { $0.holdDrainFollowUps() }
        let joinsOnT: @Sendable (isolated SyncEngine) -> Int = { e in
            e.state.eventsAfterFollow.reduce(0) { sum, event in
                if case .join(let join) = event, join.entry.transferID == tTransfer {
                    return sum + 1
                }
                return sum
            }
        }
        while await engine.readForTests({ $0.followBarrier }) {
            try #require(run.turns.count < 400, "the follow and its drain end within 400 turns: \(run.turns.suffix(4))")
            run.peakJoinsOnT = max(run.peakJoinsOnT, await engine.readForTests(joinsOnT))
            run.turns.append(await Self.timedTurn(engine, holder: hTransfer))
        }
        await engine.readForTests { e in
            e.releaseFollowFollowUps()
            e.releaseDrainFollowUps()
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        run.violations = await engine.invariantViolations()
        await engine.shutdown()
        run.t0Answer = "\(await w0.value)"
        _ = await w1.value
        return run
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C20C-DEFER-BEHIND", .timeLimit(.minutes(10)), arguments: [true, false])
    func deferBehindTurns(_ waits: Bool) async throws {
        let count = Int(ProcessInfo.processInfo.environment["PROBE_C20C_COUNT"] ?? "") ?? 2_000
        let repeats = Int(ProcessInfo.processInfo.environment["PROBE_C20C_REPEATS"] ?? "") ?? 1
        var runs: [DeferRun] = []
        for index in 0..<repeats {
            let run = try await Self.deferBehind(count: count, waits: waits, seed: 2_020_501 + UInt64(index) * 10)
            print("PROBE-C20C-DEFER-BEHIND waits=\(waits) count=\(count) run \(index): \(run)")
            runs.append(run)
        }
        let longest = runs.map(\.longestFollow)
        let cpus = runs.map(\.longestFollowCPU)
        print("PROBE-C20C-DEFER-BEHIND waits=\(waits) count=\(count): longest follow turn per run \(longest) ms, best \(longest.min() ?? -1) ms; thread CPU per run \(cpus) ms; stride \(MemoryLayout<EventAfterFollow>.stride) B; load \(ProcessInfo.processInfo.environment["PROBE_LOAD"] ?? "?")")
        for run in runs {
            #expect(run.violations.isEmpty, "invariants: \(run.violations.prefix(3))")
            if waits {
                #expect(run.peakJoinsOnT >= count / 2, "setup: H's joins waited behind T's verdict: \(run.peakJoinsOnT)")
            }
        }
        #expect((longest.min() ?? .infinity) <= 10.0, "PROBE-C20C-DEFER-BEHIND: every follow turn at most C2's 10 ms: \(longest)")
    }

    // MARK: PROBE-C20C-DRAIN-BOUND-ALL

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C20C-DRAIN-BOUND-ALL", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, [3, 4])
    func drainBoundAllTurns(_ visit: LaneDropVisit, _ jobsCount: Int) async throws {
        let seed: UInt64 = 2_020_601 + UInt64(jobsCount)
        let perJob = 3
        let bound = 4
        let tuning = jobsCount == 3 ? SyncTuning() : SyncTuning(maxConcurrentTransfers: 12, reservedInteractiveSlots: 4)
        let (s, _) = try await T.setUpHeldPublications(seed: seed, tuning: tuning)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = bound }
        let jBytes = (0..<jobsCount).map { EngineFixture.bytes(seed + 3 + UInt64($0), count: 16) }
        var onJ: [ManifestEntry] = []
        var own: [ManifestEntry] = []
        var ownBytes: [Data] = []
        for k in 0..<jobsCount {
            for m in 0..<perJob {
                let name = String(format: "zz-j%d-m%d", k, m)
                onJ.append(EngineHarness.onDemand(name, jBytes[k]))
                let bytes = EngineFixture.bytes(seed + 10_000 + UInt64(k * 100 + m), count: 20)
                ownBytes.append(bytes)
                own.append(EngineHarness.onDemand(name, bytes))
            }
        }
        let jTransfers = (0..<jobsCount).map { onJ[$0 * perJob].transferID }
        try #require(Set(jTransfers).count == jobsCount && Set(own.map(\.transferID)).count == own.count, "setup: distinct contents")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + onJ + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let timeout = TransferError.transient(.timedOut, retryAfter: nil)
        for k in 0..<jobsCount {
            await s.harness.source.script(jTransfers[k], [.hold, .fail(timeout), .stage(jBytes[k])])
        }
        for (entry, bytes) in zip(own, ownBytes) {
            await s.harness.source.script(entry.transferID, [.stage(bytes)])
        }
        var waiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for entry in onJ {
            let id = entry.identifier
            waiters.append(Task { await engine.awaitAsset(id, lane: .prefetch) })
        }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                e.state.conditions != nil && jTransfers.allSatisfy { e.state.jobs[$0]?.state == .downloading && e.state.jobs[$0]?.interests.count == perJob }
            }
        }
        try await T.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + onJ + T.laterFillers(seed + 6_000), tag: "v3-drainall-\(seed)", s, visit: visit)
        for transfer in jTransfers {
            await s.harness.source.release(transfer, with: .progress(received: 0, expected: nil))
        }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { e in jTransfers.allSatisfy { e.state.verdictsAfterFollow[$0] != nil } }
        } else {
            await engine.awaitCondition { e in jTransfers.allSatisfy { e.state.jobs[$0]?.state != .downloading } }
        }
        let ids = onJ.map(\.identifier)
        let leftOn: @Sendable (isolated SyncEngine) -> Int = { e in
            ids.filter { id in jTransfers.contains { e.state.jobs[$0]?.assets.contains(id) == true } }.count
        }
        let atV4 = await engine.readForTests(leftOn)
        try await T.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + own + T.laterFillers(seed + 9_000), tag: "v4-drainall-\(seed)", s, visit: visit)
        var before = await engine.readForTests(leftOn)
        var turns: [Int] = [atV4 - before]
        var kinds: [String] = ["apply"]
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.holdDrainFollowUps() }
            while await engine.readForTests({ $0.followBarrier }) {
                try #require(turns.count < 60, "the follow and drain end within 60 turns: \(turns) \(kinds)")
                kinds.append((await T.runOneHeldTurn(engine)).rawValue)
                let now = await engine.readForTests(leftOn)
                turns.append(before - now)
                before = now
            }
            await engine.readForTests { e in
                e.releaseFollowFollowUps()
                e.releaseDrainFollowUps()
            }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        var answers: [Int64] = []
        for waiter in waiters {
            let result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) }
            answers.append((try? result.get())?.byteSize ?? -1)
        }
        let jStarts = await s.harness.source.starts.filter { jTransfers.contains($0.id) }.count
        print("PROBE-C20C-DRAIN-BOUND-ALL \(visit) jobs \(jobsCount) bound \(bound) atV4 \(atV4) turns \(turns) kinds \(kinds) answers \(answers) jStarts \(jStarts)")
        #expect(answers.allSatisfy { $0 == 20 }, "every member is served its own content's 20 bytes: \(answers)")
        #expect(jStarts == jobsCount, "each J starts once: \(jStarts)")
        #expect(visit != .sweepFollowsFirst || (turns.allSatisfy { $0 <= bound } && turns.reduce(0, +) == jobsCount * perJob), "PROBE-C20C-DRAIN-BOUND-ALL: every follow and drain turn moves at most \(bound) ids, all members moved: \(turns) \(kinds)")
        await T.finishHeld(s)
    }
    // MARK: PROBE-C20C-MANY-MOVES (scratch)

    /// PROBE-C20C-MANY-MOVES: `continueInbound` makes each owed move that fits the turn's ids with `move`, which sorts
    /// every interest's whole id set of the holder (`interest.assets.sorted()`) and mutates the holder's ids while the
    /// copy `holder` it was passed is alive, once per move. Owed moves off one holder onto many publications in flight
    /// (`bringInboundOntoPublications` at an apply while the follow owes the holder's visit) are one move per target, so a
    /// follow turn of up to `followsPerTurn` moves of one id each pays that per move. Shape: H, `count` prefetch members
    /// sharing one content, downloads (held); `moves` user waiters U_i on contents of their own publish, held at their
    /// first store unit. v3 maps H's first `moves` members each to one U_i's content (the follow is held, H not
    /// visited); v4 (the same mapping, another digest) is applied while H's visit is owed, so its walk finds one move off
    /// H per publication. Each held follow or drain turn is timed inside the actor.
    struct ManyMovesRun: CustomStringConvertible, Sendable {
        var turns: [TurnFigure] = []
        var publishing = 0
        var owedAfterV4 = 0
        var owedOffH = 0
        var hAfterV3 = 0
        var violations: [String] = []

        var longestFollow: Double {
            self.turns.filter { $0.kind == "follow" }.map(\.ms).max() ?? 0
        }

        var longestFollowCPU: Double {
            self.turns.filter { $0.kind == "follow" }.map(\.cpu).max() ?? 0
        }

        var description: String {
            "publishing \(self.publishing); H ids after v3 \(self.hAfterV3); owed moves after v4 \(self.owedAfterV4) (off H \(self.owedOffH)); longest follow turn \(String(format: "%.2f", self.longestFollow)) ms (thread CPU \(String(format: "%.2f", self.longestFollowCPU)) ms); violations \(self.violations.prefix(2)); turns \(self.turns.prefix(12))"
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func manyMoves(count: Int, moves k: Int, seed: UInt64) async throws -> ManyMovesRun {
        // No preemption: the user downloads must not cancel H's held attempt (its retry would stage and publish H).
        let (s, bulk) = try await T.setUpHeldPublications(seed: seed, tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 1, preemptLowerLanes: false))
        let engine = s.engine
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let names = (0..<count).map { String(format: "zz-h%05d", $0) }
        let onH = names.map { EngineHarness.onDemand($0, hBytes) }
        let uBytes = (0..<k).map { EngineFixture.bytes(seed + 1_000 + UInt64($0), count: 20 + $0 % 7) }
        let users = (0..<k).map { EngineHarness.onDemand(String(format: "zz-u%03d", $0), uBytes[$0]) }
        let movedH = (0..<count).map { index in index < k ? EngineHarness.onDemand(names[index], uBytes[index]) : onH[index] }
        let hTransfer = try #require(onH.first?.transferID)
        let userTransfers = users.map(\.transferID)
        try #require(Set(userTransfers).count == k && !userTransfers.contains(hTransfer) && (0..<k).allSatisfy { movedH[$0].transferID == userTransfers[$0] }, "setup: contents")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + onH + users, etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(hTransfer, [.hold, .hold, .hold, .stage(hBytes)])
        for (user, bytes) in zip(users, uBytes) {
            await s.harness.source.script(user.transferID, [.stage(bytes)])
        }
        let group = await engine.registerGroup(onH.map(\.identifier), lane: .prefetch)
        guard case .success = group else {
            Issue.record("setup: the group was refused: \(group)")
            return ManyMovesRun()
        }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[hTransfer]?.assets.count == count && $0.state.jobs[hTransfer]?.state == .downloading }
        }
        await engine.awaitCondition { !$0.state.storeWorkInFlight }
        await bulk.setHolding(true)
        let waiters = users.map { user in Task { await engine.awaitAsset(user.identifier, lane: .userInitiated) } }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in userTransfers.allSatisfy { e.state.jobs[$0]?.state == .verifying } }
        }
        try await bulk.requireHeldUnits(atLeast: k)
        let held = Set(await bulk.heldUnits)
        let releaser = Task {
            while !Task.isCancelled {
                await bulk.waitForHeldUnits(atLeast: held.count + 1)
                for other in await bulk.heldUnits where !held.contains(other) {
                    await bulk.release(other)
                }
            }
        }
        var run = ManyMovesRun()
        run.publishing = await engine.readForTests { e in userTransfers.filter { e.state.jobs[$0]?.state == .verifying }.count }
        // The fillers' contents change at each apply, so each apply's follow formats more than one turn's entries and
        // stays owed past the apply's turn (H, after them in the copy's order, is not visited yet).
        let v3 = [s.q] + FollowBarrier.fillers(seed + 200) + movedH + users
        let v4 = [s.q] + FollowBarrier.fillers(seed + 300) + movedH + users
        try await T.applyHeld(v3, tag: "v3-many-\(count)-\(k)-\(seed)", s, visit: .sweepFollowsFirst)
        run.hAfterV3 = await engine.readForTests { $0.state.jobs[hTransfer]?.assets.count ?? -1 }
        try await T.applyHeld(v4, tag: "v4-many-\(count)-\(k)-\(seed)", s, visit: .sweepFollowsFirst)
        (run.owedAfterV4, run.owedOffH) = await engine.readForTests { e in
            let owed = e.state.inboundMoves[e.state.inboundNext...]
            return (owed.count, owed.filter { $0.holder == hTransfer }.count)
        }
        await engine.readForTests { $0.holdDrainFollowUps() }
        while await engine.readForTests({ $0.followBarrier }) {
            try #require(run.turns.count < 200, "the follow and its drain end within 200 turns: \(run.turns.suffix(4))")
            run.turns.append(await Self.timedTurn(engine, holder: hTransfer))
        }
        await engine.readForTests { e in
            e.releaseFollowFollowUps()
            e.releaseDrainFollowUps()
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        run.violations = await engine.invariantViolations()
        releaser.cancel()
        _ = await releaser.value
        await bulk.setHolding(false)
        await bulk.releaseAll()
        await engine.shutdown()
        for waiter in waiters {
            _ = await waiter.value
        }
        return run
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C20C-MANY-MOVES", .timeLimit(.minutes(10)))
    func manyMovesTurns() async throws {
        let count = Int(ProcessInfo.processInfo.environment["PROBE_C20C_COUNT"] ?? "") ?? 2_000
        let repeats = Int(ProcessInfo.processInfo.environment["PROBE_C20C_REPEATS"] ?? "") ?? 1
        let movesList = (ProcessInfo.processInfo.environment["PROBE_C20C_MOVES"] ?? "1,16,64").split(separator: ",").compactMap { Int($0) }
        for moves in movesList {
            var runs: [ManyMovesRun] = []
            for index in 0..<repeats {
                let run = try await Self.manyMoves(count: count, moves: moves, seed: 2_020_701 + UInt64(index) * 10)
                print("PROBE-C20C-MANY-MOVES count=\(count) moves=\(moves) run \(index): \(run)")
                runs.append(run)
            }
            let longest = runs.map(\.longestFollow)
            let cpus = runs.map(\.longestFollowCPU)
            print("PROBE-C20C-MANY-MOVES count=\(count) moves=\(moves): longest follow turn per run \(longest) ms, best \(longest.min() ?? -1) ms; thread CPU per run \(cpus) ms; load \(ProcessInfo.processInfo.environment["PROBE_LOAD"] ?? "?")")
            for run in runs {
                #expect(run.violations.isEmpty, "invariants: \(run.violations.prefix(3))")
                #expect(run.publishing == moves && run.owedOffH == moves, "setup: one owed move off H per publication: \(run)")
            }
            #expect((longest.min() ?? .infinity) <= 10.0, "PROBE-C20C-MANY-MOVES moves=\(moves): every follow turn at most C2's 10 ms: \(longest)")
        }
    }
}

