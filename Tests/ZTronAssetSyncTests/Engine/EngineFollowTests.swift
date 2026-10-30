import Foundation
import Synchronization
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
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 46.2 to 47.2 s beside a second TSan process at a
    /// load of 20 to 35 (79 % of 60 s) and 19.3 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7; the cycle-6
    /// verifier measured 35.1 to 35.2 s paired at a load of 17 to 34), over half its 60 s, so the guard is
    /// `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: a failure of an id's replaced content before its follow visit answers the id's waiter from its new content", .timeLimit(.minutes(3)), arguments: ReplacedContentFailure.allCases)
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
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 48.3 to 49.5 s beside a second TSan process at a
    /// load of 20 to 35 (82 % of 60 s) and 19.9 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7; the cycle-6
    /// verifier measured 36.3 to 37.0 s paired at a load of 17 to 34), over half its 60 s, so the guard is
    /// `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: no transfer of a replaced content starts after the apply while a bounded follow still owes its job", .timeLimit(.minutes(3)))
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
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 48.5 to 49.0 s beside a second TSan process at a
    /// load of 20 to 35 (82 % of 60 s) and 20.0 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7; the cycle-6
    /// verifier measured 36.6 to 36.7 s paired at a load of 17 to 34), over half its 60 s, so the guard is
    /// `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: a queued user job of an id the apply dropped does not start while the follow still owes its visit", .timeLimit(.minutes(3)))
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
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 44.4 to 46.2 s beside a second TSan process at a
    /// load of 20 to 35 (77 % of 60 s) and 18.7 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7; the cycle-6
    /// verifier measured 34.7 to 35.2 s paired at a load of 17 to 34), over half its 60 s, so the guard is
    /// `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a space sweep during an owed follow moves a listed id's interest to its new content before it answers or re-queues the replaced content's job (R-CAR-2)", .timeLimit(.minutes(3)), arguments: SweptReplacedContent.allCases)
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

