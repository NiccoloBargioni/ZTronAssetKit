import Combine
import Foundation
import Testing
import ZTronAssetKit
import ZTronAssetTestSupport

/// R-CAR-6: `CDNSyncCoordinator` over a real client (RECON §5: progress semantics; reconcile before download; changed
/// checksum, directory and removal behaviours; once-per-version success; `verifyFullyAvailable` and
/// `verifyAndRepair`).
///
/// A run must never race the call under test (L5-R14): the client's launch run settles first, under
/// `.atMostEvery(3600)`, so a later `syncIfNeeded()` is due only once the test moves the clock past the interval, and
/// the run it reports is the one it starts.
@Suite("Compatibility shims: sync coordinator")
struct SyncCoordinatorShimTests {
    /// The refresh interval of these tests.
    static let interval: TimeInterval = 3_600

    /// A client whose launch run stored `assets` and wrote the stamp; nothing is due until `interval` passes.
    @available(macOS 15.0, iOS 18.0, *)
    static func settled(_ assets: [(CDNAsset, Data)]) async throws -> CompatHarness {
        let harness = CompatHarness.make(refresh: .atMostEvery(SyncCoordinatorShimTests.interval))
        await harness.serve(assets)
        try await harness.settleLaunch()
        return harness
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: a coordinator starts idle, reports upToDate without a manifest request when no sync is due, and complete after a due sync", .timeLimit(.minutes(1)))
    func dueAndNotDue() async throws {
        let iconBytes = CompatFixture.bytes(40)
        let cardBytes = CompatFixture.bytes(41)
        let icon = CompatFixture.asset("bo7.ri.easter.egg.icon", iconBytes)
        let card = CompatFixture.asset("bo7.ri.easter.egg.card", cardBytes)
        let harness = try await SyncCoordinatorShimTests.settled([(icon, iconBytes)])
        let coordinator = CDNSyncCoordinator(client: harness.client, cdn: ScriptedCDNProvider(manifest: .success([icon])))
        var changes = 0
        let observation = coordinator.objectWillChange.sink { _ in
            changes += 1
        }
        #expect(coordinator.progress == .idle)
        let requests = await harness.source.manifestRequests.count

        await coordinator.syncIfNeeded()
        #expect(coordinator.progress == .upToDate)
        #expect(await harness.source.manifestRequests.count == requests, "not due: no network activity")
        #expect(changes >= 1, "an ObservableObject: SwiftUI sees the change")

        await harness.serveManifest([icon, card], etag: "v2")
        await harness.source.script(CompatFixture.transfer(card), [.stage(cardBytes)])
        harness.time.advance(by: SyncCoordinatorShimTests.interval + 1)
        await coordinator.syncIfNeeded()
        #expect(coordinator.progress == .complete)
        #expect(CDNLocalStore(client: harness.client).hasAsset(card))

        await coordinator.syncIfNeeded()
        #expect(coordinator.progress == .upToDate, "the complete run wrote the stamp")
        observation.cancel()
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: a sync whose manifest cannot be fetched reports failed with the outcome's description and stays due", .timeLimit(.minutes(1)))
    func manifestFailureReportsFailed() async throws {
        let iconBytes = CompatFixture.bytes(42)
        let icon = CompatFixture.asset("bo6.tm.icon", iconBytes)
        let harness = try await SyncCoordinatorShimTests.settled([(icon, iconBytes)])
        let coordinator = CDNSyncCoordinator(client: harness.client, cdn: ScriptedCDNProvider(manifest: .success([icon])))
        await harness.source.scriptManifest([.fail(.permanentMissing(httpStatus: 404))])
        harness.time.advance(by: SyncCoordinatorShimTests.interval + 1)

        await coordinator.syncIfNeeded()

        #expect(coordinator.progress == CDNSyncProgress(outcome: .failed(.notFound)))
        #expect(coordinator.progress == .failed(reason: String(describing: SyncOutcome.failed(.notFound))))
        #expect(try await harness.client.isSyncDue(), "the next launch retries")
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: a sync with a failed asset reports failed and the next sync downloads only what is still missing", .timeLimit(.minutes(1)))
    func partialSyncIsRetried() async throws {
        let iconBytes = CompatFixture.bytes(43)
        let cardBytes = CompatFixture.bytes(44)
        let posterBytes = CompatFixture.bytes(45)
        let icon = CompatFixture.asset("bo7.ri.icon", iconBytes)
        let card = CompatFixture.asset("bo7.ri.card", cardBytes)
        let poster = CompatFixture.asset("bo7.ri.poster", posterBytes)
        let harness = try await SyncCoordinatorShimTests.settled([(icon, iconBytes)])
        let coordinator = CDNSyncCoordinator(client: harness.client, cdn: ScriptedCDNProvider(manifest: .success([])))
        await harness.serveManifest([icon, card, poster], etag: "v2")
        await harness.source.script(CompatFixture.transfer(card), [.stage(cardBytes)])
        await harness.source.script(
            CompatFixture.transfer(poster),
            [.fail(.transient(.serverError(httpStatus: 503), retryAfter: nil)), .stage(posterBytes)]
        )
        harness.time.advance(by: SyncCoordinatorShimTests.interval + 1)

        await coordinator.syncIfNeeded()
        guard case .failed(let reason) = coordinator.progress else {
            Issue.record("a partial run is a failure in the prior art's terms: \(coordinator.progress)")
            return
        }
        #expect(reason.hasPrefix("completeWithFailures("))
        #expect(try await harness.client.isSyncDue(), "no stamp after a partial run")

        let starts = await harness.source.starts.count
        await harness.source.scriptManifest([.notModified])
        await coordinator.syncIfNeeded()
        #expect(coordinator.progress == .complete)
        #expect(await harness.starts(after: starts) == [CompatFixture.transfer(poster)], "the stored assets are not fetched again")
        #expect(CDNLocalStore(client: harness.client).isFullyAvailable(against: [icon, card, poster]))
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: progress reports syncing with a monotone completed count while assets transfer, then complete", .timeLimit(.minutes(1)))
    func progressReportsSyncing() async throws {
        let iconBytes = CompatFixture.bytes(46)
        let cardBytes = CompatFixture.bytes(47)
        let posterBytes = CompatFixture.bytes(48)
        let icon = CompatFixture.asset("bo4.ix.icon", iconBytes)
        let card = CompatFixture.asset("bo4.ix.card", cardBytes)
        let poster = CompatFixture.asset("bo4.ix.poster", posterBytes)
        let harness = try await SyncCoordinatorShimTests.settled([(icon, iconBytes)])
        let coordinator = CDNSyncCoordinator(client: harness.client, cdn: ScriptedCDNProvider(manifest: .success([])))
        await harness.serveManifest([icon, card, poster], etag: "v2")
        await harness.source.script(CompatFixture.transfer(card), [.stage(cardBytes)])
        await harness.source.script(CompatFixture.transfer(poster), [.hold, .stage(posterBytes)])
        harness.time.advance(by: SyncCoordinatorShimTests.interval + 1)
        let (syncingSeen, signal) = AsyncStream<Void>.makeStream()
        // Records what the coordinator publishes until it is cancelled. A publisher without demand may drop a value
        // (`AsyncPublisher` asks for one at a time), so the test asserts on what was seen, never on seeing the last one.
        let collector = Task { @MainActor in
            var values: [CDNSyncProgress] = []
            for await value in coordinator.$progress.values {
                values.append(value)
                if case .syncing = value {
                    signal.yield()
                }
            }
            return values
        }

        let syncing = Task { @MainActor in
            await coordinator.syncIfNeeded()
        }
        // The card commits while the poster's transfer is held, so the run reports progress mid-flight.
        for await _ in syncingSeen {
            break
        }
        await harness.source.release(CompatFixture.transfer(poster), with: .progress(received: 0, expected: nil))
        await syncing.value
        collector.cancel()
        let values = await collector.value

        #expect(coordinator.progress == .complete)
        let counts = values.compactMap { value -> Int? in
            guard case .syncing(_, let completed, let total) = value else {
                return nil
            }
            #expect(total == 2, "the run's planned fetches")
            return completed
        }
        #expect(!counts.isEmpty)
        #expect(counts == counts.sorted(), "progress never moves backwards (CDNSyncCoordinator.swift:154-164)")
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: verifyAndRepair syncs even when no sync is due and reports complete", .timeLimit(.minutes(1)))
    func verifyAndRepairForcesASync() async throws {
        let iconBytes = CompatFixture.bytes(49)
        let cardBytes = CompatFixture.bytes(50)
        let icon = CompatFixture.asset("bo6.tm.icon", iconBytes)
        let card = CompatFixture.asset("bo6.tm.card", cardBytes)
        let harness = try await SyncCoordinatorShimTests.settled([(icon, iconBytes)])
        let coordinator = CDNSyncCoordinator(client: harness.client, cdn: ScriptedCDNProvider(manifest: .success([])))
        await harness.serveManifest([icon, card], etag: "v2")
        await harness.source.script(CompatFixture.transfer(card), [.stage(cardBytes)])
        #expect(try await harness.client.isSyncDue() == false, "setup: nothing is due")

        await coordinator.verifyAndRepair()

        #expect(coordinator.progress == .complete)
        #expect(CDNLocalStore(client: harness.client).hasAsset(card))
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: a directory change moves the stored asset without a download and a removed entry is deleted, before any download", .timeLimit(.minutes(1)))
    func reconcilesBeforeDownloading() async throws {
        let iconBytes = CompatFixture.bytes(51)
        let cardBytes = CompatFixture.bytes(52)
        let icon = CompatFixture.asset("bo7.ri.easter.egg.icon", iconBytes, directories: ["Black Ops 7", "Rex Infernus"])
        let card = CompatFixture.asset("bo7.ri.easter.egg.card", cardBytes)
        let harness = try await SyncCoordinatorShimTests.settled([(icon, iconBytes), (card, cardBytes)])
        let coordinator = CDNSyncCoordinator(client: harness.client, cdn: ScriptedCDNProvider(manifest: .success([])))
        let moved = CompatFixture.asset(icon.identifier, iconBytes, directories: ["Black Ops 7", "Rex Infernus", "Vehytherion Temple"])
        await harness.serveManifest([moved], etag: "v2")
        let starts = await harness.source.starts.count

        await coordinator.verifyAndRepair()

        let store = CDNLocalStore(client: harness.client)
        #expect(coordinator.progress == .complete)
        #expect(await harness.starts(after: starts).isEmpty, "reconcile before download: the move costs nothing")
        #expect(coordinator.lastReconciliation == CDNReconciliationSummary(migratedCount: 1, prunedCount: 1))
        #expect(store.hasAsset(moved))
        #expect(store.existingLocalURL(identifier: card.identifier, candidateExtensions: []) == nil, "pruned")
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: a changed checksum re-downloads that asset only", .timeLimit(.minutes(1)))
    func changedChecksumRedownloadsOnlyThatAsset() async throws {
        let iconBytes = CompatFixture.bytes(53)
        let cardBytes = CompatFixture.bytes(54)
        let newCardBytes = CompatFixture.bytes(55)
        let icon = CompatFixture.asset("bo6.tm.icon", iconBytes)
        let card = CompatFixture.asset("bo6.tm.card", cardBytes)
        let newCard = CompatFixture.asset(card.identifier, newCardBytes)
        let harness = try await SyncCoordinatorShimTests.settled([(icon, iconBytes), (card, cardBytes)])
        let coordinator = CDNSyncCoordinator(client: harness.client, cdn: ScriptedCDNProvider(manifest: .success([])))
        await harness.serveManifest([icon, newCard], etag: "v2")
        await harness.source.script(CompatFixture.transfer(newCard), [.stage(newCardBytes)])
        let starts = await harness.source.starts.count

        await coordinator.verifyAndRepair()

        let store = CDNLocalStore(client: harness.client)
        #expect(coordinator.progress == .complete)
        #expect(await harness.starts(after: starts) == [CompatFixture.transfer(newCard)])
        #expect(store.hasAsset(newCard))
        #expect(store.hasAsset(icon))
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: verifyFullyAvailable lists what the provider's fresh manifest names that is missing or stale, downloading nothing", .timeLimit(.minutes(1)))
    func verifyFullyAvailableListsMissingAssets() async throws {
        let iconBytes = CompatFixture.bytes(56)
        let cardBytes = CompatFixture.bytes(57)
        let icon = CompatFixture.asset("bo7.ri.icon", iconBytes)
        let card = CompatFixture.asset("bo7.ri.card", cardBytes)
        let harness = try await SyncCoordinatorShimTests.settled([(icon, iconBytes), (card, cardBytes)])
        let republishedCard = CompatFixture.asset(card.identifier, CompatFixture.bytes(58))
        let poster = CompatFixture.asset("bo7.ri.poster", CompatFixture.bytes(59))
        let provider = ScriptedCDNProvider(manifest: .success([icon, republishedCard, poster]))
        let coordinator = CDNSyncCoordinator(client: harness.client, cdn: provider)
        let starts = await harness.source.starts.count

        let missing = try await coordinator.verifyFullyAvailable()

        #expect(missing == [republishedCard, poster])
        #expect(await harness.starts(after: starts).isEmpty)
        #expect(coordinator.progress == .idle, "a check, not a sync")
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: verifyFullyAvailable throws when the provider's manifest fetch fails", .timeLimit(.minutes(1)))
    func verifyFullyAvailableThrows() async throws {
        let harness = CompatHarness.make()
        let coordinator = CDNSyncCoordinator(client: harness.client, cdn: ScriptedCDNProvider(manifest: .failure(.manifestUnavailable)))

        await #expect(throws: ScriptedProviderFailure.manifestUnavailable) {
            try await coordinator.verifyFullyAvailable()
        }
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-6: a coordinator over a shut-down client reports failed with shutDown", .timeLimit(.minutes(1)))
    func shutDownClientReportsFailed() async {
        let harness = CompatHarness.make()
        let coordinator = CDNSyncCoordinator(client: harness.client, cdn: ScriptedCDNProvider(manifest: .success([])))
        await harness.client.shutdown()

        await coordinator.syncIfNeeded()
        #expect(coordinator.progress == .failed(reason: String(describing: SyncOutcome.failed(.shutDown))))
        await coordinator.verifyAndRepair()
        #expect(coordinator.progress == .failed(reason: String(describing: SyncOutcome.failed(.shutDown))))
    }

    @Test("R-CAR-6: a run's report maps onto the prior art's reconciliation summary")
    func reconciliationSummaryFromReport() {
        let report = SyncReport(
            runID: SyncRunID(rawValue: 7),
            trigger: .explicit,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_010),
            manifestFresh: true,
            planned: PlanTotals(relocationCount: 2, pruneCount: 3),
            fetched: 4,
            reused: 1,
            relocated: 2,
            pruned: 3,
            evicted: 0,
            failedCount: 1,
            bytesDownloaded: 1_024,
            failures: [AssetFailure(id: "bo7.ri.icon", error: .notFound, failureClass: .notFound)]
        )
        let summary = CDNReconciliationSummary(report: report)
        #expect(summary.migratedCount == 2)
        #expect(summary.prunedCount == 3)
        #expect(summary.migrationFailures.isEmpty)
        #expect(summary.pruneFailures.isEmpty, "asset failures are not reconciliation failures")
    }

    @Test("R-CAR-6: defaultAppVersion joins the marketing version and the build number with a plus")
    func defaultAppVersionFormat() {
        let version = CDNSyncCoordinator.defaultAppVersion()
        let parts = version.split(separator: "+", omittingEmptySubsequences: false)
        #expect(parts.count >= 2)
        #expect(parts.allSatisfy { !$0.isEmpty })
    }
}
