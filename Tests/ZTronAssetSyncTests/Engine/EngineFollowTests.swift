import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

extension EngineSyncTests {
    /// The follow after an apply visits the jobs whose ids the copy's change moved, not the whole table (C2; Stage 3,
    /// S3-PERF-02), and still moves exactly what the whole-table walk moved: of a waiting prefetch group's members, the
    /// one whose content changed has its interest follow the new content (T22), the one the manifest dropped loses its
    /// job (T21), the others keep their jobs untouched; the engine's indexes then hold no job that the copy no longer
    /// maps to (`unfollowed` is empty and every invariant holds). An apply of the same manifest moves nothing.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: an apply moves only the jobs of the ids it changed and leaves every other waiting job as it was", .timeLimit(.minutes(1)))
    func applyFollowsOnlyMovedJobs() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 1))
        let members = (0..<6).map { EngineHarness.onDemand("f\($0)", EngineFixture.bytes(UInt64(6_300 + $0))) }
        try await EngineSingleFlightTests.applied(members, harness: harness)
        let engine = harness.engine
        for member in members {
            await harness.source.script(member.transferID, [.hold])
        }
        let group = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == members.count }
        let created = await engine.readForTests { $0.state.jobsCreated }
        let changed = EngineHarness.onDemand("f4", EngineFixture.bytes(6_399))
        let next = Array(members[0..<4]) + [changed]
        await harness.serveManifest(next, etag: "v2")
        let outcome = await engine.sync(.force)
        #expect(outcome.completeReport != nil, "\(outcome)")
        let after = await engine.readForTests { engine in
            (jobs: Set(engine.state.jobs.keys), created: engine.state.jobsCreated, unfollowed: engine.state.unfollowed, violations: engine.invariantViolations())
        }
        for member in members[0..<4] {
            #expect(after.jobs.contains(member.transferID), "\(member.identifier) keeps its job")
        }
        #expect(after.created == created + 1, "one job is created, for the changed member's new content: \(after.created - created)")
        #expect(!after.jobs.contains(members[4].transferID), "the changed member's old content is superseded")
        #expect(after.jobs.contains(changed.transferID), "its interest follows the new content")
        #expect(!after.jobs.contains(members[5].transferID), "the dropped member's job ends")
        #expect(after.unfollowed.isEmpty, "\(after.unfollowed)")
        #expect(after.violations.isEmpty, "\(after.violations)")
        // The same manifest again: nothing moves.
        await harness.serveManifest(next, etag: "v2b")
        _ = await engine.sync(.force)
        let again = await engine.readForTests { engine in (jobs: Set(engine.state.jobs.keys), created: engine.state.jobsCreated) }
        #expect(again.jobs == after.jobs && again.created == after.created, "an apply that changed nothing moved nothing")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    /// The follow after an apply is bounded per actor turn (C2; S3-R5; the cycle-1 verifier's PROBE-V9, 111 to 145 ms in
    /// one turn at 10,000): a manifest that changes the content of every member of a waiting prefetch group of
    /// `followFormatsPerTurn` + 100 members is followed over several turns. The first turn's pass stops at
    /// `followFormatsPerTurn` changed entries and visits `followsPerTurn` jobs; every later turn moves at most
    /// `followsPerTurn` jobs. Between turns every invariant holds (a job the follow still owes a visit is in
    /// `unfollowed`; one its pass has not reached follows the replaced copy), the run does not settle while visits are
    /// owed, and in the end every member's interest follows its new content with no job left on the old.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: an apply that moves more jobs than one turn takes follows them a bounded slice per turn with every invariant holding between turns", .timeLimit(.minutes(1)))
    func followIsBoundedPerTurn() async throws {
        let count = SyncEngine.followFormatsPerTurn + 100
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 1))
        let members = (0..<count).map { EngineHarness.onDemand(String(format: "t%04d", $0), EngineFixture.bytes(UInt64(64_000 + $0), count: 16)) }
        try await EngineSingleFlightTests.applied(members, harness: harness)
        let engine = harness.engine
        await harness.source.script(members[0].transferID, [.hold])
        let group = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count }
        let created = await engine.readForTests { $0.state.jobsCreated }
        let changed = members.enumerated().map { index, entry in
            EngineHarness.onDemand(entry.identifier.rawValue, EngineFixture.bytes(UInt64(164_000 + index), count: 16))
        }
        let old = Set(members.map(\.transferID))
        await harness.serveManifest(changed, etag: "v2")
        await engine.holdFollowFollowUps()
        let sync = Task { await engine.sync(.force) }
        var turns: [(moved: Int, scanned: Int?, owed: Bool, settled: Bool, violations: [String])] = []
        var movedBefore = 0
        // More jobs move than one turn takes, so the apply's turn leaves a follow-up owed; each released follow-up turn
        // leaves another or ends the follow.
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        while !Task.isCancelled {
            await engine.awaitCondition { $0.state.followFollowUpWaiting || !$0.followOwed }
            let turn = await engine.readForTests { engine in
                (
                    moved: Int(engine.state.jobsCreated - created),
                    scanned: engine.state.followScans.first?.next,
                    owed: engine.state.followFollowUpWaiting,
                    settled: engine.state.run?.settlement != nil,
                    violations: engine.invariantViolations()
                )
            }
            turns.append((turn.moved - movedBefore, turn.scanned, turn.owed, turn.settled, turn.violations))
            movedBefore = turn.moved
            guard turn.owed else {
                break
            }
            // One turn: the held follow-up runs, and the turn it schedules is held again.
            await engine.readForTests { engine in
                engine.releaseFollowFollowUps()
                engine.holdFollowFollowUps()
            }
        }
        await engine.releaseFollowFollowUps()
        let outcome = await EngineHarness.value(of: sync)
        #expect(outcome.completeReport != nil, "\(outcome)")
        let first = try #require(turns.first)
        #expect(first.scanned == SyncEngine.followFormatsPerTurn, "the first turn's pass stops at the format bound: \(String(describing: first.scanned))")
        #expect(first.moved == SyncEngine.followsPerTurn, "the first turn moves one slice: \(first.moved)")
        #expect(turns.count >= (count + SyncEngine.followsPerTurn - 1) / SyncEngine.followsPerTurn, "\(turns.count) turns")
        for (index, turn) in turns.enumerated() {
            #expect(turn.moved <= SyncEngine.followsPerTurn, "turn \(index) moved \(turn.moved) jobs")
            #expect(turn.violations.isEmpty, "turn \(index): \(turn.violations.prefix(3))")
            if turn.owed {
                #expect(!turn.settled, "turn \(index): the run settled while the follow owed visits")
            }
        }
        let after = await engine.readForTests { engine in
            (jobs: Set(engine.state.jobs.keys), created: engine.state.jobsCreated, unfollowed: engine.state.unfollowed, violations: engine.invariantViolations())
        }
        #expect(Int(after.created - created) == count, "one job per member's new content: \(after.created - created)")
        #expect(after.jobs.isDisjoint(with: old), "\(after.jobs.intersection(old).count) jobs left on the old content")
        #expect(after.jobs == Set(changed.map(\.transferID)), "every member's interest follows its new content")
        #expect(after.unfollowed.isEmpty, "\(after.unfollowed.count)")
        #expect(after.violations.isEmpty, "\(after.violations.prefix(3))")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    /// While a follow still owes visits, a job held for a manifest catch-up (the store superseded its publication before
    /// the engine's copy showed the new manifest, F-20) stays held when the last catch-up ends: it may be one the follow
    /// moves, and dispatching it first would start a transfer of content no id wants any more. The follow's last turn
    /// releases it. Jobs removed between two follow turns (here by the group's release) are skipped. The catch-up and
    /// the held job are set up directly in one engine turn, the order a superseded publication and an `apply` in flight
    /// leave, which no deterministic seam reaches end to end.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: a job held for a manifest catch-up stays held until the follow that may move it has ended", .timeLimit(.minutes(1)))
    func heldJobsWaitForTheFollow() async throws {
        let count = SyncEngine.followsPerTurn + 10
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 1))
        let members = (0..<count).map { EngineHarness.onDemand(String(format: "h%04d", $0), EngineFixture.bytes(UInt64(66_000 + $0), count: 16)) }
        try await EngineSingleFlightTests.applied(members, harness: harness)
        let engine = harness.engine
        await harness.source.script(members[0].transferID, [.hold])
        let group = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count }
        let changed = members.enumerated().map { index, entry in
            EngineHarness.onDemand(entry.identifier.rawValue, EngineFixture.bytes(UInt64(166_000 + index), count: 16))
        }
        let manifest = try ValidatedManifest(entries: changed, digest: ContentHash.sha256(of: Data("held-follow".utf8)))
        let held = members[count - 1].transferID
        let first = await engine.readForTests { engine -> (owed: Bool, held: Bool, violations: [String]) in
            engine.holdFollowFollowUps()
            engine.state.manifestCatchUps += 1
            engine.state.heldForManifest.insert(held)
            let previous = engine.state.applied
            engine.adoptApplied(manifest, etag: nil)
            engine.followApplied(from: previous)
            engine.manifestCaughtUp()
            return (engine.followOwed, engine.state.heldForManifest.contains(held), engine.invariantViolations())
        }
        #expect(first.owed, "the follow owes visits after its first turn")
        #expect(first.held, "the held job stays held while the follow is owed")
        #expect(first.violations.isEmpty, "\(first.violations.prefix(3))")
        // The group's release removes the jobs the follow still owes a visit; the follow's next turn skips them.
        await engine.releaseGroup(group)
        await engine.awaitCondition { $0.state.releasing.isEmpty }
        await engine.releaseFollowFollowUps()
        await engine.awaitCondition { !$0.followOwed }
        let after = await engine.readForTests { engine in (held: engine.state.heldForManifest, violations: engine.invariantViolations()) }
        #expect(after.held.isEmpty, "the follow's last turn released the held job: \(after.held)")
        #expect(after.violations.isEmpty, "\(after.violations.prefix(3))")
        await engine.shutdown()
    }
}


