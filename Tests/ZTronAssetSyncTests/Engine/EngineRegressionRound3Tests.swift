import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Regressions the level-4 verifiers found in WP-F verification round 3, and the behaviour the orchestrator's close-out
/// rulings pin (L4-R4 to L4-R7, L4-R9). Each regression test failed before its fix (`docs/adr-drafts/f.md`, F-21).
@Suite("Engine regressions, round 3")
struct EngineRegressionRound3Tests {
    // MARK: Present assets get no job (L4-R5: ARCHITECTURE §7.1 "only outstanding work has a job", T22, R-NET-6)

    /// A waiter downloads x@c1 when a run applies v2, which gives x the content y already holds: the store binds x to
    /// y's blob (a reuse) and the engine moves the waiter to that content (T22). `shared` scripts what a download of
    /// the shared content would do.
    @available(macOS 15.0, iOS 18.0, *)
    static func reuseWhileWaiting(
        _ seed: UInt64,
        shared script: [FakeTransferStep]
    ) async throws -> (harness: EngineHarness, waiter: Task<Result<AssetLocation, AssetError>, Never>, y: ManifestEntry, bytes: Data) {
        let harness = EngineHarness.make()
        let c1 = EngineFixture.bytes(seed)
        let shared = EngineFixture.bytes(seed + 1)
        let x1 = EngineHarness.onDemand("x", c1)
        let y = EngineFixture.entry("y", shared)
        let x2 = EngineHarness.onDemand("x", shared)
        #expect(x2.transferID == y.transferID, "identical bytes share one transfer (ADR-020)")
        await harness.serveManifest([x1, y])
        await harness.scriptTransfers([(y, shared)])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        #expect(try await harness.view().records["y"]?.referencedBlob != nil, "the run fetched y")
        await harness.source.script(x1.transferID, [.hold, .stage(c1)])
        await harness.source.script(y.transferID, script)
        let waiter = Task { await engine.awaitAsset("x", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(x1.transferID)
        await harness.serveManifest([x2, y], etag: "v2")
        _ = await engine.sync(.force)
        let record = try #require(try await harness.view().records["x"])
        #expect(record.entry.contentIdentity == x2.contentIdentity, "the run applied v2")
        return (harness, waiter, y, shared)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a waiter whose asset an apply binds to content already present is answered from the store and downloads nothing", .timeLimit(.minutes(1)))
    func reusedContentAnsweredFromStore() async throws {
        let shared = EngineFixture.bytes(4_102)
        let (harness, waiter, y, bytes) = try await EngineRegressionRound3Tests.reuseWhileWaiting(4_101, shared: [.stage(shared)])
        let engine = harness.engine
        let result = await waiter.value
        #expect(result.map(\.byteSize) == .success(Int64(bytes.count)), "x is present at its new content, got \(result)")
        #expect(await harness.source.starts.filter { $0.id == y.transferID }.count == 1, "the shared content was fetched once, by the first run")
        #expect(try await harness.view().records["x"]?.referencedBlob != nil)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-6: a 404 for content an apply already bound never fails the asset that holds it", .timeLimit(.minutes(1)))
    func reusedContentSurvivesA404() async throws {
        let (harness, waiter, y, bytes) = try await EngineRegressionRound3Tests.reuseWhileWaiting(4_111, shared: [.fail(.permanentMissing(httpStatus: 404))])
        let engine = harness.engine
        let result = await waiter.value
        #expect(result.map(\.byteSize) == .success(Int64(bytes.count)), "got \(result)")
        let record = try #require(try await harness.view().records["x"])
        #expect(record.referencedBlob != nil && !record.isStale, "x keeps its valid local copy: \(record.residency)")
        let again = await engine.awaitAsset("x", lane: .userInitiated)
        #expect(again.map(\.byteSize) == .success(Int64(bytes.count)), "a fresh resolve is served from the store, got \(again)")
        #expect(await harness.source.starts.filter { $0.id == y.transferID }.count == 1)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: ensureAvailable does not download a member another interest committed after its plan", .timeLimit(.minutes(1)))
    func ensureSkipsMembersCommittedSincePlan() async throws {
        // One member at a time (pipelineDepth × maxConcurrentTransfers + runLookahead = 1).
        let tuning = SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0, pipelineDepth: 1, runLookahead: 0)
        let harness = EngineHarness.make(tuning: tuning)
        let b0 = EngineFixture.bytes(4_201)
        let b1 = EngineFixture.bytes(4_202)
        let e0 = EngineHarness.onDemand("e0", b0)
        let e1 = EngineHarness.onDemand("e1", b1)
        await harness.serveManifest([e0, e1])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        // e0 fails once and waits for its retry; e1 is scripted twice so that a second download completes (and is
        // counted) instead of hanging.
        await harness.source.script(e0.transferID, [.fail(.transient(.connectionLost(resumable: false), retryAfter: nil)), .stage(b0)])
        await harness.source.script(e1.transferID, [.stage(b1), .stage(b1)])
        let ensure = Task { await engine.ensureAvailable(scope: .identifiers(["e0", "e1"])) }
        await engine.awaitCondition { engine in
            if case .failed(.at)? = engine.state.jobs[e0.transferID]?.state {
                return true
            }
            return false
        }
        // Another interest downloads and commits e1 while the ensure waits for e0's retry.
        let other = await engine.awaitAsset("e1", lane: .prefetch)
        #expect(other.map(\.byteSize) == .success(Int64(b1.count)))
        let report = try await harness.withClock { try await ensure.value.get() }
        #expect(report.isComplete && report.present == 2, "\(report)")
        #expect(await harness.source.starts.filter { $0.id == e1.transferID }.count == 1, "e1 was present when the ensure reached it")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run does not download an asset another interest committed after its plan, and counts it as fetched", .timeLimit(.minutes(1)))
    func runSkipsAssetsCommittedSincePlan() async throws {
        let tuning = SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0, pipelineDepth: 1, runLookahead: 0)
        let harness = EngineHarness.make(tuning: tuning)
        let b0 = EngineFixture.bytes(4_301)
        let b1 = EngineFixture.bytes(4_302)
        let r0 = EngineHarness.onDemand("r0", b0)
        let r1 = EngineHarness.onDemand("r1", b1)
        await harness.serveManifest([r0, r1])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        // An explicit retention scope puts both on-demand entries in runs.
        _ = try await engine.setRetentionScope(.identifiers(["r0", "r1"])).get()
        await harness.source.script(r0.transferID, [.fail(.transient(.connectionLost(resumable: false), retryAfter: nil)), .stage(b0)])
        await harness.source.script(r1.transferID, [.stage(b1), .stage(b1)])
        let run = Task { await engine.sync(.force) }
        await engine.awaitCondition { engine in
            if case .failed(.at)? = engine.state.jobs[r0.transferID]?.state {
                return engine.state.run?.transferring == true
            }
            return false
        }
        let other = await engine.awaitAsset("r1", lane: .prefetch)
        #expect(other.map(\.byteSize) == .success(Int64(b1.count)))
        let outcome = await harness.withClock { await run.value }
        let report = try #require(outcome.completeReport, "\(outcome)")
        #expect(report.fetched == 2, "the run counts r1, present when it reached it, as fetched")
        #expect(await harness.source.starts.filter { $0.id == r1.transferID }.count == 1, "r1 was present when the run reached it")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-6: a 404 never marks failed an asset the store bound to that content while the transfer ran", .timeLimit(.minutes(1)))
    func failureSparesAssetBoundMeanwhile() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(4_401)
        let x = EngineHarness.onDemand("x", bytes)
        await harness.serveManifest([x])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(x.transferID, [.hold])
        let waiter = Task { await engine.awaitAsset("x", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(x.transferID)
        // The store binds x to its content behind the engine's back (as a legacy adoption would), then the origin
        // answers 404 for that content.
        let sink = try #require(await harness.source.attachedStaging)
        let name = StagingFileName(transfer: x.transferID, attempt: TransferAttempt(epoch: 99, sequence: 1), kind: .partial)
        try sink.createPartial(name)
        _ = try sink.appendPartial(bytes, to: name)
        let staged = StagedFile(name: name, byteCount: Int64(bytes.count), resumed: false, httpStatus: 200, etag: nil)
        _ = try await harness.store.publish(staged, binding: ["x"], expecting: x.contentIdentity, urgency: .userInitiated)
        await harness.source.release(x.transferID, with: .failed(.permanentMissing(httpStatus: 404)))
        let result = await waiter.value
        #expect(result.map(\.byteSize) == .success(Int64(bytes.count)), "x is present: never notFound, got \(result)")
        let record = try #require(try await harness.view().records["x"])
        #expect(record.referencedBlob != nil, "the valid local copy is kept: \(record.residency)")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    // MARK: Space and staging (L4-R6: R-SYN-11 / S2-23 headroom ledger, R-CLN-3 staging hygiene)

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: ensureAvailable's plan against important capacity never admits a prefetch parked for opportunistic space", .timeLimit(.minutes(1)))
    func ensureKeepsOpportunisticLedger() async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        // Room for user work, none for opportunistic work.
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: 64 << 30, opportunisticCapacity: reserve + 100)
        )
        let harness = EngineHarness.make(time: time, fileSystem: fileSystem)
        let pBytes = EngineFixture.bytes(4_501, count: 300)
        let qBytes = EngineFixture.bytes(4_502, count: 32)
        let p = EngineHarness.onDemand("p", pBytes)
        let q = EngineHarness.onDemand("q", qBytes)
        await harness.serveManifest([p, q])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(p.transferID, [.stage(pBytes)])
        await harness.source.script(q.transferID, [.stage(qBytes)])
        let group = try await engine.registerGroup(["p"], lane: .prefetch).get()
        await engine.waitUntil { ($0.jobsByState[.blocked] ?? 0) == 1 }
        let report = try await engine.ensureAvailable(scope: .identifiers(["q"])).get()
        #expect(report.isComplete && report.present == 1, "user work plans against important capacity: \(report)")
        #expect(await engine.jobStateForTests(p.transferID) == .blocked, "opportunistic capacity did not change")
        #expect(await harness.source.starts.filter { $0.id == p.transferID }.isEmpty)
        await engine.releaseGroup(group)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-3: an attempt that fails for lack of space leaves no partial without a sidecar in staging", .timeLimit(.minutes(1)))
    func noSpacePartialDiscarded() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(4_601)
        let x = EngineHarness.onDemand("x", bytes)
        await harness.serveManifest([x])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(x.transferID, [.hold, .stage(bytes)])
        let waiter = Task { await engine.awaitAsset("x", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(x.transferID)
        let first = try #require(await harness.source.starts.last)
        // What the staging sink leaves when a write hits ENOSPC: the bytes written before it, and no sidecar.
        let sink = try #require(await harness.source.attachedStaging)
        try sink.createPartial(first.partialName)
        _ = try sink.appendPartial(Data(repeating: 7, count: 120), to: first.partialName)
        // A 64 GiB volume holds the job: the engine retries (F-20).
        await harness.source.release(x.transferID, with: .failed(.insufficientSpace(requiredBytes: 300)))
        let result = await harness.withClock { await waiter.value }
        #expect(result.map(\.byteSize) == .success(Int64(bytes.count)), "\(result)")
        await engine.waitUntil { $0.jobsByState.isEmpty }
        let inventory = try await harness.store.stagingInventory()
        let left = inventory.items.keys.filter { $0.transfer == x.transferID && $0.attempt == first.attempt }
        #expect(left.isEmpty, "the dead partial occupies the space that is short: \(left)")
        await engine.shutdown()
    }

    // MARK: ENOSPC on a roomy volume is retried within the ordinary budget (L4-R4)

    /// Who waits for the transfer: a `resolve` (the interactive budget) or a run (the background budget).
    enum SpaceRetryCaller: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case resolve
        case run

        var testDescription: String {
            self.rawValue
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-11: a volume that keeps answering ENOSPC while it reads roomy ends in insufficientSpace once the retry budget is spent",
        .timeLimit(.minutes(1)),
        arguments: SpaceRetryCaller.allCases
    )
    func spaceRetriesAreBounded(caller: SpaceRetryCaller) async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(4_901)
        // Standard for the run (runs fetch it), on demand for the resolve (the first sync leaves it absent).
        let x = caller == .run ? EngineFixture.entry("x", bytes) : EngineHarness.onDemand("x", bytes)
        let budget = caller == .run ? RetryPolicy.background.maxAttemptsPerRun : RetryPolicy.interactive.maxAttemptsPerRun
        // More failures than the budget: an attempt past it would consume one.
        let failures = Array(repeating: FakeTransferStep.fail(.insufficientSpace(requiredBytes: 10)), count: budget + 3)
        let engine = harness.engine
        switch caller {
        case .resolve:
            await harness.serveManifest([x])
            try await harness.start()
            _ = try #require(await engine.sync(.force).completeReport)
            await harness.source.script(x.transferID, failures)
            let result = await harness.withClock { await engine.awaitAsset("x", lane: .userInitiated) }
            guard case .failure(.insufficientSpace(let required, _)) = result else {
                Issue.record("expected insufficientSpace once the budget is spent, got \(result)")
                await engine.shutdown()
                return
            }
            #expect(required == 10, "the figures the ENOSPC reported")
        case .run:
            await harness.serveManifest([x])
            await harness.source.script(x.transferID, failures)
            try await harness.start()
            let outcome = try await harness.syncDriven()
            guard case .completeWithFailures(let report) = outcome else {
                Issue.record("expected the run to end with x failed, got \(outcome)")
                await engine.shutdown()
                return
            }
            #expect(report.failures.map(\.failureClass) == [.insufficientSpace], "\(report.failures)")
        }
        try await harness.settle()
        #expect(await harness.source.starts.filter { $0.id == x.transferID }.count == budget, "one start per attempt of the budget, then none")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }
}
