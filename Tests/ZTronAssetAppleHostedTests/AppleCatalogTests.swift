import Foundation
import Testing
@testable import ZTronAssetAppleHosted
import ZTronAssetModel
import ZTronAssetTestSupport

/// R-APL-4: catalog-in-pack mode (transport.md §11.2 as amended by transport-2 T2-12, T2-14, T2-20).
@Suite("Apple tier: catalog")
struct AppleCatalogTests {
    @available(macOS 26.0, *)
    @Test("R-APL-4: the catalog is read from the essential pack and its digest is the ETag", .timeLimit(.minutes(1)))
    func catalogFromEssentialPack() async throws {
        let fixture = AppleTierFixture(installed: [Packs.catalog: AppleTierFixture.catalogPack()])
        let result = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        guard case .fetched(let payload) = result else {
            Issue.record("expected the catalog, got \(result)")
            return
        }
        #expect(payload.bytes == AppleTierFixture.catalogBytes)
        #expect(payload.etag == AppleTierFixture.etag(of: AppleTierFixture.catalogBytes))
        #expect(payload.origin == .installedPack(updateChecked: false))
        #expect(payload.removedSources.isEmpty)
        #expect(fixture.backend.calls == [.reader(Packs.catalog, "catalog.json"), .open(Packs.catalog, "catalog.json")])
        #expect(fixture.staging.contents.isEmpty, "the staged catalog is read back and removed")
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: an unchanged catalog yields notModified and a changed one is fetched", .timeLimit(.minutes(1)))
    func unchangedCatalogIsNotModified() async throws {
        let fixture = AppleTierFixture(installed: [Packs.catalog: AppleTierFixture.catalogPack()])
        let etag = AppleTierFixture.etag(of: AppleTierFixture.catalogBytes)
        let unchanged = try await fixture.source.fetchManifest(
            AppleTierFixture.manifestRequest(ifNoneMatch: etag, allowsUpdateCheck: false))
        #expect(unchanged == .notModified(removedSources: []))

        let updated = Data(#"{"version":2,"assets":[]}"#.utf8)
        fixture.backend.install(Packs.catalog, files: AppleTierFixture.catalogPack(updated))
        let changed = try await fixture.source.fetchManifest(
            AppleTierFixture.manifestRequest(ifNoneMatch: etag, allowsUpdateCheck: false, sequence: 2))
        guard case .fetched(let payload) = changed else {
            Issue.record("expected the new catalog, got \(changed)")
            return
        }
        #expect(payload.bytes == updated)
        #expect(payload.etag == AppleTierFixture.etag(of: updated))
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: a hanging update check never delays reading the installed catalog", .timeLimit(.minutes(1)))
    func hangingUpdateCheckNeverDelaysTheCatalog() async throws {
        let fixture = AppleTierFixture(installed: [Packs.catalog: AppleTierFixture.catalogPack()])
        fixture.backend.scriptCheck([.hold])
        let first = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest())
        await fixture.backend.waitFor(.checkForUpdates)

        // The check is still suspended in the "OS": the next fetch reads the installed catalog anyway, and does not
        // start a second check while the first runs.
        let second = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(sequence: 2))
        guard case .fetched(let firstPayload) = first, case .fetched(let secondPayload) = second else {
            Issue.record("expected two catalogs, got \(first) and \(second)")
            return
        }
        #expect(secondPayload.bytes == AppleTierFixture.catalogBytes)
        #expect(firstPayload.origin == .installedPack(updateChecked: false))
        #expect(secondPayload.origin == .installedPack(updateChecked: false))
        #expect(fixture.backend.calls.filter { $0 == .checkForUpdates }.count == 1)

        fixture.backend.releaseCheck(with: .succeed(PackUpdateCheck(updating: [], removed: [])))
        await fixture.source.state.settleUpdateCheck()
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test(
        "R-APL-4: a failing update check still returns the installed catalog, marked not update-checked",
        .timeLimit(.minutes(1))
    )
    func failingUpdateCheckStillReturnsTheCatalog() async throws {
        let fixture = AppleTierFixture(installed: [Packs.catalog: AppleTierFixture.catalogPack()])
        fixture.backend.scriptCheck([
            .fail(.system(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)),
            .succeed(PackUpdateCheck(updating: [], removed: [])),
        ])
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest())
        await fixture.source.state.settleUpdateCheck()

        let afterFailure = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(sequence: 2))
        await fixture.source.state.settleUpdateCheck()
        let afterSuccess = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(sequence: 3))