/// The failure of a replaced content that reaches the engine before the bounded follow visited its job (the close-out
/// cycle-2 correctness lens's PROBE-W4 and PROBE-W4b).
enum ReplacedContentFailure: String, CaseIterable, Sendable {
    /// The origin's 404: `failed(_:)` records the failure, then resolves every interest (`resolveAll`).
    case notFound
    /// A 503 at the user lane's attempt cap: `countFailedAttempt` answers the capped interests.
    case serverErrorAtCap
    /// ENOSPC for more bytes than the volume holds: `spaceFailed` parks the job and answers its waiters with the figures.
    case noSpace

    /// The attempt's terminal element.
    var update: TransferUpdate {
        switch self {
        case .notFound:
            return .failed(.permanentMissing(httpStatus: 404))
        case .serverErrorAtCap:
            return .failed(.transient(.serverError(httpStatus: 503), retryAfter: nil))
        case .noSpace:
            return .failed(.insufficientSpace(requiredBytes: 1 << 40))
        }
    }

    /// An engine whose attempt cap makes the failure terminal for the waiter (the default volume holds the new content,
    /// not the terabyte the ENOSPC asks for).
    @available(macOS 15.0, iOS 18.0, *)
    func harness() -> EngineHarness {
        switch self {
        case .serverErrorAtCap:
            var interactive = RetryPolicy.interactive
            interactive.maxAttemptsPerRun = 1
            return EngineHarness.make(tuning: SyncTuning(interactiveRetry: interactive))
        case .notFound, .noSpace:
            return EngineHarness.make()
        }
    }
}

