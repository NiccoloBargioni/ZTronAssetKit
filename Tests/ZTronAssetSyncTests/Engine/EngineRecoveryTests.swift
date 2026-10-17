import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Recovery paths of the engine: a migration that cannot finish yet, corruption found by maintenance, a `Retry-After`
/// beyond the policy, gates that open on their deadline, and a store that fails while a run applies (R-STO-11,
/// R-SYN-16, R-SYN-5, R-SYN-6).
@Suite("Engine recovery")
struct EngineRecoveryTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-11: a migration call that leaves nothing remaining but cannot finish defers to the next maintenance window, which finishes it", .timeLimit(.minutes(1)))
    func deferredMigrationFinishesInMaintenance() async throws {
        let time = ManualTimeSource()
        let catalog = (0..<3).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(UInt64(1_200 + index))
            return (EngineFixture.entry("legacy\(index)", bytes), bytes)
        }
        let disk = try EngineRunPathTests.legacyDisk(catalog, time: time)
        let harness = EngineHarness.make(disk: disk, time: time, legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot))
        // Phase 1 lists the legacy files' directory while the store opens; the next listing is phase 4's removal of the
        // tree, which fails once: every file is adopted, nothing remains, and migration is not finished.
        let directory = URLMatcher(lastComponentSuffix: "dir", pathContains: "CDNAssets")
        harness.fileSystem.addFault(FaultRule(operation: .contentsOfDirectory, matching: directory, occurrence: .nth(2), error: .io))
        await harness.serveManifest(catalog.map(\.0))
        let engine = harness.engine
        let report = try await harness.start()
        #expect(report.legacyMigrationPending)
        await engine.awaitCondition { $0.state.migration.deferred && !$0.state.migration.running }
        // The launch run the migration held back still runs, and downloads nothing it adopted.
        _ = try #require(await engine.sync(.force).completeReport)
        #expect(await harness.source.starts.isEmpty)
        #expect(try harness.fileSystem.itemInfo(at: EngineRunPathTests.legacyRoot) != nil, "phase 4 could not remove the tree")
        let view = try await harness.view()
        #expect(catalog.allSatisfy { view.records[$0.0.identifier]?.referencedBlob != nil }, "every legacy file was adopted")
        // The deferral holds no task and no timer: the engine waits for the next maintenance window.
        try await harness.settle()
        #expect(await engine.introspect().ownedTasks == 0)
        _ = try await engine.performMaintenance(timeBudget: 60).get()
        await engine.awaitCondition { !$0.state.migration.pending && !$0.state.migration.running }
        #expect(try harness.fileSystem.itemInfo(at: EngineRunPathTests.legacyRoot) == nil, "the restarted migration finished phase 4")
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-16: maintenance finds a corrupted blob, announces its quarantine, and the engine downloads it again when the quarantine ends", .timeLimit(.minutes(1)))
    func maintenanceHealsCorruption() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(2)
        await harness.serve(catalog)
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        let (entry, bytes) = catalog[0]
        let location = try await engine.awaitAsset(entry.identifier, lane: .userInitiated).get()
        var corrupted = bytes
        corrupted[corrupted.startIndex] ^= 0xFF
        try harness.fileSystem.write(corrupted, to: location.url, mode: .truncate)
        await harness.scriptTransfers([(entry, bytes)])
        let probe = EventProbe(stream: try await engine.subscribe().get())
        let report = try await engine.performMaintenance(timeBudget: 60).get()
        #expect(report.corruptFound == 1)
        #expect(await engine.awaitAsset(entry.identifier, lane: .userInitiated) == .failure(.integrityFailure), "quarantined until its quarantine ends")
        // The quarantine's announcement is received before the clock moves: the heal's `assetAvailable` has the same
        // subject and would replace it in the probe's slot if the probe had not pulled it yet (§7.9; L4-R17).
        let quarantined = await probe.next { $0 == .assetRemoved(entry.identifier, .quarantined) }
        #expect(quarantined != nil, "the quarantine is announced")
        // The quarantine's end is a deadline on the engine's clock; the re-download is a system interest.
        let healed = await harness.withClock {
            await probe.next { event in
                if case .assetAvailable(let id, _) = event {
                    return id == entry.identifier
                }
                return false
            }
        }
        #expect(healed != nil)
        let restored = try await engine.awaitAsset(entry.identifier, lane: .userInitiated).get()
        #expect(try harness.fileSystem.read(from: restored.url, offset: 0, maxLength: bytes.count + 1) == bytes)
        #expect(await harness.source.starts.count == 3, "two at the sync, one heal")
        await probe.stop()
        await engine.shutdown()
    }

    /// The two transient failures whose `Retry-After` the policy may refuse.
    enum LongWait: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// 503.
        case serverError
        /// 429.
        case throttled

        var testDescription: String {
            self.rawValue
        }

        var error: TransferError {
            switch self {
            case .serverError:
                return .transient(.serverError(httpStatus: 503), retryAfter: .seconds(7_200))
            case .throttled:
                return .transient(.throttled, retryAfter: .seconds(7_200))
            }
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a Retry-After beyond maxRetryAfter fails the waiter with that wait and ends the job for the run, holding nothing", .timeLimit(.minutes(1)), arguments: LongWait.allCases)
    func retryAfterBeyondPolicy(_ wait: LongWait) async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(1_300)
        let entry = EngineHarness.onDemand("slow", bytes)
        await harness.serveManifest([entry])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(entry.transferID, [.fail(wait.error)])
        let result = await engine.awaitAsset("slow", lane: .userInitiated)
        guard case .failure(.serverUnavailable(let retryAfter?)) = result else {
            Issue.record("expected serverUnavailable with the server's wait, got \(result)")
            await engine.shutdown()
            return
        }
        #expect(retryAfter == 7_200)
        // No retry is scheduled and the origin is not held: the job ended, and a later request starts at once.
        let state = await engine.introspect()
        #expect(state.jobsByState.isEmpty && state.scheduledDeadlines == 0)
        await harness.source.script(entry.transferID, [.stage(bytes)])
        #expect(try await engine.awaitAsset("slow", lane: .userInitiated).get().byteSize == Int64(bytes.count))
        #expect(await harness.source.starts.count == 2)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a prefetch held by an origin throttle starts again exactly when the throttle ends", .timeLimit(.minutes(1)))
    func throttledPrefetchResumesAtDeadline() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(1_400)
        let entry = EngineHarness.onDemand("p", bytes)
        await harness.serveManifest([entry])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(entry.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(30))), .stage(bytes)])
        let probe = EventProbe(stream: try await engine.subscribe().get())
        let throttledAt = harness.time.monotonicNow()
        let group = try await engine.registerGroup(["p"], lane: .prefetch).get()
        // A prefetch is not failed fast: it waits, blocked, for the throttle's end, whose deadline the engine arms.
        await engine.waitUntil { ($0.jobsByState[.blocked] ?? 0) == 1 }
        let origin = harness.source.originID
        await engine.awaitCondition { $0.state.heap.deadline(for: .throttle(origin)) != nil }
        try await harness.time.requireSleepers(atLeast: 1)
        #expect(harness.time.nextDeadline == throttledAt.adding(seconds: 30))
        #expect(await harness.source.starts.count == 1)
        harness.time.advance(by: 30)
        let available = await probe.next { event in
            if case .assetAvailable(let id, _) = event {
                return id == "p"
            }
            return false
        }
        #expect(available != nil)
        #expect(await harness.source.starts.count == 2)
        #expect(try await engine.metrics().get().retries[.throttled] == 1)
        await engine.releaseGroup(group)
        await probe.stop()
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a prefetch blocked by an open breaker starts when the cooldown ends, and its success closes the breaker", .timeLimit(.minutes(1)))
    func breakerBlockedPrefetchResumesAtCooldown() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(1_500)
        let entry = EngineHarness.onDemand("q", bytes)
        await harness.serveManifest([entry])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        // A key-rejected manifest 403 opens the auth breaker at once.
        await harness.source.scriptManifest([.fail(.authentication(.forbiddenAmbiguous(EngineFailurePathTests.evidence(.manifest, xml: false, bytes: 0))))])
        guard case .blocked(.circuitOpen(.authentication), _) = await engine.sync(.force) else {
            Issue.record("expected a run blocked by the auth breaker")
            await engine.shutdown()
            return
        }
        let probe = EventProbe(stream: try await engine.subscribe().get())
        await harness.source.script(entry.transferID, [.stage(bytes)])
        let group = try await engine.registerGroup(["q"], lane: .prefetch).get()
        await engine.waitUntil { ($0.jobsByState[.blocked] ?? 0) == 1 }
        #expect(await harness.source.starts.isEmpty, "nothing starts while the breaker is open")
        // The clock moves to the cooldown's end and no further (the probe's watchdog stays ahead): the job probes, its
        // success closes the breaker.
        let cooldown = try #require(await engine.breakerDeadline())
        try await harness.time.requireSleepers(atLeast: 1)
        harness.time.advance(to: cooldown)
        let available = await probe.next { event in
            if case .assetAvailable(let id, _) = event {
                return id == "q"
            }
            return false
        }
        #expect(available != nil)
        // An explicit wait for the breaker's close: it may be published after the asset's availability, which the probe
        // may have received first (L4-R17; no later breaker event can replace it in its slot).
        let closed = await probe.next { $0 == .circuitChanged(originID: harness.source.originID, .closed) }
        #expect(closed != nil)
        #expect(await harness.source.starts.count == 1)
        await engine.releaseGroup(group)
        await probe.stop()
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a store failure while a run applies its manifest fails the run with the store's error and starts nothing", .timeLimit(.minutes(1)))
    func applyFailureFailsTheRun() async throws {
        let harness = EngineHarness.make()
        let catalog = EngineSyncTests.catalog(2)
        await harness.serve(catalog)
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        let added = EngineFixture.entry("added", EngineFixture.bytes(1_600))
        await harness.serveManifest(catalog.map(\.0) + [added], etag: "v2")
        await harness.source.script(added.transferID, [.stage(EngineFixture.bytes(1_600))])
        // The index commit of the run's apply fails once.
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .io))
        #expect(await engine.sync(.force) == .failed(.storageUnavailable(.ioFailure)))
        #expect(await harness.source.starts.count == 2, "no transfer started for the manifest that was not committed")
        // The fault was transient: the next run applies v2 and fetches what it added.
        let next = await engine.sync(.force)
        #expect(next.completeReport?.fetched == 1, "the next run recovers: \(next)")
        #expect(await harness.source.starts.count == 3)
        await engine.shutdown()
    }
}


extension SyncEngine {
    /// Test seam: when the open breaker's cooldown ends (the heap's breaker entry).
    func breakerDeadline() -> MonotonicInstant? {
        guard let origin = self.state.remote?.originID else {
            return nil
        }
        return self.state.heap.deadline(for: .breaker(origin))
    }
}
