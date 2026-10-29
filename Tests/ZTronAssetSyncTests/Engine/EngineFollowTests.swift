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
    /// owed, and in the end every member's interest follows its new content with no job left on the old. Hang guard
    /// (S3-R4): under TSan in the whole Sync bundle it took 26.7 s alone and 41.2 to 41.4 s beside a second TSan process
    /// at a load of 16 to 26 (Stage 3 close-out cycle 4), over half its 60 s, so the guard is `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: an apply that moves more jobs than one turn takes follows them a bounded slice per turn with every invariant holding between turns", .timeLimit(.minutes(3)))
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
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 24.3 s alone and 37.0 to 37.2 s beside a second
    /// TSan process at a load of 16 to 26 (Stage 3 close-out cycle 4), over half its 60 s, so the guard is
    /// `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: a 404 for a prefetch member's replaced content before the follow's pass reached it moves the member to its new content", .timeLimit(.minutes(3)))
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

    /// The user-queue form of `noReplacedContentStartsDuringTheFollow`, for an id the apply dropped: the job of a user
    /// waiter whose id left the manifest waits in the user queue (both slots run other user transfers) when the apply
    /// lands, and the follow owes it a visit. A slot freed between two follow turns does not start it: a transfer of
    /// content no id wants is never requested after the apply. That user job takes no slot from other work either: the
    /// freed slot goes to the first member of an unchanged prefetch group, and no running transfer is preempted for it.
    /// The follow's visit then ends the waiter's interest with `.notFound` (T21), as the cycle-1 one-turn follow did in
    /// the apply's turn.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: a queued user job of an id the apply dropped does not start while the follow still owes its visit", .timeLimit(.minutes(1)))
    func droppedUserJobWaitsForTheFollow() async throws {
        let count = 700
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0))
        let members = (0..<count).map { EngineHarness.onDemand(String(format: "m%04d", $0), EngineFixture.bytes(UInt64(540_000 + $0), count: 16)) }
        let runningBytes = (0..<2).map { EngineFixture.bytes(UInt64(545_000 + $0), count: 16) }
        let running = (0..<2).map { EngineHarness.onDemand("u\($0)", runningBytes[$0]) }
        let dropped = EngineHarness.onDemand("dropped", EngineFixture.bytes(546_000, count: 16))
        let unchanged = (0..<2).map { EngineHarness.onDemand("b\($0)", EngineFixture.bytes(UInt64(547_000 + $0), count: 16)) }
        // Listed last, so the follow's first turn does not reach its visit.
        let v1 = members + running + unchanged + [dropped]
        try await EngineSingleFlightTests.applied(v1, harness: harness)
        let engine = harness.engine
        for (entry, bytes) in zip(running, runningBytes) {
            await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        }
        let runningWaiters = running.map { entry in Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) } }
        await engine.awaitCondition { engine in running.allSatisfy { engine.state.jobs[$0.transferID]?.state == .downloading } }
        let steady = try await engine.registerGroup(unchanged.map(\.identifier), lane: .prefetch).get()
        let group = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        let waiter = Task { await engine.awaitAsset(dropped.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs.count == count + 5 && $0.state.jobs[dropped.transferID]?.state == .queued }
        let preemptions = await engine.readForTests { $0.state.metrics.preemptions }
        let changed = members.enumerated().map { index, entry in
            EngineHarness.onDemand(entry.identifier.rawValue, EngineFixture.bytes(UInt64(590_000 + index), count: 16))
        }
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest(changed + running + unchanged, etag: "v2")
        let before = await harness.source.starts.count
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        // A slot frees between two follow turns: the user queue's head is the dropped id's job.
        await harness.source.release(running[0].transferID, with: .progress(received: 0, expected: nil))
        #expect((try? await EngineHarness.value(of: runningWaiters[0]).get()) != nil)
        await engine.awaitCondition { $0.state.jobs[running[0].transferID] == nil && $0.state.draining.isEmpty }
        let between = await engine.readForTests { engine in
            (
                queued: engine.state.jobs[dropped.transferID]?.state,
                steady: engine.state.jobs[unchanged[0].transferID]?.state,
                preemptions: engine.state.metrics.preemptions,
                violations: engine.invariantViolations()
            )
        }
        let startedBetween = await harness.source.starts.dropFirst(before).map(\.id)
        #expect(!startedBetween.contains(dropped.transferID), "the dropped id's transfer was requested after the apply")
        #expect(between.queued == .queued, "it waits in its queue for the follow: \(between)")
        #expect(between.steady == .downloading, "the freed slot went to the unchanged prefetch member: \(between)")
        #expect(between.preemptions == preemptions, "no transfer was preempted for a job that waits for the follow")
        #expect(between.violations.isEmpty, "\(between.violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let outcome = await EngineHarness.value(of: sync)
        #expect(outcome.completeReport != nil, "\(outcome)")
        let answer = await EngineHarness.value(of: waiter)
        #expect(answer == .failure(.notFound), "the follow's visit ends the dropped id's interest: \(answer)")
        #expect(!(await harness.source.starts.dropFirst(before).map(\.id)).contains(dropped.transferID), "never requested after the apply")
        await harness.source.release(running[1].transferID, with: .progress(received: 0, expected: nil))
        _ = await EngineHarness.value(of: runningWaiters[1])
        await engine.releaseGroup(steady)
        await engine.releaseGroup(group)
        await engine.shutdown()
    }
}

