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

