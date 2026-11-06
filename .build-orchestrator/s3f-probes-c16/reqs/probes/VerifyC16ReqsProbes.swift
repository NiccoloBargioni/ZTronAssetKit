import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch probes (s3f close-out verification, cycle 16, requirements lens). Never committed.
@Suite("VerifyC16ReqsProbes")
struct VerifyC16ReqsProbes {
    /// PROBE-C16R-RETRY-END-DIAG: the steps of `barrierRetriesAFailedPublicationWithNothingOfItsEnd` (WindowTests `:189`)
    /// up to its setup `#require` (`:211`), in concurrent copies, reading at that point what the committed test reads
    /// plus the job's state, its attempts, the network edge serial and whether the engine had a conditions reading
    /// before A's request. A copy whose read finds the end gone says why.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C16R-RETRY-END-DIAG", .timeLimit(.minutes(3)), arguments: 0..<24)
    func retryEndDiag(_ copy: Int) async throws {
        let seed: UInt64 = 1_616_102
        let (s, _) = try await EngineFollowBarrierTests.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: EngineFollowBarrierTests.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        await s.harness.serveManifest([s.q] + EngineFollowBarrierTests.FollowBarrier.fillers(seed + 100) + [a] + EngineFollowBarrierTests.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.stage(cBytes), .hold, .stage(cBytes)])
        s.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .io))
        let before = await engine.readForTests { e in (edge: e.state.networkEdgeSerial, conditionsNil: e.state.conditions == nil) }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { e in
            if case .failed(.at) = e.state.jobs[a.transferID]?.state {
                return true
            }
            return false
        }
        let read = await engine.readForTests { e in
            (
                owed: e.followOwed,
                end: e.state.jobs[a.transferID]?.attemptEnd,
                state: e.state.jobs[a.transferID].map { "\($0.state)" } ?? "nil",
                attempts: e.state.jobs[a.transferID]?.attempts ?? -1,
                transient: e.state.jobs[a.transferID]?.transientFailure ?? false,
                edge: e.state.networkEdgeSerial,
                conditionsNil: e.state.conditions == nil
            )
        }
        #expect(!read.owed && read.end != nil, "PROBE-C16R-RETRY-END-DIAG copy \(copy): before A's request \(before); at the committed read \(read)")
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading && $0.state.jobs[a.transferID]?.attempts == 1 }
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? aResult.get())?.byteSize == Int64(cBytes.count), "copy \(copy): A is served C by the retry: \(aResult)")
        await EngineFollowBarrierTests.finishHeld(s)
    }

    /// PROBE-C16R-RETRY-END-FIXED: the committed test with the fix this verification proposes: C's first attempt is held
    /// until the engine has its conditions reading (as `verdictBeforeApply` and `verdictLane` wait), so the reading is no
    /// edge that re-queues C during its backoff; then released, its publication fails (EIO) and the committed steps
    /// follow unchanged.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C16R-RETRY-END-FIXED", .timeLimit(.minutes(3)), arguments: 0..<24)
    func retryEndFixed(_ copy: Int) async throws {
        let seed: UInt64 = 1_616_102
        let (s, _) = try await EngineFollowBarrierTests.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: EngineFollowBarrierTests.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        await s.harness.serveManifest([s.q] + EngineFollowBarrierTests.FollowBarrier.fillers(seed + 100) + [a] + EngineFollowBarrierTests.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes), .hold, .stage(cBytes)])
        s.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .io))
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { e in
            if case .failed(.at) = e.state.jobs[a.transferID]?.state {
                return true
            }
            return false
        }
        let backingOff = await engine.readForTests { e in (owed: e.followOwed, end: e.state.jobs[a.transferID]?.attemptEnd) }
        try #require(!backingOff.owed && backingOff.end != nil, "PROBE-C16R-RETRY-END-FIXED copy \(copy) setup: the failed publication's end stays on C through its backoff: \(backingOff)")
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading && $0.state.jobs[a.transferID]?.attempts == 1 }
        }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "PROBE-C16R-RETRY-END-FIXED copy \(copy): the retry downloads with nothing of the publication before it: \(violations.prefix(3))")
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        #expect((try? aResult.get())?.byteSize == Int64(cBytes.count), "PROBE-C16R-RETRY-END-FIXED copy \(copy): A is served C by the retry: \(aResult)")
        await EngineFollowBarrierTests.finishHeld(s)
    }

    /// PROBE-C16R-RETRY-END-STRESS: the committed `barrierRetriesAFailedPublicationWithNothingOfItsEnd` itself, in
    /// concurrent copies.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C16R-RETRY-END-STRESS", .timeLimit(.minutes(3)), arguments: 0..<24)
    func retryEndStress(_ copy: Int) async throws {
        try await EngineFollowBarrierTests().barrierRetriesAFailedPublicationWithNothingOfItsEnd()
    }

    /// PROBE-C16R-RR11-RETRY-AFTER: `verdictLane`'s scenario (VerdictLaneTests `:38`) with O's attempt ending in a 503
    /// whose `Retry-After` (120 s) exceeds the user lane's cap (30 s, `shortInteractiveRetry`): `retryLater` finds no delay
    /// (`Backoff.delay` is `nil`) and answers every interest of O (`resolveAll`), A and B. Visited first, O's verdict
    /// answered B at its arrival and v4's visit found B answered: J's 429 (`Retry-After` 60 s) reads J's own prefetch
    /// lane and throttles the origin (R-SYN-5), and P, J's prefetch waiter, is served after the throttle. The draft's
    /// RR-11 records this verdict as counted "as none" by `verdictAnswers`, not probed.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C16R-RR11-RETRY-AFTER", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func rr11RetryAfter(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_616_802
        let (s, _) = try await EngineFollowBarrierTests.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: EngineFollowBarrierTests.shortInteractiveRetry))
        let engine = s.engine
        let oBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let jBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", oBytes)
        let b = EngineHarness.onDemand("zz-b", oBytes)
        let p = EngineHarness.onDemand("zz-p", jBytes)
        let bMoved = EngineHarness.onDemand("zz-b", jBytes)
        try #require(a.transferID == b.transferID && p.transferID == bMoved.transferID, "setup: zz-a and zz-b share O; zz-p and v4's zz-b share J")
        await s.harness.serveManifest([s.q] + EngineFollowBarrierTests.FollowBarrier.fillers(seed + 100) + [a, b, p] + EngineFollowBarrierTests.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .fail(.transient(.serverError(httpStatus: 503), retryAfter: .seconds(120)))])
        await s.harness.source.script(p.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(jBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .downloading }
        }
        let fillers = EngineFollowBarrierTests.FollowBarrier.fillers(seed + 200)
        try await EngineFollowBarrierTests.applyHeld([s.q] + fillers + [a, b, p] + EngineFollowBarrierTests.laterFillers(seed + 6_000), tag: "v3-rr11-\(seed)", s, visit: visit)
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
        } else {
            await engine.awaitCondition { e in
                guard let job = e.state.jobs[a.transferID] else {
                    return true
                }
                switch job.state {
                case .failed(.at), .failed(.nextRun), .blocked:
                    return true
                case .queued, .downloading, .verifying, .committing, .failed:
                    return false
                }
            }
        }
        let atVerdict = await engine.readForTests { e in
            (waiting: e.state.verdictsAfterFollow[a.transferID] != nil, oState: e.state.jobs[a.transferID].map { "\($0.state)" } ?? "nil", oInterests: e.state.jobs[a.transferID]?.interests.count ?? 0)
        }
        try await EngineFollowBarrierTests.applyHeld([s.q] + fillers + [a, bMoved, p] + EngineFollowBarrierTests.laterFillers(seed + 9_000), tag: "v4-rr11-\(seed)", s, visit: visit)
        await s.harness.source.release(p.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state != .downloading }
        let after429 = await engine.readForTests { e in
            (
                throttled: e.state.remote.flatMap { e.state.throttles[$0.originID] } != nil,
                jState: e.state.jobs[p.transferID].map { "\($0.state)" } ?? "nil",
                jLane: e.state.jobs[p.transferID].map { "\($0.lane)" } ?? "nil"
            )
        }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        await EngineFollowBarrierTests.finishHeld(s)
        let trace = "\(visit): at O's verdict \(atVerdict); after J's 429 \(after429); A \(aResult); B \(bResult); P \(pResult)"
        #expect(after429.throttled, "PROBE-C16R-RR11-RETRY-AFTER: J's 429 throttles the origin on J's own prefetch lane, B answered by O's verdict (visit-first): \(trace)")
        #expect((try? pResult.get())?.byteSize == Int64(jBytes.count), "PROBE-C16R-RR11-RETRY-AFTER: P is served J after the throttle (visit-first): \(trace)")
        guard case .failure = bResult else {
            Issue.record("PROBE-C16R-RR11-RETRY-AFTER: B is answered by O's verdict (visit-first): \(trace)")
            return
        }
    }
}
