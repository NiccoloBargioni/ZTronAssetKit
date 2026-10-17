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

    /// The cycle-5 test `unscheduledReclaimFailsTyped`'s setup on a volume with `reserve + 100,000` bytes and no
    /// ballast: `x` (300 B) was pruned by v2, which lists the on-demand `y` (300 B); the snapshot sink keeps every
    /// install from then on, so `x`'s bytes wait for an acknowledgement nobody gives, pending reclaim with no store
    /// deadline. Returns the harness (started, with `y` absent), `y`'s entry and its bytes.
    @available(macOS 15.0, iOS 18.0, *)
    static func unscheduledReclaim(seed: UInt64) async throws -> (EngineHarness, ManifestEntry, Data) {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 100_000, opportunisticCapacity: reserve + 100_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 0), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = EngineFixture.bytes(seed, count: 300)
        let yBytes = EngineFixture.bytes(seed + 1, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let y = EngineHarness.onDemand("y", yBytes)
        await harness.serveManifest([x])
        await harness.scriptTransfers([(x, xBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await harness.sink.setBehaviour(.ignore)
        await harness.serveManifest([y], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's pruned bytes wait for reclaim")
        #expect(await harness.store.nextDeadline() == nil, "setup: the store schedules no work that would reclaim them")
        return (harness, y, yBytes)
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
        let (harness, y, yBytes) = try await Self.unscheduledReclaim(seed: 9_981)
        let engine = harness.engine
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

    // MARK: An ENOSPC's figures through the settlement (R-SYN-11, F-22; review of close-out cycle 6, L4-R12)

    /// Review of close-out cycle 6 (non-blocking): a job parked `awaitingSpace` after an ENOSPC that asked for more than
    /// its entry's size, then parked `insufficientSpace` by the settlement because nothing will reclaim on time, must
    /// answer the bytes the ENOSPC asked for (the transport knows the attempt's need better than the manifest's size)
    /// against the room the settlement's fresh read leaves it above the reserve (F-22's convention), and must not start
    /// the transfer again while the volume cannot hold that much.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-11: an ensure whose member waits for space after an ENOSPC asking for more than the entry fails with the bytes the ENOSPC asked for and the room above the reserve",
        .timeLimit(.minutes(1))
    )
    func enospcFiguresSurviveTheSettlement() async throws {
        let (harness, y, _) = try await Self.unscheduledReclaim(seed: 9_983)
        let engine = harness.engine
        // Ten times the volume's room: no reclaim can make it fit.
        await harness.source.script(y.transferID, [.fail(.insufficientSpace(requiredBytes: 1_000_000))])
        let result = await harness.withClock { await engine.ensureAvailable(scope: .identifiers(["y"])) }
        let space = try await harness.store.freeSpace()
        if case .failure(.insufficientSpace(let required, let available)) = result {
            #expect(required == 1_000_000, "the bytes the ENOSPC asked for, not the entry's 300")
            #expect(available == space.volumeImportant - space.reserveBytes, "the room above the reserve: \(available) against \(space)")
        } else {
            Issue.record("expected the ENOSPC's figures, got \(result)")
        }
        await engine.awaitCondition { $0.state.jobs[y.transferID] == nil }
        #expect(await harness.source.starts.filter { $0.id == y.transferID }.count == 1, "one attempt: the volume never held 1,000,000 bytes")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }
}
