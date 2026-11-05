import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The answers a large job's resolution owes past its own turn (Stage 3 close-out cycle 21, ruling S3-R26 item 4's
/// Phase 2; `integrate-c21.md` C12 with `critic-commit-window.md` A7, `design2-commit-window.md` T-A1 to T-A5): at
/// `answersPerTurn` 4, C's commit computes every answer of its job and takes every waiter out of the state in its own
/// turn, and the answer follow-ups resume the callers, four a turn, oldest first. Each test runs in both orders
/// (`LaneDropVisit`): C's publication is held while v4 changes only the fillers (`applyHeld`), so swept first the commit
/// lands with v4's follow owed, visited first after it; the answers are the same in both.
extension EngineFollowBarrierTests {
    /// What `owedAnswersSetUp` built: C's transfer, its ids and their callers, zz-o00's first.
    @available(macOS 15.0, iOS 18.0, *)
    struct OwedAnswersSetup {
        let s: FollowBarrier.Setup
        let x: TransferID
        let ids: [AssetID]
        let callers: [Task<Result<AssetLocation, AssetError>, Never>]
        /// Each caller's waiter token, read while the waiters were registered.
        let tokens: [AssetID: InterestToken]
        /// The `ensureAvailable` call for zz-o00 (`ensure`).
        let ensure: Task<Result<AvailabilityReport, AssetError>, Never>?

        var engine: SyncEngine {
            self.s.engine
        }
    }

