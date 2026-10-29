import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The sync-1 regression tests ARCHITECTURE §12.3 names for S1-01, S1-12 and S1-15's run form (Stage 3, S3-B-068).
extension EngineRegressionTests {
    /// Whether the heap holds a retry deadline for `transfer`.
    static func retryScheduled(_ engine: isolated SyncEngine, _ transfer: TransferID) -> Bool {
        engine.state.heap.entries.contains { deadline in
            if case .retry(transfer, _) = deadline.reason {
                return true
            }
            return false
        }
    }

    /// Whether `residency` is present.
    static func isPresent(_ residency: Residency?) -> Bool {
        if case .present? = residency {
            return true
        }
        return false
    }

    /// A job whose only interest leaves while its publication verifies is removed when the verification finds the bytes
    /// corrupt, never retried: no backoff deadline, no second transfer, however far the clock moves (sync-1 S1-01; one
    /// `retire` funnel, no-interest jobs leave verifying and committing by removal, §7.1).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a job whose last interest left during verification is not retried after an integrity failure", .timeLimit(.minutes(1)))
    func noRetryAfterIntegrityFailureWithoutInterest() async throws {
        let bulk = NextUnitGate()
        let harness = EngineHarness.make(bulk: bulk)
        let good = EngineFixture.bytes(8_101)
        let entry = EngineHarness.onDemand("verify-left", good)
        try await EngineSingleFlightTests.applied([entry], harness: harness)
        let engine = harness.engine
        // The transfer stages other bytes of the same size: the publication's verification finds them corrupt.
        await harness.source.script(entry.transferID, [.hold, .stage(EngineFixture.bytes(8_102))])
        let waiter = Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[entry.transferID]?.state == .downloading }
        await engine.waitForHandle(entry.transferID)
        await bulk.holdNext()
        await harness.source.release(entry.transferID, with: .progress(received: 0, expected: nil))
        await bulk.waitForHold()
        #expect(await engine.readForTests { $0.state.jobs[entry.transferID]?.state } == .verifying, "the publication verifies")
        // The only interest leaves while the publication verifies.
        waiter.cancel()
        #expect(await waiter.value == .failure(.cancelled), "the cancelled caller is answered at once")
        #expect(await engine.readForTests { $0.state.jobs[entry.transferID]?.interests.isEmpty } == true, "the job verifies with no interest")
        await bulk.release()
        await engine.awaitCondition { $0.state.jobs[entry.transferID] == nil }
        harness.time.advance(by: 3_600)
        let after = await engine.readForTests { engine in
            (
                retry: Self.retryScheduled(engine, entry.transferID),
                job: engine.state.jobs[entry.transferID] != nil,
                illegal: engine.state.metrics.illegalTransitions,
                violations: engine.invariantViolations()
            )
        }
        #expect(!after.retry && !after.job, "the integrity failure removed the job and scheduled no retry")
        #expect(await harness.source.starts.count == 1, "the asset was never downloaded again")
        #expect(after.illegal == 0)
        #expect(after.violations.isEmpty, "\(after.violations)")
        await engine.shutdown()
    }

    /// A publication whose job lost its last interest while it verified still commits (the store binds the content), and
    /// the engine then removes the job and frees its place in the verify and commit pipeline: a prefetch member that
    /// waited for that place starts (sync-1 S1-01, §7.1, §7.4). A stale commit that kept the job would hold the place for
    /// good.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: a stale commit with no interests removes the job and frees its pipeline slot", .timeLimit(.minutes(1)))
    func staleCommitFreesPipelineSlot() async throws {
        let bulk = NextUnitGate()
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0, pipelineDepth: 1), bulk: bulk)
        let aBytes = EngineFixture.bytes(8_201)
        let bBytes = EngineFixture.bytes(8_202)
        let a = EngineHarness.onDemand("stale-a", aBytes)
        let b = EngineHarness.onDemand("stale-b", bBytes)
        try await EngineSingleFlightTests.applied([a, b], harness: harness)
        let engine = harness.engine
        await harness.source.script(a.transferID, [.hold, .stage(aBytes)])
        await harness.source.script(b.transferID, [.stage(bBytes)])
        let first = try await engine.registerGroup([a.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        await engine.waitForHandle(a.transferID)
        let second = try await engine.registerGroup([b.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state == .queued }
        await bulk.holdNext()
        await harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await bulk.waitForHold()
        let held = await engine.readForTests { engine in (engine.state.jobs[a.transferID]?.state, engine.state.jobs[b.transferID]?.state) }
        #expect(held.0 == .verifying && held.1 == .queued, "a fills the one-deep pipeline and b waits with the transfer slot free: \(held)")
        // a's only interest leaves: the commit that follows is stale.
        await engine.releaseGroup(first)
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.isEmpty == true && $0.state.releasing.isEmpty }
        #expect(await engine.readForTests { $0.state.jobs[b.transferID]?.state } == .queued, "b still waits while a holds the pipeline")
        await bulk.release()
        await engine.awaitCondition { $0.state.jobs[a.transferID] == nil && $0.state.jobs[b.transferID] == nil }
        let starts = await harness.source.starts.map(\.id)
        #expect(starts == [a.transferID, b.transferID], "b started once a's stale commit freed the pipeline: \(starts)")
        let records = try await harness.view().records
        #expect(Self.isPresent(records[a.identifier]?.residency), "the stale commit still bound a's content")
        #expect(Self.isPresent(records[b.identifier]?.residency), "b was fetched")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.releaseGroup(second)
        await engine.shutdown()
    }

    /// An `ensureAvailable` member whose publication is held while a bulk sync commits every other asset (each commit moves
    /// the index generation and installs a snapshot) publishes and completes: the publication guards each entry's
    /// identity, never the whole snapshot's generation (sync-1 S1-12, ADR-030).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: ensureAvailable during a bulk sync never fails with storageUnavailable because of concurrent commits", .timeLimit(.minutes(1)))
    func ensureDuringBulkCommits() async throws {
        let bulk = NextUnitGate()
        let harness = EngineHarness.make(bulk: bulk)
        // Three bulk transfers fill the slots bulk work may take (one of the four is reserved for user work, which the
        // ensure's member takes).
        let catalog = (0..<3).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(8_300 + UInt64(index))
            return (EngineFixture.entry("bulk-\(index)", bytes), bytes)
        }
        let yBytes = EngineFixture.bytes(8_310)
        let y = EngineHarness.onDemand("ensured", yBytes)
        await harness.serveManifest(catalog.map(\.0) + [y])
        for (entry, bytes) in catalog {
            await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        }
        await harness.source.script(y.transferID, [.hold, .stage(yBytes)])
        try await harness.start()
        let engine = harness.engine
        let run = Task { await engine.sync(.force) }
        let bulkTransfers = catalog.map(\.0.transferID)
        await engine.awaitCondition { engine in bulkTransfers.allSatisfy { engine.state.jobs[$0]?.state == .downloading } }
        let ensure = Task { await engine.ensureAvailable(scope: .identifiers([y.identifier])) }
        await engine.awaitCondition { $0.state.jobs[y.transferID]?.state == .downloading }
        await engine.waitForAllHandles()
        // y's publication is held at its first store unit while every bulk asset commits.
        await bulk.holdNext()
        await harness.source.release(y.transferID, with: .progress(received: 0, expected: nil))
        await bulk.waitForHold()
        let generation = try await harness.view().generation
        for (entry, _) in catalog {
            await harness.source.release(entry.transferID, with: .progress(received: 0, expected: nil))
        }
        let outcome = await EngineHarness.value(of: run)
        #expect(outcome.completeReport?.fetched == catalog.count, "the bulk sync committed every asset: \(outcome)")
        #expect(try await harness.view().generation > generation, "the bulk commits moved the index generation while y's publication was held")
        await bulk.release()
        let ensured = await EngineHarness.value(of: ensure)
        guard case .success(let report) = ensured else {
            Issue.record("the ensure completes: \(ensured)")
            await engine.shutdown()
            return
        }
        #expect(report.isComplete && report.present == 1, "\(report)")
        let errors = await engine.readForTests { $0.state.recentErrors.map(\.detail) }
        #expect(!errors.contains { $0.contains("storageUnavailable") }, "\(errors)")
        await engine.shutdown()
    }

    /// A run over a 100,000-entry plan turns its fetches into jobs a pipeline at a time: at every notification of every
    /// turn the engine holds at most `pipelineDepth × maxConcurrentTransfers + runLookahead` jobs (sync-1 S1-15's run
    /// form, §7.3; the `ensureAvailable` form is `ensureMaterialisesInBatches`). The transfers wait unanswered, so the
    /// run never drains its plan; it ends at shutdown.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a 100,000-entry plan never materialises more than the pipeline plus the lookahead as jobs", .timeLimit(.minutes(1)))
    func runMaterialisesAPipelineAtATime() async throws {
        let tuning = SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0, pipelineDepth: 2, runLookahead: 4)
        let bound = tuning.pipelineDepth * tuning.maxConcurrentTransfers + tuning.runLookahead
        let harness = EngineHarness.make(tuning: tuning)
        let catalog = (0..<100_000).map { index in
            ManifestEntry(
                identifier: AssetID(String(format: "plan-%06d", index)),
                fileExtension: "png",
                remotePath: "media/plan-\(index).png",
                localPathComponents: ["dir"],
                byteSize: 16,
                checksum: ContentHash(w0: 0x5153_0000 + UInt64(index), w1: 1, w2: 2, w3: 3),
                tags: [],
                policy: .standard
            )
        }
        await harness.serveManifest(catalog)
        let engine = harness.engine
        let peak = Mutex(0)
        let sampler = Task {
            await engine.awaitCondition { engine in
                peak.withLock { $0 = max($0, engine.state.jobs.count) }
                return false
            }
        }
        try await harness.start()
        let run = Task { await engine.sync(.force) }
        // Both transfer slots are taken and the plan is materialised as far as it goes.
        await engine.awaitCondition { engine in
            engine.state.inFlight.count == tuning.maxConcurrentTransfers && engine.state.run?.transferring == true
        }
        let held = await engine.readForTests { engine in (jobs: engine.state.jobs.count, violations: engine.invariantViolations()) }
        await engine.shutdown()
        _ = await EngineHarness.value(of: run)
        sampler.cancel()
        await sampler.value
        let most = peak.withLock { $0 }
        #expect(most <= bound, "jobs at once: \(most), bound \(bound)")
        #expect(held.jobs >= tuning.maxConcurrentTransfers, "the run materialised its first fetches: \(held.jobs)")
        #expect(held.violations.isEmpty, "\(held.violations.prefix(3))")
        #expect(await harness.source.starts.count == tuning.maxConcurrentTransfers, "only the slots' transfers started")
    }
}