        guard case .fetched(let failed) = afterFailure, case .fetched(let checked) = afterSuccess else {
            Issue.record("expected catalogs, got \(afterFailure) and \(afterSuccess)")
            return
        }
        #expect(failed.bytes == AppleTierFixture.catalogBytes)
        #expect(failed.origin == .installedPack(updateChecked: false))
        #expect(checked.origin == .installedPack(updateChecked: true))
        #expect(fixture.tap.lines.contains { $0.category == .apple && $0.level == .error && $0.message.contains("update check failed") })
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: packs removed by the update check are reported to the engine once, on notModified too", .timeLimit(.minutes(1)))
    func removedPacksAreReported() async throws {
        let fixture = AppleTierFixture(installed: [
            Packs.catalog: AppleTierFixture.catalogPack(), Packs.extras: ["c.wav": Data("c".utf8)],
        ])
        fixture.backend.scriptCheck([.succeed(PackUpdateCheck(updating: [Packs.media], removed: [Packs.extras]))])
        let etag = AppleTierFixture.etag(of: AppleTierFixture.catalogBytes)
        let first = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(ifNoneMatch: etag))
        await fixture.source.state.settleUpdateCheck()
        let second = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(ifNoneMatch: etag, sequence: 2))
        await fixture.source.state.settleUpdateCheck()
        let third = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(ifNoneMatch: etag, sequence: 3))

        #expect(first == .notModified(removedSources: []))
        #expect(second == .notModified(removedSources: ["ZTronExtras"]))
        #expect(third == .notModified(removedSources: []))
        #expect(!fixture.backend.installedPacks.contains(Packs.extras))
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: removals found while a fetch fails are reported by the next successful fetch", .timeLimit(.minutes(1)))
    func removalsSurviveAFailedFetch() async throws {
        let fixture = AppleTierFixture(installed: [Packs.catalog: AppleTierFixture.catalogPack()])
        fixture.backend.scriptCheck([.succeed(PackUpdateCheck(updating: [], removed: [Packs.extras]))])
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest())
        await fixture.source.state.settleUpdateCheck()

        fixture.staging.failNext(.writeStaged, with: .io(posixCode: EIO))
        await #expect(throws: TransferError.transient(.localIO(posixCode: EIO), retryAfter: nil)) {
            try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false, sequence: 2))
        }
        let recovered = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false, sequence: 3))
        guard case .fetched(let payload) = recovered else {
            Issue.record("expected the catalog, got \(recovered)")
            return
        }
        #expect(payload.removedSources == ["ZTronExtras"])
        #expect(payload.origin == .installedPack(updateChecked: true))
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: update checks are skipped when the request or the configuration disallows them", .timeLimit(.minutes(1)))
    func updateChecksFollowRequestAndConfiguration() async throws {
        let disallowed = AppleTierFixture(installed: [Packs.catalog: AppleTierFixture.catalogPack()])
        _ = try await disallowed.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        let switchedOff = AppleTierFixture(
            installed: [Packs.catalog: AppleTierFixture.catalogPack()],
            configuration: AppleTierConfiguration(updateCheckOnManifestFetch: false)
        )
        _ = try await switchedOff.source.fetchManifest(AppleTierFixture.manifestRequest())
        await disallowed.source.state.settleUpdateCheck()
        await switchedOff.source.state.settleUpdateCheck()
        #expect(!disallowed.backend.calls.contains(.checkForUpdates))
        #expect(!switchedOff.backend.calls.contains(.checkForUpdates))
        await disallowed.source.invalidate()
        await switchedOff.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: a missing catalog pack is made available once and read again", .timeLimit(.minutes(1)))
    func missingCatalogPackIsMadeAvailable() async throws {
        let fixture = AppleTierFixture(remote: [Packs.catalog: AppleTierFixture.catalogPack()])
        let result = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        guard case .fetched(let payload) = result else {
            Issue.record("expected the catalog, got \(result)")
            return
        }
        #expect(payload.bytes == AppleTierFixture.catalogBytes)
        #expect(fixture.backend.calls.filter { $0 == .ensure(Packs.catalog) }.count == 1)
        #expect(fixture.backend.calls.filter { $0 == .open(Packs.catalog, "catalog.json") }.count == 2)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: a fetch cancelled while the catalog pack downloads ends at once and stops the download", .timeLimit(.minutes(1)))
    func fetchCancelledDuringCatalogDownload() async throws {
        let fixture = AppleTierFixture(remote: [Packs.catalog: AppleTierFixture.catalogPack()])
        fixture.backend.scriptEnsure(Packs.catalog, [.hold])
        let fetch = Task {
            try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        }
        await fixture.source.packs.waitForWaiters(on: Packs.catalog, count: 1)
        fetch.cancel()
        await #expect(throws: TransferError.cancelled(.byClient)) {
            try await fetch.value
        }
        await fixture.backend.waitFor(.ensureCancelled(Packs.catalog))
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: a missing catalog pack while offline reports offline", .timeLimit(.minutes(1)))
    func missingCatalogPackOfflineReportsOffline() async throws {
        let fixture = AppleTierFixture()
        fixture.backend.scriptEnsure(Packs.catalog, [
            .fail(.system(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), progress: []),
        ])
        await #expect(throws: TransferError.offline(.noConnection)) {
            try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        }
        #expect(fixture.staging.contents.isEmpty)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: a catalog pack without the catalog file is permanently missing", .timeLimit(.minutes(1)))
    func catalogPackWithoutCatalogIsMissing() async throws {
        let other = ["other.json": Data("{}".utf8)]
        let fixture = AppleTierFixture(installed: [Packs.catalog: other], remote: [Packs.catalog: other])
        await #expect(throws: TransferError.permanentMissing(httpStatus: 404)) {
            try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        }
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: a catalog over the manifest cap is refused while it streams", .timeLimit(.minutes(1)))
    func oversizedCatalogIsRefused() async throws {
        let fixture = AppleTierFixture(installed: [Packs.catalog: AppleTierFixture.catalogPack()])
        let request = ManifestRequest(ifNoneMatch: nil, maxBytes: 8, allowsUpdateCheck: false, attempt: TransferAttempt(epoch: 1, sequence: 1))
        await #expect(throws: TransferError.integrity(.oversize(announced: nil, limit: 8))) {
            try await fixture.source.fetchManifest(request)
        }
        #expect(fixture.staging.contents.isEmpty)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: a staged catalog that cannot be read back fails and is removed", .timeLimit(.minutes(1)))
    func unreadableStagedCatalogFails() async throws {
        let fixture = AppleTierFixture(installed: [Packs.catalog: AppleTierFixture.catalogPack()])
        fixture.staging.failNext(.readStaged, with: .io(posixCode: EIO))
        await #expect(throws: TransferError.transient(.localIO(posixCode: EIO), retryAfter: nil)) {
            try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        }
        #expect(fixture.staging.contents.isEmpty)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: a catalog copy that outlives invalidate cancels the fetch and is left for staging GC", .timeLimit(.minutes(1)))
    func catalogCopyOutlivingInvalidate() async throws {
        let gated = GatedStagingSink()
        let fixture = AppleTierFixture(installed: [Packs.catalog: AppleTierFixture.catalogPack()], staging: gated)
        gated.arm(.afterWrite)
        let fetch = Task {
            try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        }
        await gated.waitForHeldWrites(1)
        let invalidation = Task {
            await fixture.source.invalidate()
        }
        await fixture.source.state.waitForDrain()
        gated.open()
        await invalidation.value
        await #expect(throws: TransferError.cancelled(.byClient)) {
            try await fetch.value
        }
        let name = StagingFileName(transfer: .manifest, attempt: TransferAttempt(epoch: 1, sequence: 1), kind: .partial)
        #expect(gated.base.contents[name] == AppleTierFixture.catalogBytes)
        #expect(!gated.events.contains("discard"))
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: invalidate stops a catalog copy in flight at its next chunk and leaves nothing in staging", .timeLimit(.minutes(1)))
    func invalidateStopsACatalogCopyInFlight() async throws {
        let gated = GatedStagingSink()
        let fixture = AppleTierFixture(installed: [Packs.catalog: AppleTierFixture.catalogPack()], staging: gated)
        gated.arm(.beforeWrite)
        let fetch = Task {
            try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        }
        await gated.waitForHeldWrites(1)
        let invalidation = Task {
            await fixture.source.invalidate()
        }
        await fixture.source.state.waitForDrain()
        gated.open()
        await invalidation.value
        await #expect(throws: TransferError.cancelled(.byClient)) {
            try await fetch.value
        }
        #expect(!fixture.backend.calls.contains(.open(Packs.catalog, "catalog.json")))
        #expect(gated.base.contents.isEmpty)
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: an invalid catalog location is rejected without touching any pack", .timeLimit(.minutes(1)))
    func invalidCatalogLocationIsRejected() async throws {
        let fixture = AppleTierFixture(configuration: AppleTierConfiguration(catalogPackID: "..", catalogPath: "catalog.json"))
        await #expect(throws: TransferError.rejected(.invalidURL)) {
            try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest())
        }
        #expect(fixture.backend.calls.isEmpty)
        #expect(fixture.tap.lines.contains { $0.category == .apple && $0.level == .fault })
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-APL-4: a manifest fetch after invalidate is cancelled and touches no staging", .timeLimit(.minutes(1)))
    func fetchAfterInvalidateIsCancelled() async throws {
        let fixture = AppleTierFixture(installed: [Packs.catalog: AppleTierFixture.catalogPack()])
        await fixture.source.invalidate()
        await #expect(throws: TransferError.cancelled(.byClient)) {
            try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest())
        }
        #expect(fixture.backend.calls.isEmpty)
    }
}