    /// C (16 bytes) is shared by `count` ids zz-o00…, each with a user waiter, and, with `ensure`, by an
    /// `ensureAvailable` call for zz-o00 too; C's download ends and its publication is held at its first store unit while
    /// v4 changes only the fillers; the answer follow-ups are held, and the publication commits. Returns once C's job is
    /// gone, with the answers its commit owes still owed.
    @available(macOS 15.0, iOS 18.0, *)
    func owedAnswersSetUp(_ visit: LaneDropVisit, seed: UInt64, count: Int, ensure: Bool = false) async throws -> OwedAnswersSetup {
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        await engine.readForTests { $0.state.answersPerTurn = 4 }
        let bytes = EngineFixture.bytes(seed + 3, count: 16)
        let onC = (0..<count).map { EngineHarness.onDemand(String(format: "zz-o%02d", $0), bytes) }
        let x = try #require(onC.first).transferID
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + onC + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(x, [.hold, .stage(bytes)])
        let callers = onC.map { entry in
            let id = entry.identifier
            return Task { await engine.awaitAsset(id, lane: .userInitiated) }
        }
        let first = onC[0].identifier
        let ensureCall = ensure ? Task { await engine.ensureAvailable(scope: .identifiers([first])) } : nil
        let interests = count + (ensure ? 1 : 0)
        // The ensure's continuation is set after the pump that joins it, in the same turn, with no notification after
        // it: the wait reads the join, and the check below the continuation.
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                e.state.jobs[x]?.state == .downloading && e.state.jobs[x]?.interests.count == interests
                    && (!ensure || e.state.groups.values.contains { $0.kind == .ensure && $0.pending == [first: x] })
            }
        }
        let suspended = await engine.readForTests { e in e.state.groups.values.filter { $0.kind == .ensure && $0.continuation != nil }.count }
        try #require(suspended == (ensure ? 1 : 0), "setup: the ensure waits for zz-o00: \(suspended)")
        let tokens = await engine.readForTests { e in
            Dictionary(e.state.waiters.map { ($0.value.asset, $0.key) }, uniquingKeysWith: { first, _ in first })
        }
        let releaser = try await Self.holdPublication(of: x, s, bulk: bulk)
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + onC + Self.laterFillers(seed + 6_000), tag: "v4-owed-\(seed)", s, visit: visit)
        await engine.readForTests { $0.holdAnswerFollowUps() }
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        await engine.awaitCondition { $0.state.jobs[x] == nil }
        return OwedAnswersSetup(s: s, x: x, ids: onC.map(\.identifier), callers: callers, tokens: tokens, ensure: ensureCall)
    }

    /// The answers still owed, and whether an answer follow-up is scheduled.
    static func owedAnswersLeft(_ e: isolated SyncEngine) -> (left: Int, scheduled: Bool) {
        (e.state.owedAnswers.count - e.state.owedAnswersHead, e.state.answerFollowUp != nil)
    }

    /// Runs exactly one held answer follow-up, and holds the next one again.
    @available(macOS 15.0, iOS 18.0, *)
    static func runOneAnswerTurn(_ engine: SyncEngine) async {
        await engine.awaitCondition { $0.state.answerFollowUpWaiting }
        await engine.readForTests { e in
            e.releaseAnswerFollowUps()
            e.holdAnswerFollowUps()
        }
    }

    /// Releases the answer follow-ups and, swept first, the follow's, and waits for the follow and its drain to end.
    @available(macOS 15.0, iOS 18.0, *)
    static func releaseOwedAnswers(_ t: OwedAnswersSetup, _ visit: LaneDropVisit) async {
        await t.engine.readForTests { e in
            e.releaseAnswerFollowUps()
            e.releaseFollowFollowUps()
        }
        await t.engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
    }

    /// Every caller's bytes, `-1` for an error.
    @available(macOS 15.0, iOS 18.0, *)
    static func owedAnswerBytes(_ t: OwedAnswersSetup) async -> [Int64] {
        var bytes: [Int64] = []
        for caller in t.callers {
            let result = await EngineRegressionCycle6Tests.driving([t.s.time], fence: t.engine) { await EngineHarness.value(of: caller) }
            bytes.append((try? result.get())?.byteSize ?? -1)
        }
        return bytes
    }

    // MARK: T-A1: a large job's answers are owed and resumed a turn's worth a turn

    /// T-A1 (A1, A2): ten user waiters on C, at four answers a turn. The commit's turn owes the ten answers to a
    /// scheduled follow-up, which resumes four, then four, then two, each held turn read; the table is then empty and no
    /// follow-up is scheduled. Every caller gets C's bytes. Without the fit guard the commit's turn resumes all ten;
    /// with a follow-up that ignores the bound its first turn does.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a commit of more interests than a turn answers owes their answers and resumes them a turn's worth a turn (C2, T-A1)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitOwesALargeJobsAnswersAndResumesThemATurnsWorthATurn(_ visit: LaneDropVisit) async throws {
        let t = try await self.owedAnswersSetUp(visit, seed: 2_028_501, count: 10)
        let engine = t.engine
        let owed = await engine.readForTests { Self.owedAnswersLeft($0) }
        #expect(owed.left == 10 && owed.scheduled, "the commit's turn owes the ten answers to a scheduled follow-up: \(owed)")
        var left: [Int] = []
        for _ in 0..<3 {
            await Self.runOneAnswerTurn(engine)
            left.append(await engine.readForTests { Self.owedAnswersLeft($0).left })
        }
        #expect(left == [6, 2, 0], "the follow-ups resume four, four, then two: \(left)")
        let emptied = await engine.readForTests { e in e.state.owedAnswers.isEmpty && e.state.owedAnswersHead == 0 && e.state.answerFollowUp == nil }
        #expect(emptied, "the last follow-up empties the table and schedules none")
        await Self.releaseOwedAnswers(t, visit)
        #expect(await Self.owedAnswerBytes(t) == Array(repeating: 16, count: 10), "every caller gets C's bytes")
        await Self.finishHeld(t.s)
    }

    /// T-A1 with an `ensureAvailable` call (`deliver`'s ensure arm): four user waiters and the ensure's group share C,
    /// five interests at four a turn, so the commit owes the four answers and the settled ensure's resume, and the
    /// ensure answers zz-o00 present once its turn resumes it. An ensure resumed in the commit's turn leaves four owed.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a commit of more interests than a turn answers owes a settled ensure's resume with its waiters' answers (C2, T-A1)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitOwesASettledEnsuresResume(_ visit: LaneDropVisit) async throws {
        let t = try await self.owedAnswersSetUp(visit, seed: 2_028_511, count: 4, ensure: true)
        let engine = t.engine
        let owed = await engine.readForTests { e in
            (left: Self.owedAnswersLeft(e).left, ensures: e.state.owedAnswers.filter { if case .ensure = $0 { return true } else { return false } }.count)
        }
        #expect(owed.left == 5 && owed.ensures == 1, "the commit's turn owes the four answers and the ensure's resume: \(owed)")
        await Self.runOneAnswerTurn(engine)
        let afterFirst = await engine.readForTests { Self.owedAnswersLeft($0).left }
        #expect(afterFirst == 1, "the first follow-up resumes the four oldest: \(afterFirst) left")
        await Self.releaseOwedAnswers(t, visit)
        #expect(await Self.owedAnswerBytes(t) == Array(repeating: 16, count: 4), "every waiter gets C's bytes")
        let ensure = try #require(t.ensure)
        let answer = await EngineRegressionCycle6Tests.driving([t.s.time], fence: engine) { await EngineHarness.value(of: ensure) }
        let report = try? answer.get()
        #expect(report?.total == 1 && report?.present == 1 && report?.missing == 0 && report?.failed == 0, "the ensure answers zz-o00 present: \(answer)")
        await Self.finishHeld(t.s)
    }

    // MARK: T-A5: a job of a turn's answers is answered in its own turn

    /// T-A5 (A1's bound): four user waiters, at four answers a turn: the commit answers them in its own turn and owes
    /// nothing, no follow-up scheduled, so each caller gets C's bytes with the answer follow-ups held. A fit guard of
    /// `>=` owes the four.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a commit of as many interests as a turn answers answers them in its own turn (C2, T-A5)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitAnswersATurnsWorthOfInterestsInItsOwnTurn(_ visit: LaneDropVisit) async throws {
        let t = try await self.owedAnswersSetUp(visit, seed: 2_028_521, count: 4)
        let engine = t.engine
        let owed = await engine.readForTests { Self.owedAnswersLeft($0) }
        #expect(owed.left == 0 && !owed.scheduled, "the commit owes nothing: \(owed)")
        #expect(await Self.owedAnswerBytes(t) == Array(repeating: 16, count: 4), "every caller gets C's bytes, the answer follow-ups held")
        await Self.releaseOwedAnswers(t, visit)
        await Self.finishHeld(t.s)
    }

    // MARK: T-A3: the shutdown resumes the owed answers with their values

    /// T-A3 (A3): ten user waiters' answers owed, the follow-ups held, and the engine shuts down after `turns` of them
    /// (none: between the commit and its first follow-up; one, which resumed the four oldest: between two). The
    /// shutdown's drain resumes each answer still owed with the value the commit gave it, and none resumed before again,
    /// so every caller gets C's bytes, not `.shutDown`. A drain that drops them leaves their callers suspended until the
    /// time limit; one that drains from the table's start resumes the four twice.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: a shutdown while a commit's answers are owed answers the callers still owed with the commit's answers (T-A3)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, [0, 1])
    func shutdownAnswersTheOwedCallersWithTheCommitsAnswers(_ visit: LaneDropVisit, turns: Int) async throws {
        let t = try await self.owedAnswersSetUp(visit, seed: 2_028_531 + UInt64(turns), count: 10)
        let engine = t.engine
        for _ in 0..<turns {
            await Self.runOneAnswerTurn(engine)
        }
        let owed = await engine.readForTests { Self.owedAnswersLeft($0) }
        try #require(owed.left == 10 - 4 * turns && owed.scheduled, "setup: \(turns) follow-ups resumed four answers each, and the next is scheduled: \(owed)")
        await Self.finishHeld(t.s)
        let drained = await engine.readForTests { e in e.state.owedAnswers.isEmpty && e.state.owedAnswersHead == 0 && e.state.answerFollowUp == nil }
        #expect(drained, "the shutdown's drain empties the owed answers")
        #expect(await Self.owedAnswerBytes(t) == Array(repeating: 16, count: 10), "every caller gets C's bytes, not the shutdown")
    }

    // MARK: T-A2: a withdrawal while an answer is owed

    /// T-A2 (A4): ten user waiters' answers owed; zz-o05's caller is cancelled and its withdrawal made before any
    /// follow-up (`withdraw`, as its cancellation handler makes it): the waiter left the state at the commit, so the
    /// withdrawal finds nothing, and the caller gets C's bytes, as it did when the commit resumed it in its turn. A
    /// waiter kept registered until its resume would be cancelled here, then resumed again.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a caller cancelled while its answer is owed gets the commit's answer (T-A2)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func aCallerCancelledWhileItsAnswerIsOwedGetsTheCommitsAnswer(_ visit: LaneDropVisit) async throws {
        let t = try await self.owedAnswersSetUp(visit, seed: 2_028_541, count: 10)
        let engine = t.engine
        let index = 5
        let token = try #require(t.tokens[t.ids[index]], "setup: zz-o05's waiter token")
        let owed = await engine.readForTests { e in
            (owed: e.state.owedAnswers[e.state.owedAnswersHead...].contains { $0.token == token }, registered: e.state.waiters[token] != nil)
        }
        #expect(owed.owed && !owed.registered, "zz-o05's answer is owed and its waiter left the state at the commit: \(owed)")
        t.callers[index].cancel()
        let kept = await engine.readForTests { e in
            e.withdraw(token)
            return (owed: e.state.owedAnswers[e.state.owedAnswersHead...].contains { $0.token == token }, registered: e.state.waiters[token] != nil)
        }
        #expect(kept.owed && !kept.registered, "the withdrawal finds no waiter and leaves the answer owed: \(kept)")
        await Self.releaseOwedAnswers(t, visit)
        #expect(await Self.owedAnswerBytes(t) == Array(repeating: 16, count: 10), "every caller, the cancelled one too, gets C's bytes")
        await Self.finishHeld(t.s)
    }

    // MARK: T-A4: the owed answers' clause

    /// T-A4 (A5): ten user waiters' answers owed, the follow-ups held, and the clause broken three ways in turn, each
    /// expecting exactly its message: no follow-up scheduled while the engine runs, the head past the table, and an owed
    /// waiter registered again (whose missing interest the waiters' clause reports too). Each is restored before the
    /// next, and the callers get C's bytes.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: the invariants report owed answers with no follow-up, a head past them and an owed waiter still registered (T-A4)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func invariantsReportTheOwedAnswersOutOfStep(_ visit: LaneDropVisit) async throws {
        let t = try await self.owedAnswersSetUp(visit, seed: 2_028_551, count: 10)
        let engine = t.engine
        let x = t.x
        let id = try #require(t.ids.first)
        let clean = await engine.invariantViolations()
        try #require(clean.isEmpty, "setup: \(clean.prefix(3))")
        let unscheduled = await engine.readForTests { e -> [String] in
            let key = e.state.answerFollowUp
            e.state.answerFollowUp = nil
            defer { e.state.answerFollowUp = key }
            return e.invariantViolations()
        }
        #expect(unscheduled == ["10 answers are owed and no answer follow-up is scheduled"], "\(unscheduled)")
        let pastHead = await engine.readForTests { e -> [String] in
            let head = e.state.owedAnswersHead
            e.state.owedAnswersHead = e.state.owedAnswers.count + 1
            defer { e.state.owedAnswersHead = head }
            return e.invariantViolations()
        }
        #expect(pastHead == ["the owed answers' head 11 is past their 10"], "\(pastHead)")
        let (token, registered) = await engine.readForTests { e -> (InterestToken?, [String]) in
            guard let token = e.state.owedAnswers.first?.token else {
                return (nil, [])
            }
            e.state.waiters[token] = Waiter(asset: id, transfer: x, continuation: nil)
            defer { e.state.waiters[token] = nil }
            return (token, e.invariantViolations())
        }
        let owedToken = try #require(token, "setup: an owed answer")
        #expect(registered == ["waiter \(owedToken.rawValue) has no interest in \(x)", "owed answer \(owedToken.rawValue) has a registered waiter"], "\(registered)")
        await Self.releaseOwedAnswers(t, visit)
        #expect(await Self.owedAnswerBytes(t) == Array(repeating: 16, count: 10), "every caller gets C's bytes")
        await Self.finishHeld(t.s)
    }
}
