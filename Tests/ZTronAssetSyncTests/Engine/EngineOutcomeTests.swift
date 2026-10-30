import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// What callers and run reports see when things go wrong: failure classes, publication faults, a breaker that is
/// already open, an engine started implicitly or whose store cannot open, a resolve during legacy migration, and the
/// invariant oracle the model test relies on (R-SYN-6, R-STO-6, R-SYN-5, R-CAR-1, R-STO-11, R-SYN-12).
@Suite("Engine outcomes")
struct EngineOutcomeTests {
    /// A transfer failure and the class a run reports for it.
    enum Failure: String, CaseIterable, Sendable {
        case integrity
        case rejected
        case authentication
        case serverError

        var error: TransferError {
            switch self {
            case .integrity:
                return .integrity(.sizeMismatch(expected: 300, actual: 12))
            case .rejected:
                return .rejected(.insecureScheme)
            case .authentication:
                return .authentication(.forbiddenAmbiguous(EngineFailurePathTests.evidence(.asset, xml: true, bytes: 120)))
            case .serverError:
                return .transient(.serverError(httpStatus: 503), retryAfter: nil)
            }
        }

        var failureClass: FailureClass {
            switch self {
            case .integrity:
                return .integrity
            case .rejected, .serverError:
                return .serverError
            case .authentication:
                return .authentication
            }
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run reports each asset it could not fetch with its failure class", .timeLimit(.minutes(1)), arguments: Failure.allCases)
    func runFailureClasses(_ failure: Failure) async throws {
        let retry = RetryPolicy(baseDelay: 1, maxDelay: 1, maxAttemptsPerRun: 1, maxRetryAfter: 60, interactiveMaxWait: 0)
        let harness = EngineHarness.make(tuning: SyncTuning(retry: retry))
        let catalog = EngineSyncTests.catalog(2)
        await harness.serveManifest(catalog.map(\.0))
        await harness.source.script(catalog[0].0.transferID, [.fail(failure.error)])
        await harness.source.script(catalog[1].0.transferID, [.stage(catalog[1].1)])
        // The launch run's own outcome, whether or not a `sync` call would have joined it (L4-R17).
        let outcome = try await harness.startAndAwaitLaunchRun()
        guard case .completeWithFailures(let report) = outcome else {
            Issue.record("expected completeWithFailures, got \(outcome)")
            return
        }
        #expect(report.fetched == 1)
        #expect(report.failures.map(\.id) == [catalog[0].0.identifier])
        #expect(report.failures.first?.failureClass == failure.failureClass)
        await harness.engine.shutdown()
    }

    @Test("R-OBS-3: every engine error maps to the failure class the diagnostics report")
    func failureClassTable() {
        let table: [(AssetError, FailureClass)] = [
            (.offline, .offline),
            (.authRejected(.ambiguous), .authentication),
            (.notFound, .notFound),
            (.insufficientSpace(required: 10, available: 1), .insufficientSpace),
            (.integrityFailure, .integrity),
            (.serverUnavailable(retryAfter: nil), .serverError),
            (.cancelled, .transient),
            (.shutDown, .transient),
            (.storageUnavailable(.ioFailure), .storage),
        ]
        for (error, expected) in table {
            #expect(SyncEngine.failureClass(of: error) == expected, "\(error)")
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-6: a publication that fails with an I/O error is retried after a backoff and the asset arrives", .timeLimit(.minutes(1)))
    func publicationIOErrorRetries() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(450)
        let entry = EngineHarness.onDemand("eio", bytes)
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.stage(bytes), .stage(bytes)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        harness.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: ".part"), occurrence: .nth(1), error: .io))
        let engine = harness.engine
        let location = try await harness.withClock { try await engine.awaitAsset("eio", lane: .userInitiated).get() }
        #expect(location.byteSize == Int64(bytes.count))
        #expect(await harness.source.starts.count == 2, "the failed publication cost one more attempt")
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a publication that runs out of space fails a user request with insufficientSpace", .timeLimit(.minutes(1)))
    func publicationOutOfSpace() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(451)
        let entry = EngineHarness.onDemand("enospc", bytes)
        await harness.serveManifest([entry])
        // The volume holds the file, so the ENOSPC is retried within the interactive policy's attempts (F-20).
        await harness.source.script(entry.transferID, [.stage(bytes), .stage(bytes)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        harness.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: ".part"), occurrence: .every, error: .noSpace))
        let engine = harness.engine
        let result = await harness.withClock { await engine.awaitAsset("enospc", lane: .userInitiated) }
        guard case .failure(.insufficientSpace(let required, _)) = result else {
            Issue.record("expected insufficientSpace, got \(result)")
            return
        }
        #expect(required == Int64(bytes.count))
        #expect(await harness.source.starts.count == SyncTuning().interactiveRetry.maxAttemptsPerRun)
        await harness.engine.shutdown()
    }

    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 38.2 to 39.0 s beside a second TSan process at a
    /// load of 20 to 35 (65 % of 60 s) and 16.6 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7), over half
    /// its 60 s, so the guard is `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a run started while the breaker is open ends blocked without asking for the manifest", .timeLimit(.minutes(3)))
    func runWhileBreakerOpen() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 5, reservedInteractiveSlots: 0))
        let catalog = EngineSyncTests.catalog(6)
        await harness.serveManifest(catalog.map(\.0))
        for (entry, bytes) in catalog {
            await harness.source.script(entry.transferID, [.fail(.transient(.serverError(httpStatus: 500), retryAfter: nil)), .stage(bytes)])
        }
        let probe = EventProbe(stream: try await harness.engine.subscribe().get())
        try await harness.start()
        let launch = await probe.next { event in
            if case .syncFinished = event {
                return true
            }
            if case .circuitChanged(_, .open) = event {
                return true
            }
            return false
        }
        #expect(launch != nil)
        try await harness.drive(maxStep: 25) { $0.groups == 0 && $0.jobsByState.isEmpty && $0.lifecycle == .running }
        await probe.stop()
        let requests = await harness.source.manifestRequests.count
        let outcome = await harness.engine.sync(.force)
        guard case .blocked(.circuitOpen(.serverErrors), let report) = outcome else {
            Issue.record("expected a run blocked by the open breaker, got \(outcome)")
            return
        }
        #expect(!report.manifestFresh)
        #expect(await harness.source.manifestRequests.count == requests, "no manifest request while the breaker is open")
        await harness.engine.shutdown()
    }

    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 30.9 to 32.2 s beside a second TSan process at a
    /// load of 20 to 35 (54 % of 60 s) and 13.9 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7), over half
    /// its 60 s, so the guard is `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a transfer that probes after the cooldown publishes the half-open breaker before it closes", .timeLimit(.minutes(3)))
    func transferProbePublishesHalfOpen() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 5, reservedInteractiveSlots: 0))
        let failing = (0..<5).map { EngineHarness.onDemand("f\($0)", EngineFixture.bytes(UInt64(495 + $0))) }
        let probeBytes = EngineFixture.bytes(494)
        let probeEntry = EngineHarness.onDemand("probe", probeBytes)
        await harness.serveManifest(failing + [probeEntry])
        for entry in failing {
            await harness.source.script(entry.transferID, [.fail(.transient(.serverError(httpStatus: 500), retryAfter: nil))])
        }
        await harness.source.script(probeEntry.transferID, [.hold, .stage(probeBytes)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let probe = EventProbe(stream: try await engine.subscribe().get())
        let groups = try await engine.registerGroup(failing.map(\.identifier), lane: .prefetch).get()
        let opened = await probe.next { event in
            if case .circuitChanged(_, .open(.serverErrors, _)) = event {
                return true
            }
            return false
        }
        #expect(opened != nil)
        await engine.releaseGroup(groups)
        harness.time.advance(by: CircuitBreakerPolicy().serverCooldownBase + 1)
        let request = Task { await engine.awaitAsset("probe", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        // While the probe is held no other breaker event can replace the half-open one in the subscriber's slot.
        let halfOpen = await probe.next { event in
            if case .circuitChanged(_, .halfOpen(.serverErrors, _)) = event {
                return true
            }
            return false
        }
        #expect(halfOpen != nil, "the probe's admission is published")
        await harness.source.release(probeEntry.transferID, with: .progress(received: 0, expected: nil))
        let location = try await request.value.get()
        #expect(location.byteSize == Int64(probeBytes.count))
        let closed = await probe.next { event in
            if case .circuitChanged(_, .closed) = event {
                return true
            }
            return false
        }
        #expect(closed != nil)
        await probe.stop()
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-1: the first call of any API starts the engine", .timeLimit(.minutes(1)))
    func implicitStart() async throws {
        let harness = EngineHarness.make()
        await harness.serve(EngineSyncTests.catalog(1))
        #expect(await harness.engine.introspect().lifecycle == .created)
        let due = await harness.engine.isSyncDue()
        #expect(due != .failure(.shutDown) && due != .failure(.cancelled), "the call was served")
        #expect(await harness.engine.introspect().lifecycle == .running)
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-1: an engine whose store cannot open answers storageUnavailable from start and every API", .timeLimit(.minutes(1)))
    func storeCannotOpen() async throws {
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(time: time)
        fileSystem.addFault(FaultRule(operation: .createDirectory, matching: URLMatcher(lastComponentSuffix: "ZTronAssetKit"), occurrence: .every, error: .permissionDenied))
        let harness = EngineHarness.make(time: time, fileSystem: fileSystem)
        let first = await harness.engine.start()
        guard case .failure(.storageUnavailable(let reason)) = first else {
            Issue.record("expected storageUnavailable, got \(first)")
            return
        }
        #expect(await harness.engine.start() == .failure(.storageUnavailable(reason)), "a later start reports the same")
        #expect(await harness.engine.awaitAsset("any", lane: .userInitiated) == .failure(.storageUnavailable(reason)))
        #expect(await harness.engine.isSyncDue() == .failure(.storageUnavailable(reason)))
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-11: a resolve during migration adopts that legacy file first and never waits for the whole catalog", .timeLimit(.minutes(1)))
    func resolveDuringMigration() async throws {
        let time = ManualTimeSource()
        let catalog = (0..<4).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(UInt64(460 + index))
            return (EngineFixture.entry("legacy\(index)", bytes), bytes)
        }
        let disk = try EngineRunPathTests.legacyDisk(catalog, time: time)
        let bulk = SteppedBlockingExecutor(holding: true)
        let harness = EngineHarness.make(disk: disk, time: time, bulk: bulk, legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot))
        await harness.serveManifest(catalog.map(\.0))
        let engine = harness.engine
        // Open's bulk units are released until the engine runs; from then on the migration's unit stays held.
        let starting = Task { await engine.start() }
        while !EngineOutcomeTests.isUp(await engine.introspect().lifecycle) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await engine.waitUntil { EngineOutcomeTests.isUp($0.lifecycle) }
                }
                group.addTask {
                    await bulk.waitForHeldUnits(atLeast: 1)
                }
                _ = await group.next()
                group.cancelAll()
            }
            for unit in await bulk.heldUnits {
                await bulk.release(unit)
            }
            // Both waits above end on cancellation; the loop must too (a test past its time limit ends, never spins).
            try Task.checkCancellation()
        }
        let report = try await starting.value.get()
        #expect(report.legacyMigrationPending)
        try await bulk.requireHeldUnits(atLeast: 1)
        let migration = Set(await bulk.heldUnits)
        // The resolve's own units are released as they come; it wakes the loop with one more unit when it is done.
        let outcome = Mutex<Result<AssetLocation, AssetError>?>(nil)
        let resolve = Task {
            let result = await engine.awaitAsset("legacy3", lane: .userInitiated)
            outcome.withLock { $0 = result }
            _ = await bulk.run { 0 }
        }
        while outcome.withLock({ $0 }) == nil {
            try await bulk.requireHeldUnits(atLeast: migration.count + 1)
            for unit in await bulk.heldUnits where !migration.contains(unit) {
                await bulk.release(unit)
            }
        }
        let location = try #require(outcome.withLock { $0 }).get()
        #expect(location.byteSize == Int64(catalog[3].1.count))
        #expect(Set(await bulk.heldUnits).isSuperset(of: migration), "the migration was still held at its file")
        #expect(await harness.source.starts.isEmpty, "the legacy file was adopted, not downloaded")
        await bulk.setHolding(false)
        await bulk.releaseAll()
        await resolve.value
        await engine.shutdown()
    }

    /// Whether start has ended (running, degraded or shut down).
    static func isUp(_ lifecycle: EngineLifecycle) -> Bool {
        lifecycle != .created && lifecycle != .starting
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: ensureAvailable for a scope that cannot fit fails with insufficientSpace before any transfer", .timeLimit(.minutes(1)))
    func ensureAvailableCannotFit() async throws {
        let harness = EngineHarness.make(storage: StoragePolicy(reserveFreeBytes: 0), capacity: 500)
        let big = EngineFixture.bytes(480, count: 600)
        let entry = EngineHarness.onDemand("big", big)
        await harness.serveManifest([entry])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        await harness.serveManifest([entry], etag: "v2")
        let result = await harness.engine.ensureAvailable(scope: .identifiers(["big"]))
        guard case .failure(.insufficientSpace(let required, let available)) = result else {
            Issue.record("expected insufficientSpace, got \(result)")
            return
        }
        #expect(required >= 600 && available <= 500)
        #expect(await harness.source.starts.isEmpty, "decided before any transfer")
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: ensureAvailable evicts least-recently-used standard assets to make room within the budget", .timeLimit(.minutes(1)))
    func ensureAvailableEvicts() async throws {
        let harness = EngineHarness.make(storage: StoragePolicy(budget: .bytes(700), reserveFreeBytes: 0, minimumResidency: 0))
        let standard = (0..<2).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(UInt64(481 + index))
            return (EngineFixture.entry("s\(index)", bytes), bytes)
        }
        let wanted = EngineFixture.bytes(483)
        let onDemand = EngineHarness.onDemand("wanted", wanted)
        await harness.serveManifest(standard.map(\.0) + [onDemand])
        await harness.scriptTransfers(standard)
        await harness.source.script(onDemand.transferID, [.stage(wanted)])
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        await harness.serveManifest(standard.map(\.0) + [onDemand], etag: "v2")
        harness.time.advance(by: 60)
        let engine = harness.engine
        let report = try await harness.withClock { try await engine.ensureAvailable(scope: .identifiers(["wanted"])).get() }
        #expect(report.present == 1 && report.isComplete)
        let view = try await harness.view()
        let evicted = standard.filter { entry in
            if case .absent(.evicted)? = view.records[entry.0.identifier]?.residency {
                return true
            }
            return false
        }
        #expect(evicted.count == 1, "one standard asset made room")
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-12: maintenance with no time budget stops after its first step and reports the budget exhausted", .timeLimit(.minutes(1)))
    func maintenanceWithoutBudget() async throws {
        let harness = EngineHarness.make()
        await harness.serve(EngineSyncTests.catalog(2))
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let report = try await harness.engine.performMaintenance(timeBudget: 0).get()
        #expect(report.budgetExhausted)
        #expect(report.verifiedBytes == 0 && report.corruptFound == 0, "verification never started")
        await harness.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-3: staging GC during maintenance keeps the file of a publication in flight, however old", .timeLimit(.minutes(1)))
    func maintenanceKeepsPublicationInFlight() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(bulk: bulk)
        let bytes = EngineFixture.bytes(490)
        let entry = EngineHarness.onDemand("claimed", bytes)
        await harness.serveManifest([entry])
        // A second attempt is scripted so that a collected file shows as a re-download rather than a hang.
        await harness.source.script(entry.transferID, [.hold, .stage(bytes), .stage(bytes)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let waiter = Task { await engine.awaitAsset("claimed", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        // From here every bulk unit is held: the staging writes are released until the publication hashes its claim.
        await bulk.setHolding(true)
        await harness.source.release(entry.transferID, with: .progress(received: 0, expected: nil))
        while await engine.introspect().jobsByState[.verifying] != 1 {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await engine.waitUntil { $0.jobsByState[.verifying] == 1 }
                }
                group.addTask {
                    await bulk.waitForHeldUnits(atLeast: 1)
                }
                _ = await group.next()
                group.cancelAll()
            }
            if await engine.introspect().jobsByState[.verifying] != 1 {
                for unit in await bulk.heldUnits {
                    await bulk.release(unit)
                }
            }
            // Both waits above end on cancellation; the loop must too (a test past its time limit ends, never spins).
            try Task.checkCancellation()
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        let hashing = Set(await bulk.heldUnits)
        // The claimed file is now older than the unclaimed-file grace: only the engine's claim keeps it.
        harness.time.advance(by: StoragePolicy().stagingClaimGrace + 60)
        let report = Mutex<Result<MaintenanceReport, AssetError>?>(nil)
        let maintenance = Task {
            let result = await engine.performMaintenance(timeBudget: 3_600)
            report.withLock { $0 = result }
            _ = await bulk.run { 0 }
        }
        while report.withLock({ $0 }) == nil {
            try await bulk.requireHeldUnits(atLeast: hashing.count + 1)
            for unit in await bulk.heldUnits where !hashing.contains(unit) {
                await bulk.release(unit)
            }
        }
        _ = try #require(report.withLock { $0 }).get()
        await bulk.setHolding(false)
        await bulk.releaseAll()
        await maintenance.value
        let location = try await harness.withClock { try await EngineHarness.value(of: waiter).get() }
        #expect(location.byteSize == Int64(bytes.count))
        #expect(await harness.source.starts.count == 1, "the publication completed from the file staging GC kept")
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: the invariant check reports every broken engine invariant it guards", .timeLimit(.minutes(1)))
    func invariantOracle() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(470)
        let entry = EngineHarness.onDemand("held", bytes)
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let group = try await engine.registerGroup(["held"], lane: .prefetch).get()
        await engine.waitUntil { $0.running == 1 }
        #expect(await engine.invariantViolations().isEmpty, "a healthy engine")
        let transfer = entry.transferID
        let orphaned = await engine.violations { $0.jobs[transfer]?.interests.removeAll() }
        #expect(orphaned.contains { $0.hasPrefix("job ") && $0.contains("has no interest") })
        #expect(orphaned.contains { $0.hasPrefix("group ") && $0.contains("without an interest") })
        let inactive = await engine.violations { $0.jobs[transfer]?.active = nil }
        #expect(inactive.contains { $0.contains("in downloading with active false") })
        let illegal = await engine.violations { $0.metrics.illegalTransitions = 2 }
        #expect(illegal == ["2 illegal transitions"])
        let openGate = await engine.violations { $0.pendingRun = PendingRun(gate: .throttle, trigger: .explicit) }
        #expect(openGate == ["the pending run's throttle gate is open but no run started"])
        let unarmed = await engine.violations {
            $0.pendingRun = PendingRun(gate: .conditions, trigger: .conditionsChanged)
            $0.conditions = EngineConditionsTests.offline
            $0.watcher = nil
        }
        #expect(unarmed == ["nothing will open the pending run's conditions gate"])
        // A due deadline no alarm will fire: none armed, then one armed after it (close-out cycle 14, F-34).
        let unfired = await engine.violations { state in
            state.heap.schedule(.heal("held"), at: .zero)
            state.alarm = nil
        }
        #expect(unfired.count == 1 && unfired.contains { $0.hasPrefix("no live alarm will fire the earliest deadline") }, "\(unfired)")
        let late = await engine.violations { state in
            state.heap.schedule(.heal("held"), at: .zero)
            if let task = state.tasks.keys.min() {
                state.alarm = Alarm(token: 0, task: task, deadline: MonotonicInstant.zero.adding(seconds: 1))
            }
        }
        #expect(late.count == 1 && late.contains { $0.hasPrefix("the alarm is armed after the earliest deadline") }, "\(late)")
        #expect(await engine.invariantViolations().isEmpty, "the check restored the state")
        await harness.source.release(transfer, with: .progress(received: 0, expected: nil))
        await engine.releaseGroup(group)
        await engine.shutdown()
    }
}

extension SyncEngine {
    /// Test seam: the invariant check of the state `edit` produces, in one actor turn; the state is restored after.
    func violations(after edit: @Sendable (inout EngineState) -> Void) -> [String] {
        let saved = self.state
        edit(&self.state)
        let violations = self.invariantViolations()
        self.state = saved
        return violations
    }
}