extension EngineSyncTests {
    /// One space sweep turn follows at most `followsPerTurn` of the jobs it re-queues or parks during an owed follow, and
    /// leaves the rest to its follow-up sweep (C2). A follow visit (supersede, re-route each interest, create the new
    /// content's job) costs about ten times a re-queue or a park; counted as one of those, one `.reclaimed` sweep turn
    /// followed up to `readmissionsPerTurn + parksPerPump` jobs, which held the actor 9.3 to 13 ms at 10,000 members (the
    /// close-out cycle-4 correctness lens, PROBE-C4-SWEEP2-C2). Setup: 600 prefetch members alternating 400 and 3,000
    /// bytes wait `awaitingSpace` for a pruned 2,000-byte blob with 200 bytes of room; a forced sync changes every
    /// member's content and its follow's follow-ups are held after the first turn's `followsPerTurn` visits, so 344 jobs
    /// still hold a moved id (more than one sweep turn may follow); the space sweep's follow-ups are held too. The deletion grace ends: the alarm reaps the
    /// blob and its `.reclaimed` sweep follows the members before it judges any (since the close-out cycle 8, PROBE-C7-RANK:
    /// a job is judged at its post-follow place). That one turn follows exactly `followsPerTurn` jobs of both sizes and,
    /// with members left to follow, judges none: every member it did not follow still waits `awaitingSpace` for the
    /// follow-up sweep (a job judged before its follow is judged at a place it may not keep). Once the holds end, every
    /// member's interest is on its new content and no replaced content was requested.
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 48.5 to 49.0 s beside a second TSan process at a
    /// load of 20 to 35 (82 % of 60 s) and 19.9 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7; the cycle-6
    /// verifier measured 37.0 to 37.0 s paired at a load of 17 to 34), over half its 60 s, so the guard is
    /// `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: one space sweep turn during an owed follow follows at most followsPerTurn jobs and leaves the rest to its follow-up sweep (C2)", .timeLimit(.minutes(3)))
    func spaceSweepFollowsAtMostOneTurnOfJobs() async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = Data(repeating: 0x78, count: 2_000)
        let x = EngineFixture.entry("x", xBytes)
        await harness.serveManifest([x])
        await harness.scriptTransfers([(x, xBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        let count = 600
        let large = 3_000
        let members = { (version: Int) in
            (0..<count).map { index in
                EngineHarness.onDemand(String(format: "m%05d", index), Self.sweptPayload(index: index, version: version, size: index % 2 == 0 ? 400 : large))
            }
        }
        let old = members(1)
        // v2 prunes x: its 2,000 bytes wait for the 60 s grace.
        await harness.serveManifest(old, etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(200, harness: harness, fileSystem: fileSystem)
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        let group = try await engine.registerGroup(old.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { engine in
            engine.state.jobs.count == count && engine.state.jobs.values.allSatisfy { $0.state == .blocked(.awaitingSpace) }
        }
        let new = members(2)
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest(new, etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        await engine.readForTests { $0.holdSpaceSweepFollowUps() }
        let largeIDs = Set(old.filter { $0.byteSize == Int64(large) }.map(\.identifier))
        let before = await engine.readForTests { Self.jobsHoldingMovedIDs($0, large: largeIDs) }
        #expect(before.small + before.large == count - SyncEngine.followsPerTurn, "setup: the follow's first turn visited followsPerTurn jobs: \(before)")
        // The grace ends: the alarm's due store work reaps x's 2,000 bytes, then its `.reclaimed` sweep runs; the turn
        // ends with a follow-up sweep owed (held) or, unbounded, with no member left waiting.
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { engine in
                engine.state.spaceSweepFollowUpWaiting || !engine.state.jobs.values.contains { $0.state == .blocked(.awaitingSpace) }
            }
        }
        let after = await engine.readForTests { engine in
            (
                owed: Self.jobsHoldingMovedIDs(engine, large: largeIDs),
                pending: engine.state.freeSpace?.pendingReclaim,
                followUpHeld: engine.state.spaceSweepFollowUpWaiting,
                waiting: old.filter { engine.state.jobs[$0.transferID]?.state == .blocked(.awaitingSpace) }.count
            )
        }
        let followed = (small: before.small - after.owed.small, large: before.large - after.owed.large)
        #expect(after.pending == 0, "setup: the sweep read the volume after the reclaim: \(String(describing: after.pending))")
        #expect(followed.small + followed.large == SyncEngine.followsPerTurn, "one sweep turn followed \(followed.small + followed.large) jobs (\(followed.small) of 400 bytes, \(followed.large) of 3,000), at most followsPerTurn = \(SyncEngine.followsPerTurn)")
        #expect(followed.small > 0 && followed.large > 0, "the turn followed jobs of both sizes: \(followed)")
        #expect(after.waiting == after.owed.small + after.owed.large && after.waiting > 0, "a turn that could not follow every member judged none: the \(after.owed.small + after.owed.large) members it did not follow still wait, \(after.waiting) do")
        #expect(after.followUpHeld, "the jobs left over wait for the sweep's follow-up turn")
        await engine.readForTests { $0.releaseSpaceSweepFollowUps() }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        let settled = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                moved: new.filter { engine.state.jobs[$0.transferID]?.assets.contains($0.identifier) != true }.count,
                violations: engine.invariantViolations()
            )
        }
        #expect(!settled.owed, "the follow ended")
        #expect(settled.moved == 0, "every member's interest is on its new content's job: \(settled.moved) are not")
        #expect(settled.violations.isEmpty, "\(settled.violations.prefix(3))")
        let replaced = Set(old.map(\.transferID))
        #expect(!(await harness.source.starts.map(\.id)).contains { replaced.contains($0) }, "no replaced content was requested")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    /// Distinct `size` bytes for member `index` at manifest `version`: a short distinct prefix and one repeated byte (a
    /// generated payload per member took most of a sanitizer run, S3-R4).
    static func sweptPayload(index: Int, version: Int, size: Int) -> Data {
        let prefix = Data("m\(index)-v\(version)-".utf8)
        return prefix + Data(repeating: 0x2E, count: size - prefix.count)
    }

    /// The jobs that hold an id the engine's copy lists at another transfer while a follow is owed
    /// (`SyncEngine.holdsMovedID`), split by whether that id is one of `large`.
    static func jobsHoldingMovedIDs(_ engine: isolated SyncEngine, large: Set<AssetID>) -> (small: Int, large: Int) {
        var small = 0
        var big = 0
        for job in engine.state.jobs.values where engine.holdsMovedID(job) {
            if job.assets.contains(where: { large.contains($0) }) {
                big += 1
            } else {
                small += 1
            }
        }
        return (small, big)
    }
}

/// The state of the job of the content shared by a moved id and a kept one (C), read in the first turn whose condition
/// check sees the job behind it (K) leave its wait for space: the reclaim's sweep turn.
@available(macOS 15.0, iOS 18.0, *)
final class SweepTurnWatch: Sendable {
    private let seen = Mutex<JobState?>(nil)

    /// Records C's job state once, in the turn the condition is first met.
    func record(_ state: JobState?) {
        self.seen.withLock { $0 = state }
    }

    /// C's job state in that turn; `nil` when the job was gone or the condition was never met.
    var state: JobState? {
        self.seen.withLock { $0 }
    }
}

/// When the follow visits the job of content shared by a moved id and a kept one, relative to the space sweep that
/// re-admits it.
enum LaneDropVisit: String, CaseIterable, Sendable {
    /// The follow's held turns are released and end before the reclaim: the sweep finds the job already followed (the
    /// outcome the sweep must give in both cases).
    case followVisitedFirst
    /// The follow still owes the job's visit when the reclaim's sweep reaches it: the sweep follows it itself
    /// (`followBeforeActing`) before it acts on it.
    case sweepFollowsFirst
}

extension EngineSyncTests {
    /// A space sweep that follows a job before re-queuing it judges the job again on the lane the follow leaves it, and
    /// neither re-queues it nor counts its bytes ahead of the jobs behind it when it no longer fits. Content C (5 MB) is
    /// listed by A, which has a user waiter, and by B, a prefetch group's member, so its job is user-lane; K (3 MB, a user
    /// waiter) waits behind it. Both wait `awaitingSpace`: 2 MB of room for user work, none for prefetch work (the
    /// opportunistic volume is 6 MB smaller), and 4 MB of a pruned blob pending the reclaim. A forced sync moves A to a
    /// 16-byte content while 2,100 changed entries sort before it, so the bounded follow owes C's visit (its turns held).
    /// The reclaim leaves 6 MB for user work and still none for prefetch work. Followed first, C's job is prefetch-lane
    /// and parked, and K is fetched. Judged on its pre-follow user lane, the sweep found that C fits, followed it (A
    /// left, B stayed: prefetch), re-queued it anyway and counted its 5 MB ahead: K was judged against 1 MB, parked
    /// `insufficientSpace`, and its fail-fast answered K's waiter `insufficientSpace(required: 3000000, available:
    /// 999000)` although 6 MB were free and the gate then parked C's job (F-22: the figures are the room the asset
    /// lacks; the close-out cycle-5 correctness lens, PROBE-C5-LANEDROP). At `s3-base` the follow moved every job in the
    /// apply's turn, so no sweep could act between the two. In the sweep's own turn C's job is parked `insufficientSpace`
    /// in both cases: a sweep that skipped the job once its re-judgement failed left it `awaitingSpace` with nothing
    /// pending and no wake until the store's settle read parked it a turn later (the close-out cycle-6 requirements
    /// lens, mutant `skipNotFit`).
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 45.7 to 47.0 s beside a second TSan process at a
    /// load of 20 to 35 (78 % of 60 s) and 19.2 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7; the cycle-6
    /// verifier measured 35.0 to 35.1 s paired at a load of 17 to 34), over half its 60 s, so the guard is
    /// `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a space sweep judges a job again on the lane its follow leaves before it re-queues it, so a lane the follow lowered takes no room from the next waiter (F-22)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func spaceSweepJudgesAFollowedJobOnItsNewLane(_ visit: LaneDropVisit) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 26_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        // Megabytes of one repeated byte: generated payloads of this size took seconds of the sanitizer run (S3-R4).
        let xBytes = Data(repeating: 0x78, count: 4_000_000)
        let qBytes = EngineFixture.bytes(889_002, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([x, q])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        // Changed on-demand entries without jobs that sort before A: the follow's first pass formats
        // `followFormatsPerTurn` of them and stops before A's entry.
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        let cBytes = Data(repeating: 0x63, count: 5_000_000)
        let kBytes = Data(repeating: 0x6B, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share one content")
        // v2 prunes x (its 4 MB wait for the 60 s grace) and lists C under A and B, and K.
        await harness.serveManifest([q] + fillers(720_000) + [a, b, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        // 2 MB of room for user work: neither C's 5 MB nor K's 3 MB fit before the reclaim.
        _ = try await EngineRegressionCycle6Tests.leaveRoom(2_000_000, harness: harness, fileSystem: fileSystem)
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.hold])
        await harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }
        let group = try await engine.registerGroup([b.identifier], lane: .prefetch).get()
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { engine in
            engine.state.jobs[k.transferID]?.state == .blocked(.awaitingSpace) && engine.state.jobs[a.transferID]?.assets.count == 2
        }
        // v3 moves A to a 16-byte content; B and K keep theirs.
        let replacementBytes = EngineFixture.bytes(889_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(820_000) + [replacement, b, k], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            // The follow's turns are owned tasks, not timers: the clock stays before the grace's end.
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                lane: engine.state.jobs[a.transferID]?.lane,
                ids: engine.state.jobs[a.transferID]?.assets.count,
                shared: engine.state.jobs[a.transferID]?.state,
                k: engine.state.jobs[k.transferID]?.state
            )
        }
        switch visit {
        case .followVisitedFirst:
            #expect(!before.owed && before.lane == .prefetch && before.ids == 1, "setup: the follow moved A and left B on C's job: \(before)")
        case .sweepFollowsFirst:
            #expect(before.owed && before.lane == .userInitiated && before.ids == 2, "setup: C's job still holds A, whose visit the follow owes: \(before)")
        }
        #expect(before.shared == .blocked(.awaitingSpace) && before.k == .blocked(.awaitingSpace), "setup: \(before)")
        // Just under 2 MB in both cases: a follow that visited first may already have committed A's 16 bytes.
        try await Self.leaveRoom(1_999_000, harness: harness, fileSystem: fileSystem)
        // The grace ends: the alarm reaps x's 4 MB (6 MB of room for user work, none for prefetch work) and runs its
        // `.reclaimed` sweep. C's job is also read in the first turn that sees K leave its wait, the sweep's (a condition
        // is evaluated in every turn that notifies): the settle read that follows that turn decides a job the sweep left
        // waiting, so a later read cannot tell a job the sweep parked from one it left `awaitingSpace` with no wake.
        let watch = SweepTurnWatch()
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { engine in
                guard engine.state.jobs[k.transferID]?.state != .blocked(.awaitingSpace) else {
                    return false
                }
                watch.record(engine.state.jobs[a.transferID]?.state)
                return true
            }
        }
        let afterSweep = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                lane: engine.state.jobs[a.transferID]?.lane,
                shared: engine.state.jobs[a.transferID]?.state,
                violations: engine.invariantViolations()
            )
        }
        #expect(afterSweep.owed == (visit == .sweepFollowsFirst), "the sweep ran while the follow owed C's visit only when the follow had not visited first: \(afterSweep)")
        #expect(afterSweep.lane == .prefetch && afterSweep.shared != .queued, "C's job, left with B's prefetch interest, waits for room prefetch work has not: \(afterSweep)")
        #expect(watch.state == .blocked(.insufficientSpace), "in the sweep's turn C's job, which does not fit its prefetch lane, is parked insufficientSpace (re-checked at every read), not left awaitingSpace with nothing pending and no wake: \(String(describing: watch.state))")
        #expect(afterSweep.violations.isEmpty, "\(afterSweep.violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let kResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? kResult.get())?.byteSize == Int64(kBytes.count), "K's waiter is answered from its 3 MB, with 6 MB of room for user work: \(kResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A's waiter is answered from its 16-byte new content: \(aResult)")
        #expect(!(await harness.source.starts.map(\.id)).contains(a.transferID), "C's content, wanted by prefetch work only, never started without room")
        await engine.releaseGroup(group)
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.shutdown()
    }
}

