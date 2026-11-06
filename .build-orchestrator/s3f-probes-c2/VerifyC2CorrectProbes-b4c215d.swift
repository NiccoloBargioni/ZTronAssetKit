import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch probes (s3f close-out verification, cycle 2, correctness lens). Never committed.
@Suite("VerifyC2Correct probes")
struct VerifyC2CorrectProbes {
    /// PROBE-W1b: the same without any seam: count, over the whole follow, the transfers of replaced content started
    /// after the apply (production scheduling of the follow-ups against the drains).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-W1b: over a whole bounded follow, no transfer of a replaced content starts after the apply", .timeLimit(.minutes(2)))
    func noStaleStartsOverFollow() async throws {
        let count = 3_000
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 0))
        let v1 = (0..<count).map { EngineHarness.onDemand(String(format: "x%04d", $0), EngineFixture.bytes(UInt64(140_000 + $0), count: 16)) }
        try await EngineSingleFlightTests.applied(v1, harness: harness)
        let engine = harness.engine
        let group = try await engine.registerGroup(v1.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count && $0.state.inFlight.count == 4 }
        let before = await harness.source.starts.count
        let old = Set(v1.map(\.transferID))
        let v2 = v1.enumerated().map { index, entry in
            EngineHarness.onDemand(entry.identifier.rawValue, EngineFixture.bytes(UInt64(190_000 + index), count: 16))
        }
        await harness.serveManifest(v2, etag: "v2")
        let outcome = await engine.sync(.force)
        await engine.awaitCondition { $0.state.draining.isEmpty && $0.state.inFlight.count == 4 }
        let starts = await harness.source.starts.dropFirst(before).map(\.id)
        let stale = starts.filter { old.contains($0) }
        let violations = await engine.readForTests { $0.invariantViolations() }
        print("PROBE-W1b: complete \(outcome.completeReport != nil), starts since the apply \(starts.count), of replaced content \(stale.count)")
        #expect(stale.isEmpty, "PROBE-W1b FAIL: \(stale.count) transfers of replaced content started after the apply")
        #expect(violations.isEmpty, "\(violations)")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    /// PROBE-W4: an id whose content changed waits for its follow visit on the job of its replaced content; a 404 for
    /// that replaced content arriving before the visit answers its waiter `.notFound` although the engine's copy lists
    /// the id (F-20's rule: never `.notFound` while the asset is listed). The hold seam stands for the follow-up turn
    /// that has not run yet when the network callback lands (independent tasks in production).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-W4: a 404 for an id's replaced content before its follow visit does not answer its waiter notFound", .timeLimit(.minutes(2)))
    func notFoundBeforeVisit() async throws {
        let count = 600
        let harness = EngineHarness.make()
        let v1 = (0..<count).map { EngineHarness.onDemand(String(format: "y%04d", $0), EngineFixture.bytes(UInt64(240_000 + $0), count: 16)) }
        try await EngineSingleFlightTests.applied(v1, harness: harness)
        let engine = harness.engine
        let target = v1[count - 1]
        let group = try await engine.registerGroup(v1.dropLast().map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count - 1 }
        await harness.source.script(target.transferID, [.hold])
        let waiter = Task { await engine.awaitAsset(target.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[target.transferID]?.state == .downloading }
        let v2 = v1.enumerated().map { index, entry in
            EngineHarness.onDemand(entry.identifier.rawValue, EngineFixture.bytes(UInt64(290_000 + index), count: 16))
        }
        let newBytes = EngineFixture.bytes(UInt64(290_000 + count - 1), count: 16)
        await harness.source.script(v2[count - 1].transferID, [.stage(newBytes)])
        await harness.serveManifest(v2, etag: "v2")
        let sync = Task { await engine.sync(.force) }
        _ = await sync.value
        let before = await engine.readForTests { engine in
            (listed: engine.state.applied.entry(for: target.identifier)?.transferID == v2[count - 1].transferID, oldJob: engine.state.jobs[target.transferID]?.state)
        }
        print("PROBE-W4 before the 404: copy lists the id at its new content \(before.listed), old job \(String(describing: before.oldJob))")
        await harness.source.release(target.transferID, with: .failed(.permanentMissing(httpStatus: 404)))
        let answer = await waiter.value
        print("PROBE-W4 waiter's answer: \(answer)")
        #expect((try? answer.get()) != nil, "PROBE-W4 FAIL: the waiter of a listed id was answered \(answer)")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }
}
