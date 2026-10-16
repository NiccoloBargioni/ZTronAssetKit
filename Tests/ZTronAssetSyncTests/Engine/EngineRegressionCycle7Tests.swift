import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Regressions the verifiers of close-out cycle 6 found in WP-F (cycle 7 of the level-4 close-out). Each failed before
/// its fix (`docs/adr-drafts/f.md`, F-27).
@Suite("Engine regressions, close-out cycle 7")
struct EngineRegressionCycle7Tests {
    /// Who waits for the transfer: a `resolve` and an `ensureAvailable` (the interactive budget) or a run (the background
    /// budget).
    enum Caller: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case resolve
        case ensure
        case run

        var testDescription: String {
            self.rawValue
        }
    }

    // MARK: ENOSPC on a roomy volume while the store holds bytes it has not scheduled to reclaim (R-SYN-11, L4-R4)

    /// PROBE-C6R-1 (review of close-out cycle 6, blocking): an attempt that failed with ENOSPC while the store counted
    /// pending reclaim parked `awaitingSpace` without counting toward the retry budget. With nothing scheduled to reclaim
    /// those bytes, the settlement's fresh free-space read held the job and re-queued it at once, the next attempt failed
    /// with ENOSPC again, and so on: a volume that keeps answering ENOSPC while it reads roomy meant one transfer start
    /// per failure, without end (the verifier measured 503 starts for 500 scripted failures). L4-R4 bounds that loop by
    /// the ordinary retry budget and ends it in a typed `insufficientSpace`. The setup is the cycle-5 test
    /// `unscheduledReclaimFailsTyped`'s (`x`'s pruned bytes wait for an acknowledgement nobody gives, with no store
    /// deadline) on a volume with ample room.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-11: a volume that keeps answering ENOSPC while the store holds bytes it has not scheduled to reclaim ends in insufficientSpace once the retry budget is spent",
        .timeLimit(.minutes(1)),
        arguments: Caller.allCases
    )
    func enospcWithUnscheduledReclaimIsBounded(caller: Caller) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 100_000, opportunisticCapacity: reserve + 100_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 0), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = EngineFixture.bytes(9_981, count: 300)
        let yBytes = EngineFixture.bytes(9_982, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let y = EngineHarness.onDemand("y", yBytes)
        await harness.serveManifest([x])
        await harness.scriptTransfers([(x, xBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        // v2 prunes x and lists the on-demand y; no install is acknowledged from now on, so x's bytes stay pending
        // reclaim with nothing scheduled. No ballast: the volume reads roomy.
        await harness.sink.setBehaviour(.ignore)
        await harness.serveManifest([y], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's pruned bytes wait for reclaim")
        #expect(await harness.store.nextDeadline() == nil, "setup: the store schedules no work that would reclaim them")
        let budget = caller == .run ? RetryPolicy.background.maxAttemptsPerRun : RetryPolicy.interactive.maxAttemptsPerRun
        // Far more ENOSPC failures than the budget, then a success: an attempt past the budget consumes one, and the
        // loop the review found reached the success after every failure.
        let failures = Array(repeating: FakeTransferStep.fail(.insufficientSpace(requiredBytes: 10)), count: budget + 20)
        await harness.source.script(y.transferID, failures + [.stage(yBytes)])
        switch caller {
        case .resolve:
            let result = await harness.withClock { await engine.awaitAsset("y", lane: .userInitiated) }
            if case .failure(.insufficientSpace(let required, let available)) = result {
                #expect(required == 10, "the figures the ENOSPC reported")
                #expect(available >= Int64(yBytes.count), "the volume read roomy: the room above the reserve holds y (\(available))")
            } else {
                Issue.record("expected insufficientSpace once the budget is spent, got \(result)")
            }
        case .ensure:
            let result = await harness.withClock { await engine.ensureAvailable(scope: .identifiers(["y"])) }
            if case .failure(.insufficientSpace(let required, let available)) = result {
                #expect(required == 10, "the figures the ENOSPC reported")
                #expect(available >= Int64(yBytes.count), "the volume read roomy: the room above the reserve holds y (\(available))")
            } else {
                Issue.record("expected insufficientSpace once the budget is spent, got \(result)")
            }
        case .run:
            // v3 lists y as a standard entry, so the run fetches it; nothing is pruned (x's bytes still wait).
            await harness.serveManifest([EngineFixture.entry("y", yBytes)], etag: "v3")
            let outcome = try await harness.syncDriven()
            if case .completeWithFailures(let report) = outcome {
                #expect(report.failures.map(\.failureClass) == [.insufficientSpace], "\(report.failures)")
            } else {
                Issue.record("expected the run to end with y failed, got \(outcome)")
            }
        }
        // The job ended with its last interest: no attempt can follow.
        await engine.awaitCondition { $0.state.jobs[y.transferID] == nil }
        let starts = await harness.source.starts.filter { $0.id == y.transferID }.count
        #expect(starts == budget, "one start per attempt of the budget (\(budget)), then none: \(starts) starts")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }
}