extension EngineSyncTests {
    /// A space sweep that follows a job before parking it judges the job again on the lane the follow leaves it, and
    /// re-queues it when it fits there. The two free-space readings are not ordered (neither the store nor the ledger
    /// clamps them, and `largestRoom` takes the larger), so a lane the follow lowered may read the larger room. Content C
    /// (5 MB) is listed by A, which has a user waiter, and by B, which has a prefetch waiter, so its job is user-lane. It
    /// waits `awaitingSpace`: no room for user work, 6 MB for prefetch work (the important volume is 6 MB smaller), and 4
    /// MB of a pruned blob pending the reclaim. A forced sync moves A to a 16-byte content while 2,100 changed entries sort
    /// before it, so the bounded follow owes C's visit (its turns held). The reclaim leaves 4 MB for user work and 10 MB
    /// for prefetch work. Followed first, C's job is prefetch-lane, fits, and is fetched for B's waiter. Judged on its
    /// pre-follow user lane, the sweep found that C does not fit, followed it (A left, B stayed: prefetch) and parked it
    /// `insufficientSpace` anyway, so its fail-fast answered B's waiter `insufficientSpace(required: 5000000, available:
    /// 10000003)`: figures that contradict themselves (F-22: `required` exceeds `available` whenever a job is parked;
    /// the close-out cycle-6 correctness lens, PROBE-C6-LANEGAIN). At `s3-base` the follow moved every job in the apply's
    /// turn, so no sweep could act between the two.
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 44.2 to 45.5 s beside a second TSan process at a
    /// load of 20 to 35 (76 % of 60 s) and 18.7 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7; the cycle-6
    /// verifier measured 35.0 to 35.1 s paired at a load of 17 to 34), over half its 60 s, so the guard is
    /// `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a space sweep judges a job again on the lane its follow leaves before it parks it, so a lane whose volume has room re-queues it (F-22)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func spaceSweepRequeuesAFollowedJobItsNewLaneFits(_ visit: LaneDropVisit) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 26_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        // Megabytes of one repeated byte: generated payloads of this size took seconds of the sanitizer run (S3-R4).
        let xBytes = Data(repeating: 0x79, count: 4_000_000)
        let qBytes = EngineFixture.bytes(893_002, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([x, q])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        // Changed on-demand entries without jobs that sort before A: the follow's first pass formats
        // `followFormatsPerTurn` of them and stops before A's entry.
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        let cBytes = Data(repeating: 0x65, count: 5_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share one content")
        // v2 prunes x (its 4 MB wait for the 60 s grace) and lists C under A and B.
        await harness.serveManifest([q] + fillers(730_000) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        // No room for user work, 6 MB for prefetch work: C's 5 MB do not fit its user lane before the reclaim.
        _ = try await EngineRegressionCycle6Tests.leaveRoom(0, harness: harness, fileSystem: fileSystem)
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.stage(cBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.assets.count == 2 }
        // v3 moves A to a 16-byte content; B keeps C.
        let replacementBytes = EngineFixture.bytes(893_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(830_000) + [replacement, b], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            // The follow's turns are owned tasks, not timers: the clock stays before the grace's end.
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                lane: engine.state.jobs[a.transferID]?.lane,
                ids: engine.state.jobs[a.transferID]?.assets.count,
                shared: engine.state.jobs[a.transferID]?.state
            )
        }
        switch visit {
        case .followVisitedFirst:
            #expect(!before.owed && before.lane == .prefetch && before.ids == 1, "setup: the follow moved A and left B on C's job: \(before)")
        case .sweepFollowsFirst:
            #expect(before.owed && before.lane == .userInitiated && before.ids == 2, "setup: C's job still holds A, whose visit the follow owes: \(before)")
        }
        #expect(before.shared == .blocked(.awaitingSpace), "setup: \(before)")
        // The grace ends: the alarm reaps x's 4 MB (4 MB of room for user work, 10 MB for prefetch work) and runs its
        // `.reclaimed` sweep.
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .blocked(.awaitingSpace) }
        }
        let afterSweep = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                lane: engine.state.jobs[a.transferID]?.lane,
                shared: engine.state.jobs[a.transferID]?.state,
                space: engine.state.freeSpace,
                violations: engine.invariantViolations()
            )
        }
        let important = afterSweep.space.map { $0.volumeImportant - $0.reserveBytes } ?? 0
        let opportunistic = afterSweep.space.map { $0.volumeOpportunistic - $0.reserveBytes } ?? 0
        #expect(afterSweep.space?.pendingReclaim == 0 && important < Int64(cBytes.count) && opportunistic >= Int64(cBytes.count), "setup: after the reclaim C fits the prefetch lane's volume and not the user lane's: \(String(describing: afterSweep.space))")
        #expect(afterSweep.owed == (visit == .sweepFollowsFirst), "the sweep ran while the follow owed C's visit only when the follow had not visited first: \(afterSweep)")
        let parked: Bool
        if case .blocked? = afterSweep.shared {
            parked = true
        } else {
            parked = false
        }
        #expect(!parked && (afterSweep.lane == nil || afterSweep.lane == .prefetch), "C's job, left with B's prefetch interest, is re-queued for the room prefetch work has: \(afterSweep)")
        #expect(afterSweep.violations.isEmpty, "\(afterSweep.violations.prefix(3))")
        let bResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? bResult.get())?.byteSize == Int64(cBytes.count), "B's prefetch waiter is answered from C's 5 MB, with 10 MB of room for prefetch work: \(bResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A's waiter is answered from its 16-byte new content: \(aResult)")
        #expect(await harness.source.starts.map(\.id).contains(a.transferID), "C's content was fetched")
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.shutdown()
    }
}

