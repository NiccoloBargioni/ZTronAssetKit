import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A `FakeRemoteSource` that keeps source copies and reports every release it is asked for as failed (R-CLN-10): the
/// engine records the failure for diagnostics (Stage 3, S3-CONF-08). An actor: no lock (C1).
@available(macOS 15.0, iOS 18.0, *)
actor ReclaimFailingSource: RemoteSource, StagingAttachable {
    let base: FakeRemoteSource
    /// The capabilities of a source that keeps copies, on the AWS tier (no Apple-tier gating).
    static let keeping = RemoteSourceCapabilities(tier: .aws, supportsPriority: true, supportsResume: true, supportsBackground: false, keepsSourceCopies: true)
    private(set) var reclaims = 0

    nonisolated var originID: String {
        self.base.originID
    }

    nonisolated var capabilities: RemoteSourceCapabilities {
        Self.keeping
    }

    init(base: FakeRemoteSource) {
        self.base = base
    }

    func attach(staging: any StagingSink) async {
        await self.base.attach(staging: staging)
    }

    func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        try await self.base.fetchManifest(request)
    }

    func transfer(_ request: TransferRequest) async -> any TransferHandle {
        await self.base.transfer(request)
    }

    func reattachedTransfers() async -> [ReattachedTransfer] {
        await self.base.reattachedTransfers()
    }

    func cancelTransfer(_ name: StagingFileName) async {
        await self.base.cancelTransfer(name)
    }

    func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport {
        self.reclaims += 1
        return ReclaimReport(released: [], failed: ["pack-a": .transient(.unknown(urlErrorCode: 0), retryAfter: nil), "pack-b": .permanentMissing(httpStatus: 404)])
    }

    func sourceCopyBytes() async -> Int64 {
        await self.base.sourceCopyBytes()
    }

    func handleBackgroundEvents(identifier: String) async {
        await self.base.handleBackgroundEvents(identifier: identifier)
    }

    func invalidate() async {
        await self.base.invalidate()
    }
}

/// Maintenance's paths between and inside its steps (R-SYN-16, L4-R5; ARCHITECTURE §7.10) and the record of source
/// copies a source could not release (R-CLN-10): paths no earlier test ran (Stage 3, S3-CONF-08).
extension EngineCommandTests {
    /// An engine over a synced two-asset catalog whose bulk executor `bulk` can hold one store unit.
    @available(macOS 15.0, iOS 18.0, *)
    static func maintainedHarness(_ bulk: NextUnitGate) async throws -> EngineHarness {
        let harness = EngineHarness.make(bulk: bulk)
        let catalog = EngineSyncTests.catalog(2, prefix: "kept")
        await harness.serve(catalog)
        try await harness.start()
        _ = try #require(try await harness.syncDriven().completeReport)
        return harness
    }

    /// Maintenance checks its deadline between steps: when the time budget runs out while orphan collection runs (its
    /// sweep decision is held on the bulk executor and the clock passes the deadline meanwhile), it stops before
    /// eviction and deep verification, reports the budget exhausted and announces the report; a maintenance with time
    /// to spare verifies the present assets, so the first one stopped before that step.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-16: maintenance whose time budget runs out during orphan collection stops before eviction and verification and reports the budget exhausted", .timeLimit(.minutes(1)))
    func maintenanceStopsBetweenSteps() async throws {
        let bulk = NextUnitGate()
        let harness = try await Self.maintainedHarness(bulk)
        let engine = harness.engine
        let probe = EventProbe(stream: try await engine.subscribe().get())
        await bulk.holdNext()
        let maintenance = Task { await engine.performMaintenance(timeBudget: 5) }
        await bulk.waitForHold()
        harness.time.advance(by: 6)
        await bulk.release()
        let report = try await EngineHarness.value(of: maintenance).get()
        #expect(report.budgetExhausted, "\(report)")
        #expect(report.evictedBytes == 0 && report.verifiedBytes == 0 && report.corruptFound == 0, "no step ran after the deadline: \(report)")
        let announced = await probe.next { if case .maintenanceFinished = $0 { return true } else { return false } }
        #expect(announced == .maintenanceFinished(report), "the report is announced: \(String(describing: announced))")
        let full = try await engine.performMaintenance(timeBudget: 600).get()
        #expect(full.verifiedBytes > 0 && !full.budgetExhausted, "with time to spare verification reads the present assets: \(full)")
        await probe.stop()
        await engine.shutdown()
    }