extension EngineSyncTests {
    /// An id whose content an apply changed keeps its interest on the job of its replaced content until the bounded
    /// follow visits that job, up to many turns later at 10,000. A failure of that job's attempt arriving first is not
    /// that id's failure: the job is followed before it acts, so the waiter follows the id's new content and is
    /// answered from it, never `.notFound` (F-20: never `.notFound` while the asset is listed) nor the old content's
    /// failure. 600 ids, all changed; the last one's user waiter rides its old content's running transfer; the follow
    /// stops after its first turn (`holdFollowFollowUps()`, the turn ordering the network callback ahead of the
    /// follow-up, which production allows) with that job's visit still owed; then the transfer fails. Without the
    /// on-demand follow the waiter was answered `failure(notFound)` (the 404), the 503's error, or the ENOSPC figures
    /// (the close-out cycle-2 correctness lens, PROBE-W4).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: a failure of an id's replaced content before its follow visit answers the id's waiter from its new content", .timeLimit(.minutes(1)), arguments: ReplacedContentFailure.allCases)
    func replacedContentFailureFollowsTheWaiter(_ failure: ReplacedContentFailure) async throws {
        let count = 600
        let harness = failure.harness()
        let v1 = (0..<count).map { EngineHarness.onDemand(String(format: "y%04d", $0), EngineFixture.bytes(UInt64(240_000 + $0), count: 16)) }
        try await EngineSingleFlightTests.applied(v1, harness: harness)
        let engine = harness.engine
        let target = v1[count - 1]
        let group = try await engine.registerGroup(v1.dropLast().map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count - 1 }
        await harness.source.script(target.transferID, [.hold])
        let waiter = Task { await engine.awaitAsset(target.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[target.transferID]?.state == .downloading }
        await engine.waitForHandle(target.transferID)
        let v2 = v1.enumerated().map { index, entry in
            EngineHarness.onDemand(entry.identifier.rawValue, EngineFixture.bytes(UInt64(290_000 + index), count: 16))
        }
        let replacement = v2[count - 1]
        await harness.source.script(replacement.transferID, [.stage(EngineFixture.bytes(UInt64(290_000 + count - 1), count: 16))])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest(v2, etag: "v2")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        let before = await engine.readForTests { engine in
            (
                listed: engine.state.applied.entry(for: target.identifier)?.transferID == replacement.transferID,
                old: engine.state.jobs[target.transferID]?.state,
                owed: engine.state.unfollowed.contains(target.transferID)
            )
        }
        #expect(before.listed && before.old == .downloading && before.owed, "the copy lists the id at its new content and the old job still downloads, its visit owed: \(before)")
        await harness.source.release(target.transferID, with: failure.update)
        // The old job ends (followed, or answered) or, without the follow, parks for lack of space.
        await engine.awaitCondition { engine in
            switch engine.state.jobs[target.transferID]?.state {
            case nil, .blocked?:
                return true
            default:
                return false
            }
        }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let outcome = await EngineHarness.value(of: sync)
        #expect(outcome.completeReport != nil, "\(outcome)")
        let answer = await EngineHarness.value(of: waiter)
        #expect((try? answer.get()) != nil, "the waiter of a listed id is answered from its new content: \(answer)")
        #expect(await harness.source.starts.map(\.id).contains(replacement.transferID), "the id's new content was fetched")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    /// The prefetch-member form of `replacedContentFailureFollowsTheWaiter`, for a job the follow's pass has not reached
    /// yet: the member whose old content's transfer runs is the last entry of the replaced copy, past the first turn's
    /// `followFormatsPerTurn` comparisons, so no visit is even owed for it when its transfer answers 404. The member
    /// follows its new content (the group waits for that job) instead of being settled by the old content's failure
    /// (the close-out cycle-2 correctness lens, PROBE-W4b's shape with the hold seam).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: a 404 for a prefetch member's replaced content before the follow's pass reached it moves the member to its new content", .timeLimit(.minutes(1)))
    func replacedContentFailureFollowsTheMember() async throws {
        let count = SyncEngine.followFormatsPerTurn + 64
        let harness = EngineHarness.make()
        // The target sorts first, so the group's first dispatch starts it, and is listed last, so the pass reaches it last.
        let others = (1..<count).map { EngineHarness.onDemand(String(format: "p%04d", $0), EngineFixture.bytes(UInt64(440_000 + $0), count: 16)) }
        let target = EngineHarness.onDemand("a0000", EngineFixture.bytes(440_000, count: 16))
        let v1 = others + [target]
        try await EngineSingleFlightTests.applied(v1, harness: harness)
        let engine = harness.engine
        await harness.source.script(target.transferID, [.hold])
        let group = try await engine.registerGroup(v1.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count && $0.state.jobs[target.transferID]?.state == .downloading }
        await engine.waitForHandle(target.transferID)
        let v2 = v1.enumerated().map { index, entry in
            EngineHarness.onDemand(entry.identifier.rawValue, EngineFixture.bytes(UInt64(490_000 + index), count: 16))
        }
        let replacement = v2[count - 1]
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest(v2, etag: "v2")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        let unreached = await engine.readForTests { engine in
            !engine.state.unfollowed.contains(target.transferID) && engine.unscannedFollowEntries()[target.identifier] != nil
        }
        #expect(unreached, "the follow's pass has not reached the member when its old content fails")
        await harness.source.release(target.transferID, with: .failed(.permanentMissing(httpStatus: 404)))
        await engine.awaitCondition { $0.state.jobs[target.transferID] == nil }
        let after = await engine.readForTests { engine in
            (
                pending: engine.state.groups.values.compactMap { $0.pending[target.identifier] },
                new: engine.state.jobs[replacement.transferID]?.interests.isEmpty == false,
                old: engine.state.jobs[target.transferID]?.state,
                violations: engine.invariantViolations()
            )
        }
        #expect(after.pending == [replacement.transferID], "the member waits for its new content: \(after.pending)")
        #expect(after.new, "the new content's job holds the member's interest")
        #expect(after.old == nil, "the old content's job is gone: \(String(describing: after.old))")
        #expect(after.violations.isEmpty, "\(after.violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let outcome = await EngineHarness.value(of: sync)
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    /// Between two turns of a bounded follow, the jobs of replaced content the follow still owes a visit (or its pass has
    /// not reached) stay queued with their old tickets, ahead of the new content's jobs. No pump starts them: a transfer
    /// of content no id of the applied copy wants is never requested after the apply (the cycle-1 one-turn follow
    /// abandoned them in the apply's turn). 700 members whose content all changed, two slots; the follow-up is held so
    /// the drains' and freed slots' pumps run between the follow's turns. Without the check each pump started replaced
    /// content (the close-out cycle-2 correctness lens, PROBE-W1: two of two starts, PROBE-W1b: 44 of 48 at 3,000).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: no transfer of a replaced content starts after the apply while a bounded follow still owes its job", .timeLimit(.minutes(1)))
    func noReplacedContentStartsDuringTheFollow() async throws {
        let count = 700
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0))
        let v1 = (0..<count).map { EngineHarness.onDemand(String(format: "w%04d", $0), EngineFixture.bytes(UInt64(40_000 + $0), count: 16)) }
        try await EngineSingleFlightTests.applied(v1, harness: harness)
        let engine = harness.engine
        let group = try await engine.registerGroup(v1.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count && $0.state.inFlight.count == 2 }
        let before = await harness.source.starts.count
        let old = Set(v1.map(\.transferID))
        let v2 = v1.enumerated().map { index, entry in
            EngineHarness.onDemand(entry.identifier.rawValue, EngineFixture.bytes(UInt64(90_000 + index), count: 16))
        }
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest(v2, etag: "v2")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting && $0.state.draining.isEmpty }
        let between = await engine.readForTests { engine in
            (
                downloading: engine.state.jobs.values.filter { $0.state == .downloading }.map(\.transfer),
                owed: engine.followOwed,
                violations: engine.invariantViolations()
            )
        }
        let startedBetween = await harness.source.starts.dropFirst(before).map(\.id).filter { old.contains($0) }
        #expect(between.owed, "the follow still owes visits")
        #expect(startedBetween.isEmpty, "\(startedBetween.count) transfers of replaced content started after the apply: \(startedBetween.prefix(4))")
        #expect(between.downloading.allSatisfy { !old.contains($0) }, "no replaced content downloads between the follow's turns")
        #expect(between.violations.isEmpty, "\(between.violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let outcome = await EngineHarness.value(of: sync)
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.awaitCondition { !$0.followOwed && $0.state.inFlight.count == 2 }
        let started = await harness.source.starts.dropFirst(before).map(\.id)
        #expect(!started.isEmpty && started.allSatisfy { !old.contains($0) }, "every start since the apply is of new content: \(started.filter { old.contains($0) }.prefix(4))")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }
}