extension EngineSyncTests {
    /// A free-space read's sweep (`.read`) that follows a job before re-queuing it judges the job again on the lane the
    /// follow leaves it, as the reclaim's sweep does. Content C (5 MB) is wanted by A through a user-lane group and by B
    /// through a prefetch group, so its job is user-lane; K (3 MB) is wanted by a user-lane group. Both are parked
    /// `insufficientSpace`: 2 MB of room for user work, none for prefetch work (the opportunistic volume is 6 MB smaller)
    /// and nothing pending reclaim. A forced sync moves A to a 16-byte content while 2,100 changed entries sort before it,
    /// so the bounded follow owes C's visit (its turns held). The volume then gains room (6 MB for user work, still none
    /// for prefetch work) and a read sweeps. Followed first, C's job is prefetch-lane and stays parked; K is re-queued.
    /// Judged on its pre-follow user lane, the read found that C fits, followed it (A left, B stayed: prefetch),
    /// re-queued it and counted its 5 MB ahead, so K was judged against 1 MB and stayed parked with 6 MB free (the
    /// close-out cycle-6 correctness lens, PROBE-C6-READDROP; it fails on the code before the cycle-6 re-judgement).
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 37.7 to 38.5 s beside a second TSan process at a
    /// load of 20 to 35 (64 % of 60 s) and 16.1 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7), over half
    /// its 60 s, so the guard is `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a free-space read's sweep judges a followed job again on its new lane, so a lane the follow lowered takes no room from the next parked job", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func readSweepJudgesAFollowedJobOnItsNewLane(_ visit: LaneDropVisit) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 26_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let qBytes = EngineFixture.bytes(894_002, count: 300)
        let q = EngineFixture.entry("q", qBytes)
        // Changed on-demand entries without jobs that sort before A: the follow's first pass formats
        // `followFormatsPerTurn` of them and stops before A's entry.
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        // Megabytes of one repeated byte: generated payloads of this size took seconds of the sanitizer run (S3-R4).
        let cBytes = Data(repeating: 0x66, count: 5_000_000)
        let kBytes = Data(repeating: 0x6C, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share one content")
        await harness.serveManifest([q] + fillers(740_000) + [a, b, k])
        await harness.scriptTransfers([(q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        let free = try await harness.store.freeSpace()
        #expect(free.pendingReclaim == 0, "setup: nothing pending reclaim: \(free)")
        // 2 MB of room for user work: neither C's 5 MB nor K's 3 MB fit.
        let ballastURL = EngineHarness.base.appendingPathComponent("ballast-read-drop")
        var ballast = free.volumeImportant - free.reserveBytes - 2_000_000
        try fileSystem.write(Data(repeating: 3, count: Int(ballast)), to: ballastURL, mode: .truncate)
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.hold])
        await harness.source.script(k.transferID, [.hold])
        let groupA = try await engine.registerGroup([a.identifier], lane: .userInitiated).get()
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.insufficientSpace) }
        let groupB = try await engine.registerGroup([b.identifier], lane: .prefetch).get()
        let groupK = try await engine.registerGroup([k.identifier], lane: .userInitiated).get()
        await engine.awaitCondition { engine in
            engine.state.jobs[k.transferID]?.state == .blocked(.insufficientSpace) && engine.state.jobs[a.transferID]?.assets.count == 2
        }
        // v2 moves A to a 16-byte content; B and K keep theirs.
        let replacementBytes = EngineFixture.bytes(894_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(840_000) + [replacement, b, k], etag: "v2")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                lane: engine.state.jobs[a.transferID]?.lane,
                ids: engine.state.jobs[a.transferID]?.assets.count,
                shared: engine.state.jobs[a.transferID]?.state,
                k: engine.state.jobs[k.transferID]?.state
            )
        }
        switch visit {
        case .followVisitedFirst:
            #expect(!before.owed && before.lane == .prefetch && before.ids == 1, "setup: the follow moved A and left B on C's job: \(before)")
        case .sweepFollowsFirst:
            #expect(before.owed && before.lane == .userInitiated && before.ids == 2, "setup: C's job still holds A, whose visit the follow owes: \(before)")
        }
        #expect(before.shared == .blocked(.insufficientSpace) && before.k == .blocked(.insufficientSpace), "setup: \(before)")
        // The volume gains room: 6 MB for user work, none for prefetch work; the read sweeps.
        let gained = try await harness.store.freeSpace()
        ballast -= 6_000_000 - (gained.volumeImportant - gained.reserveBytes)
        try fileSystem.write(Data(repeating: 3, count: Int(ballast)), to: ballastURL, mode: .truncate)
        await engine.refreshFreeSpace()
        let after = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                lane: engine.state.jobs[a.transferID]?.lane,
                shared: engine.state.jobs[a.transferID]?.state,
                k: engine.state.jobs[k.transferID]?.state,
                violations: engine.invariantViolations()
            )
        }
        #expect(after.owed == (visit == .sweepFollowsFirst), "the read swept while the follow owed C's visit only when the follow had not visited first: \(after)")
        #expect(after.k != .blocked(.insufficientSpace), "K (3 MB, user lane) is re-queued for the 6 MB of room user work has: \(String(describing: after.k))")
        #expect(after.lane == .prefetch && after.shared == .blocked(.insufficientSpace), "C's job, left with B's prefetch interest, stays parked for room prefetch work lacks: \(after)")
        #expect(after.violations.isEmpty, "\(after.violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.releaseGroup(groupA)
        await engine.releaseGroup(groupB)
        await engine.releaseGroup(groupK)
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.shutdown()
    }

    /// The kept waiter of a job a space sweep parks after its follow gets the figures of the lane the follow left it
    /// (F-22: the bytes the asset needs against the room that lane has). The reclaim's sweep runs during an owed follow as
    /// in `spaceSweepJudgesAFollowedJobOnItsNewLane`, but B is a prefetch-lane waiter rather than a group member, so the
    /// park's fail-fast answers it: C's 5 MB against no room for prefetch work (the opportunistic volume is 6 MB smaller
    /// than the important one, which has 6 MB of room after the reclaim), whether the follow visited first or the sweep
    /// followed the job itself. K's waiter is answered from its 3 MB and A's from its 16-byte content (the close-out
    /// cycle-6 correctness lens, PROBE-C6-PARKFIGURES).
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 45.7 to 47.2 s beside a second TSan process at a
    /// load of 20 to 35 (79 % of 60 s) and 19.3 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7), over half
    /// its 60 s, so the guard is `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: the kept prefetch waiter of a job a space sweep parks after its follow gets its own lane's figures (F-22)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func spaceSweepParksAFollowedJobWithItsNewLanesFigures(_ visit: LaneDropVisit) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 26_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = Data(repeating: 0x7A, count: 4_000_000)
        let qBytes = EngineFixture.bytes(895_002, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([x, q])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        let cBytes = Data(repeating: 0x67, count: 5_000_000)
        let kBytes = Data(repeating: 0x6D, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share one content")
        // v2 prunes x (its 4 MB wait for the 60 s grace) and lists C under A and B, and K.
        await harness.serveManifest([q] + fillers(750_000) + [a, b, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(2_000_000, harness: harness, fileSystem: fileSystem)
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.hold])
        await harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { engine in
            engine.state.jobs[k.transferID]?.state == .blocked(.awaitingSpace) && engine.state.jobs[a.transferID]?.assets.count == 2
        }
        // v3 moves A to a 16-byte content; B and K keep theirs.
        let replacementBytes = EngineFixture.bytes(895_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(850_000) + [replacement, b, k], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            // The follow's turns are owned tasks, not timers: the clock stays before the grace's end.
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (owed: engine.followOwed, lane: engine.state.jobs[a.transferID]?.lane, ids: engine.state.jobs[a.transferID]?.assets.count)
        }
        #expect(before.owed == (visit == .sweepFollowsFirst), "setup: \(before)")
        // Just under 2 MB in both cases: a follow that visited first may already have committed A's 16 bytes.
        try await Self.leaveRoom(1_999_000, harness: harness, fileSystem: fileSystem)
        // The grace ends: the alarm reaps x's 4 MB (6 MB of room for user work, none for prefetch work) and runs its
        // `.reclaimed` sweep.
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state != .blocked(.awaitingSpace) }
        }
        let bResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let kResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let violations = await engine.invariantViolations()
        if case .failure(.insufficientSpace(let required, let available)) = bResult {
            #expect(required == Int64(cBytes.count) && available == 0, "B's figures are C's 5 MB against the room its prefetch lane has: \(bResult)")
        } else {
            Issue.record("B's prefetch waiter is answered insufficientSpace for C's 5 MB with no room for prefetch work: \(bResult)")
        }
        #expect((try? kResult.get())?.byteSize == Int64(kBytes.count), "K's waiter is answered from its 3 MB: \(kResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A's waiter is answered from its 16-byte new content: \(aResult)")
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.shutdown()
    }
}