    /// The deadline check after orphan collection keeps eviction from running too: on a store over its byte budget whose
    /// assets are out of the retention scope, so that eviction would free them, a maintenance whose time budget runs out
    /// while orphan collection runs evicts nothing and keeps every asset. A maintenance with time to spare then evicts
    /// them, so the first one stopped before a step that had work to do (the close-out cycle-2 requirements lens: with
    /// nothing to evict, a maintenance that skipped this check reported the same).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-16: maintenance whose time budget runs out during orphan collection evicts nothing from a store over its budget", .timeLimit(.minutes(1)))
    func maintenanceStopsBeforeEviction() async throws {
        let time = ManualTimeSource()
        let catalog = EngineSyncTests.catalog(2, prefix: "spent")
        let first = EngineHarness.make(time: time)
        await first.serve(catalog)
        try await first.start()
        _ = try #require(try await first.syncDriven().completeReport)
        await first.engine.shutdown()
        time.advance(by: 3_600)
        let bulk = NextUnitGate()
        let storage = StoragePolicy(budget: .bytes(64), reserveFreeBytes: 0, minimumResidency: 0)
        let second = EngineHarness.make(disk: first.fileSystem.survivingDisk(), time: time, storage: storage, bulk: bulk)
        try await second.start()
        let engine = second.engine
        try await engine.setRetentionScope(.tags(["none"])).get()
        await bulk.holdNext()
        let maintenance = Task { await engine.performMaintenance(timeBudget: 5) }
        await bulk.waitForHold()
        time.advance(by: 6)
        await bulk.release()
        let report = try await EngineHarness.value(of: maintenance).get()
        #expect(report.budgetExhausted && report.evictedBytes == 0, "no eviction ran after the deadline: \(report)")
        let view = try await second.view()
        #expect(catalog.allSatisfy { view.records[$0.0.identifier]?.referencedBlob != nil }, "every asset is still present")
        let full = try await engine.performMaintenance(timeBudget: 600).get()
        #expect(full.evictedBytes > 0, "with time to spare eviction frees what the stopped maintenance kept: \(full)")
        await engine.shutdown()
    }

    /// A maintenance step cancelled by shutdown (its orphan collection held on the bulk executor while the shutdown
    /// cancels the engine's tasks) throws `cancelled`: the engine trusts no binding learned during maintenance and
    /// answers `shutDown` once the engine has stopped.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-16: a maintenance step cancelled by shutdown answers shutDown", .timeLimit(.minutes(1)))
    func maintenanceStepCancelledByShutdown() async throws {
        let bulk = NextUnitGate()
        let harness = try await Self.maintainedHarness(bulk)
        let engine = harness.engine
        await bulk.holdNext()
        let maintenance = Task { await engine.performMaintenance(timeBudget: 600) }
        await bulk.waitForHold()
        let forgets = await engine.readForTests { $0.state.ledgerForgets }
        let shutdown = Task { await engine.shutdown() }
        await engine.waitUntil { $0.lifecycle == .shuttingDown }
        await bulk.release()
        await EngineHarness.value(of: shutdown)
        #expect(await EngineHarness.value(of: maintenance) == .failure(.shutDown))
        #expect(await engine.readForTests { $0.state.ledgerForgets } != forgets, "the bindings were dropped after the cancelled step")
    }

    /// A maintenance step that throws (the staging listing fails with EIO) ends the maintenance with that error mapped to
    /// the public error; no report is announced, and the next maintenance runs normally.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-16: a maintenance step that throws fails the maintenance with the mapped error and the next one runs", .timeLimit(.minutes(1)))
    func maintenanceStepThrows() async throws {
        let bulk = NextUnitGate()
        let harness = try await Self.maintainedHarness(bulk)
        let engine = harness.engine
        let forgets = await engine.readForTests { $0.state.ledgerForgets }
        harness.fileSystem.addFault(FaultRule(operation: .contentsOfDirectory, occurrence: .nth(1), error: .io))
        let failed = await engine.performMaintenance(timeBudget: 600)
        #expect(failed == .failure(.storageUnavailable(.ioFailure)), "\(failed)")
        #expect(await engine.readForTests { $0.state.ledgerForgets } - forgets >= 2, "the bindings were dropped at the start and after the failed step")
        #expect(await engine.readForTests { $0.isRunning }, "the engine keeps running")
        let next = await engine.performMaintenance(timeBudget: 600)
        #expect((try? next.get()) != nil, "the next maintenance runs: \(next)")
        await engine.shutdown()
    }

    /// A source that keeps source copies is told what the store adopted after a run, and releases it can't make are
    /// recorded for diagnostics (R-CLN-10, ADR-027): the run still completes.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-10: source copies a source fails to release after a run are recorded for diagnostics", .timeLimit(.minutes(1)))
    func failedSourceCopyReleasesAreRecorded() async throws {
        let base = FakeRemoteSource()
        let keeping = ReclaimFailingSource(base: base)
        let harness = EngineHarness.make(source: base, remote: keeping)
        let catalog = EngineSyncTests.catalog(2, prefix: "copied")
        await harness.serve(catalog)
        try await harness.start()
        let engine = harness.engine
        #expect(try await harness.syncDriven().completeReport != nil)
        await engine.awaitCondition { engine in
            engine.state.recentErrors.contains { $0.detail.contains("source copies could not be released") }
        }
        let recorded = await engine.readForTests { $0.state.recentErrors.filter { $0.detail.contains("source copies could not be released") }.map(\.detail) }
        #expect(recorded.contains { $0.hasPrefix("2 source copies") }, "\(recorded)")
        #expect(await keeping.reclaims >= 1)
        await engine.shutdown()
    }
}