/// The interest a listed id's replaced content holds when a space sweep reaches its parked job during an owed follow, and
/// what the sweep then does with the job.
enum SweptReplacedContent: String, CaseIterable, Sendable {
    /// A user waiter (`awaitAsset`); the reclaim leaves too little room, so the sweep parks the job
    /// `insufficientSpace` and its fail-fast answers the waiter.
    case waiterReparked
    /// A member of `ensureAvailable`'s group, as `waiterReparked`.
    case ensureReparked
    /// A user waiter; the reclaim makes room, so the sweep re-queues the job.
    case waiterRequeued

    /// The room above the reserve the test leaves just before the reclaim: with the 4 MB reaped, too little for the
    /// replaced content's 5 MB, or room for it.
    var roomBeforeReclaim: Int64 {
        self == .waiterRequeued ? 2_000_000 : 500_000
    }
}

extension EngineSyncTests {
    /// A space sweep (`sweepSpaceParked`: the alarm's `.reclaimed` sweep after reaped bytes, `.settle`, a purge's
    /// reclaim) reaching the parked job of a listed id's replaced content while a bounded follow still owes its visit
    /// follows that job before it answers or re-queues it, as a failure does (`followBeforeActing`): the id's interest
    /// moves to its new content (T22) and is answered from it. Without it the sweep parked the replaced 5 MB content
    /// `insufficientSpace` and its fail-fast answered the waiter, or the ensure member, with that content's figures
    /// although the copy lists the id at 16 bytes that fit (F-22: the figures are the bytes the asset needs), or it
    /// re-queued the replaced content, whose head then stalled its queue until the follow's visit (the close-out cycle-3
    /// correctness lens, PROBE-C3-SPACE). Setup: 4 MB of a pruned blob wait for the reclaim; the user job of the target's
    /// 5 MB content is parked `awaitingSpace`; a forced sync moves the target to a 16-byte content while 2,100 changed
    /// entries sort before it, so the follow's first pass stops before its entry (`holdFollowFollowUps()`); then the
    /// deletion grace ends and the alarm's reaper frees the 4 MB.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a space sweep during an owed follow moves a listed id's interest to its new content before it answers or re-queues the replaced content's job (R-CAR-2)", .timeLimit(.minutes(1)), arguments: SweptReplacedContent.allCases)
    func spaceSweepFollowsTheReplacedContent(_ swept: SweptReplacedContent) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        // Megabytes of one repeated byte: generated payloads of this size took seconds of the sanitizer run (S3-R4).
        let xBytes = Data(repeating: 0x78, count: 4_000_000)
        let qBytes = EngineFixture.bytes(779_002, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([x, q])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        // The fillers are changed on-demand entries without jobs that sort before the target: the follow's first pass
        // formats `followFormatsPerTurn` of them and stops before the target's entry.
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        let old = EngineHarness.onDemand("zz-target", Data(repeating: 0x6F, count: 5_000_000))
        // v2 prunes x (its 4 MB wait for the 60 s grace) and lists the target's 5 MB content.
        await harness.serveManifest([q] + fillers(720_000) + [old], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        // 4 MB of room: the 5 MB do not fit before the reclaim, and fit the plan of `ensureAvailable` with it.
        _ = try await EngineRegressionCycle6Tests.leaveRoom(4_000_000, harness: harness, fileSystem: fileSystem)
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        await harness.source.script(old.transferID, [.hold])
        // The answer: whether it came from the new content, and what it was.
        let answer: Task<(fromNewContent: Bool, answer: String), Never>
        switch swept {
        case .waiterReparked, .waiterRequeued:
            let waiter = Task { await engine.awaitAsset(old.identifier, lane: .userInitiated) }
            answer = Task {
                let result = await EngineHarness.value(of: waiter)
                return ((try? result.get())?.byteSize == 16, "\(result)")
            }
        case .ensureReparked:
            // The ensure's fetch-first finds v2 unchanged.
            await harness.source.scriptManifest([.notModified])
            let ensure = Task { await engine.ensureAvailable(scope: .identifiers([old.identifier])) }
            answer = Task {
                let result = await EngineHarness.value(of: ensure)
                return ((try? result.get())?.isComplete == true, "\(result)")
            }
        }
        await engine.awaitCondition { $0.state.jobs[old.transferID]?.state == .blocked(.awaitingSpace) }
        let replacement = EngineHarness.onDemand("zz-target", EngineFixture.bytes(779_004, count: 16))
        await harness.source.script(replacement.transferID, [.stage(EngineFixture.bytes(779_004, count: 16))])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(820_000) + [replacement], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        let before = await engine.readForTests { engine in
            (
                listed: engine.state.applied.entry(for: old.identifier)?.transferID == replacement.transferID,
                parked: engine.state.jobs[old.transferID]?.state,
                reached: engine.state.unfollowed.contains(old.transferID),
                owed: engine.followOwed
            )
        }
        #expect(before.listed && before.parked == .blocked(.awaitingSpace) && !before.reached && before.owed, "setup: \(before)")
        // The room the reclaim adds to: too little for the replaced 5 MB, or enough.
        try await Self.leaveRoom(swept.roomBeforeReclaim, harness: harness, fileSystem: fileSystem)
        // The grace ends: the alarm's due store work reaps x's 4 MB, then the `.reclaimed` sweep runs.
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[old.transferID]?.state != .blocked(.awaitingSpace) }
        }
        let afterSweep = await engine.readForTests { engine in
            (
                holds: engine.state.jobs[old.transferID]?.assets.contains(old.identifier) == true,
                state: engine.state.jobs[old.transferID]?.state,
                owed: engine.followOwed,
                violations: engine.invariantViolations()
            )
        }
        #expect(afterSweep.owed, "the sweep ran while the follow still owed the id's visit")
        #expect(!afterSweep.holds, "the replaced content's job no longer holds the id after the sweep: \(String(describing: afterSweep.state))")
        #expect(afterSweep.violations.isEmpty, "\(afterSweep.violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let answered = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: answer) }
        #expect(answered.fromNewContent, "the id's interest is answered from its 16-byte new content: \(answered.answer)")
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        #expect(!(await harness.source.starts.map(\.id)).contains(old.transferID), "the replaced content was never requested")
        await engine.shutdown()
    }

    /// Takes the room above the reserve down to `room` with a second ballast file (`leaveRoom`'s own ballast stays).
    @available(macOS 15.0, iOS 18.0, *)
    static func leaveRoom(_ room: Int64, harness: EngineHarness, fileSystem: FakeFileSystem) async throws {
        let free = try await harness.store.freeSpace()
        let excess = free.volumeImportant - free.reserveBytes - room
        try #require(excess >= 0, "the room above the reserve is already below \(room): \(free)")
        try fileSystem.write(Data(repeating: 2, count: Int(excess)), to: EngineHarness.base.appendingPathComponent("ballast-2"), mode: .truncate)
    }
}
