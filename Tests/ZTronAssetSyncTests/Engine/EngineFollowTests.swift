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
}
