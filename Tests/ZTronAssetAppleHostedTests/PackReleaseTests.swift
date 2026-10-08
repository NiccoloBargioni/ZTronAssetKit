import Foundation
import Testing
@testable import ZTronAssetAppleHosted
import ZTronAssetModel
import ZTronAssetTestSupport

private let mediaA = "ZTronMedia/a.png"
private let mediaB = "ZTronMedia/b.png"
private let extraC = "ZTronExtras/c.wav"

private func pack(_ paths: String...) -> [String: Data] {
    Dictionary(uniqueKeysWithValues: paths.map { (String($0.drop(while: { $0 != "/" }).dropFirst()), Data($0.utf8)) })
}

/// R-CLN-10 and the source half of R-CLN-9 (H-7, ADR-027).
@Suite("Apple tier: releases and source copies")
struct PackReleaseTests {
    @available(macOS 26.0, *)
    @Test("R-CLN-10: reclaim releases a media pack once every entry in it is adopted or excluded", .timeLimit(.minutes(1)))
    func reclaimReleasesSettledPacks() async throws {
        let fixture = AppleTierFixture(installed: [
            Packs.catalog: AppleTierFixture.catalogPack(), Packs.media: pack(mediaA, mediaB), Packs.extras: pack(extraC),
        ])
        let entries = [mediaA, mediaB, extraC, "ZTronCatalog/catalog.json"]
        let partial = await fixture.source.reclaimSourceCopies(
            AdoptionReport(manifestRemotePaths: entries, adoptedRemotePaths: [mediaA, extraC, "ZTronCatalog/catalog.json"])
        )
        #expect(partial == ReclaimReport(released: ["ZTronExtras"]))
        let settled = await fixture.source.reclaimSourceCopies(
            AdoptionReport(manifestRemotePaths: entries, adoptedRemotePaths: [mediaA], excludedRemotePaths: [mediaB])
        )
        #expect(settled == ReclaimReport(released: ["ZTronMedia"]))
        #expect(fixture.backend.installedPacks == [Packs.catalog])
        #expect(fixture.backend.calls.filter { if case .remove = $0 { true } else { false } } == [.remove(Packs.extras), .remove(Packs.media)])
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-CLN-10: a pack that comes back after release is released at most once per catalog generation", .timeLimit(.minutes(1)))
    func releasedOncePerCatalogGeneration() async throws {
        let fixture = AppleTierFixture(installed: [Packs.catalog: AppleTierFixture.catalogPack(), Packs.media: pack(mediaA)])
        let report = AdoptionReport(manifestRemotePaths: [mediaA], adoptedRemotePaths: [mediaA])
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronMedia"])

        fixture.backend.install(Packs.media, files: pack(mediaA))
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false, sequence: 2))
        #expect(await fixture.source.reclaimSourceCopies(report).released.isEmpty, "same catalog generation")
        #expect(fixture.backend.installedPacks.contains(Packs.media))

        fixture.backend.install(Packs.catalog, files: AppleTierFixture.catalogPack(Data(#"{"version":2}"#.utf8)))
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false, sequence: 3))
        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronMedia"], "a new catalog generation")
        #expect(fixture.backend.calls.filter { $0 == .remove(Packs.media) }.count == 2)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-CLN-10: a report larger than one survey slice releases exactly the packs settled in every slice", .timeLimit(.minutes(1)))
    func reportAcrossSurveySlices() async throws {
        let fixture = AppleTierFixture(installed: [Packs.media: pack(mediaA), Packs.extras: pack(extraC)])
        let media = (0..<1_500).map { "ZTronMedia/images/\($0).heic" }
        let extras = (0..<1_500).map { "ZTronExtras/sounds/\($0).wav" }
        // The one unadopted extra sits in the last slice; every media entry is adopted.
        let report = AdoptionReport(
            manifestRemotePaths: media + extras,
            adoptedRemotePaths: Set(media + extras.dropLast())
        )
        #expect(report.manifestRemotePaths.count > ReleaseSurvey.sliceSize * 2)
        #expect(await fixture.source.reclaimSourceCopies(report) == ReclaimReport(released: ["ZTronMedia"]))
        #expect(fixture.backend.installedPacks == [Packs.extras])
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-CLN-10: a release made before the first catalog fetch counts for that catalog's generation", .timeLimit(.minutes(1)))
    func releaseBeforeFirstFetchIsNotRepeated() async throws {
        let fixture = AppleTierFixture(installed: [Packs.catalog: AppleTierFixture.catalogPack(), Packs.media: pack(mediaA)])
        let report = AdoptionReport(manifestRemotePaths: [mediaA], adoptedRemotePaths: [mediaA])
        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronMedia"], "an offline launch's maintenance")
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        #expect(await fixture.source.reclaimSourceCopies(report) == ReclaimReport(), "reported once, never again")
        #expect(fixture.backend.calls.filter { $0 == .remove(Packs.media) }.count == 1)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-CLN-10: a released pack that a transfer downloaded again is released again once adopted", .timeLimit(.minutes(1)))
    func redownloadedPackIsReleasedAgain() async throws {
        let fixture = AppleTierFixture(
            installed: [Packs.catalog: AppleTierFixture.catalogPack(), Packs.media: pack(mediaA)],
            remote: [Packs.media: pack(mediaA)]
        )
        let report = AdoptionReport(manifestRemotePaths: [mediaA], adoptedRemotePaths: [mediaA])
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronMedia"])
        let updates = await collect(await fixture.source.transfer(PackAsset(mediaA, mediaA).request()))
        #expect(updates.last.map(AppleTransferTests.isStaged) == true, "\(updates)")
        #expect(fixture.backend.installedPacks.contains(Packs.media), "the transfer downloaded the pack again")

        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronMedia"], "same catalog generation")
        #expect(!fixture.backend.installedPacks.contains(Packs.media))
        #expect(fixture.backend.calls.filter { $0 == .remove(Packs.media) }.count == 2)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test(
        "R-CLN-10: a pack a transfer downloaded again while its release call was running is released again once adopted",
        .timeLimit(.minutes(1))
    )
    func redownloadDuringReleaseIsReleasedAgain() async throws {
        let fixture = AppleTierFixture(installed: [Packs.media: pack(mediaA)], remote: [Packs.media: pack(mediaA)])
        let report = AdoptionReport(manifestRemotePaths: [mediaA], adoptedRemotePaths: [mediaA])
        fixture.backend.holdRemove(Packs.media)
        let reclaim = Task {
            await fixture.source.reclaimSourceCopies(report)
        }
        await fixture.backend.waitFor(.remove(Packs.media))
        #expect(!fixture.backend.installedPacks.contains(Packs.media), "the pack is gone, the release call has not returned")

        // The adopted blob was evicted meanwhile; the engine fetches it again while the release call still runs.
        let updates = await collect(await fixture.source.transfer(PackAsset(mediaA, mediaA).request()))
        #expect(updates.last.map(AppleTransferTests.isStaged) == true, "\(updates)")
        #expect(fixture.backend.installedPacks.contains(Packs.media), "the transfer downloaded the pack again")
        fixture.backend.releaseRemove(Packs.media)
        #expect(await reclaim.value.released == ["ZTronMedia"])

        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronMedia"], "released once more")
        #expect(!fixture.backend.installedPacks.contains(Packs.media), "no copy stays next to the adopted blob")
        #expect(await fixture.source.sourceCopyBytes() == 0)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-CLN-10: a transfer that ends in skew never re-arms its pack's release within a catalog generation", .timeLimit(.minutes(1)))
    func skewedTransferDoesNotRearmTheRelease() async throws {
        // Verifier probe PROBE-R3-1 (ADR-027): the catalog lists `missing`, which the retention scope excludes and the
        // pack does not hold. Each request for it downloads the released pack on demand and ends in skew; if that
        // re-armed the release, every maintenance run would remove the pack again and every retry download it again.
        let adopted = PackAsset("ZTronMedia/a.bin", "adopted asset")
        let missing = PackAsset("ZTronMedia/b.bin", "listed by the catalog but missing from the pack")
        let fixture = AppleTierFixture(
            installed: [Packs.catalog: AppleTierFixture.catalogPack(), Packs.media: [adopted.path: adopted.bytes]],
            remote: [Packs.media: [adopted.path: adopted.bytes]]
        )
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        let report = AdoptionReport(
            manifestRemotePaths: [adopted.remotePath, missing.remotePath],
            adoptedRemotePaths: [adopted.remotePath],
            excludedRemotePaths: [missing.remotePath]
        )
        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronMedia"])
        for round in 1...3 {
            let updates = await collect(await fixture.source.transfer(missing.request(sequence: UInt32(round + 1))))
            #expect(updates == [.failed(.transient(.sourceVersionSkew, retryAfter: nil))], "round \(round)")
            #expect(await fixture.source.reclaimSourceCopies(report).released.isEmpty, "round \(round): released again")
        }
        #expect(fixture.backend.calls.filter { $0 == .remove(Packs.media) }.count == 1, "one release per generation")
        #expect(fixture.backend.installedPacks.contains(Packs.media), "the pack downloaded for the skewed entry stays")
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-CLN-10: a failed release is reported and planned again by the next reclaim", .timeLimit(.minutes(1)))
    func failedReleaseIsRetried() async throws {
        let fixture = AppleTierFixture(installed: [Packs.media: pack(mediaA)])
        let report = AdoptionReport(manifestRemotePaths: [mediaA], adoptedRemotePaths: [mediaA])
        fixture.backend.failRemove(Packs.media, with: .system(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        let failed = await fixture.source.reclaimSourceCopies(report)
        #expect(failed == ReclaimReport(released: [], failed: ["ZTronMedia": .transient(.timedOut, retryAfter: nil)]))
        #expect(fixture.tap.lines.contains { $0.category == .apple && $0.level == .error })

        fixture.backend.failRemove(Packs.media, with: nil)
        #expect(await fixture.source.reclaimSourceCopies(report) == ReclaimReport(released: ["ZTronMedia"]))
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-CLN-10: a pack the system already removed counts as released", .timeLimit(.minutes(1)))
    func absentPackCountsAsReleased() async throws {
        let fixture = AppleTierFixture()
        let report = AdoptionReport(manifestRemotePaths: [mediaA], adoptedRemotePaths: [mediaA])
        #expect(await fixture.source.reclaimSourceCopies(report) == ReclaimReport(released: ["ZTronMedia"]))
        #expect(await fixture.source.reclaimSourceCopies(report) == ReclaimReport())
        #expect(fixture.backend.calls == [.remove(Packs.media)])
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-CLN-10: keepPacks and an invalid catalog pack id never release through reclaim", .timeLimit(.minutes(1)))
    func keepPacksNeverReleases() async throws {
        let report = AdoptionReport(manifestRemotePaths: [mediaA], adoptedRemotePaths: [mediaA])
        let keeping = AppleTierFixture(
            installed: [Packs.media: pack(mediaA)],
            configuration: AppleTierConfiguration(retention: .keepPacks)
        )
        let invalid = AppleTierFixture(
            installed: [Packs.media: pack(mediaA)],
            configuration: AppleTierConfiguration(catalogPackID: "not a pack id")
        )
        #expect(await keeping.source.reclaimSourceCopies(report) == ReclaimReport())
        #expect(await invalid.source.reclaimSourceCopies(report) == ReclaimReport())
        #expect(keeping.backend.calls.isEmpty)
        #expect(invalid.backend.calls.isEmpty)
        await keeping.source.invalidate()
        await invalid.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-CLN-9: sourceCopyBytes sums the installed bytes of adopted media packs not yet released", .timeLimit(.minutes(1)))
    func sourceCopyBytesCountsAdoptedUnreleasedPacks() async throws {
        let fixture = AppleTierFixture(installed: [
            Packs.catalog: AppleTierFixture.catalogPack(), Packs.media: pack(mediaA, mediaB), Packs.extras: pack(extraC),
        ])
        fixture.backend.setInstalledBytes(Packs.media, 7_000)
        fixture.backend.setInstalledBytes(Packs.extras, 300)
        fixture.backend.setInstalledBytes(Packs.catalog, 50)
        #expect(await fixture.source.sourceCopyBytes() == 0, "nothing is known adopted before the first report")

        let entries = [mediaA, mediaB, extraC, "ZTronCatalog/catalog.json"]
        let first = await fixture.source.reclaimSourceCopies(
            AdoptionReport(manifestRemotePaths: entries, adoptedRemotePaths: [mediaA, "ZTronCatalog/catalog.json"])
        )
        #expect(first.released.isEmpty)
        #expect(await fixture.source.sourceCopyBytes() == 7_000, "the catalog pack is not a media pack")

        let second = await fixture.source.reclaimSourceCopies(
            AdoptionReport(manifestRemotePaths: entries, adoptedRemotePaths: [mediaA, mediaB])
        )
        #expect(second.released == ["ZTronMedia"])
        #expect(await fixture.source.sourceCopyBytes() == 0)

        let third = await fixture.source.reclaimSourceCopies(
            AdoptionReport(manifestRemotePaths: entries, adoptedRemotePaths: [mediaA, mediaB, extraC], excludedRemotePaths: [])
        )
        #expect(third.released == ["ZTronExtras"])
        #expect(await fixture.source.sourceCopyBytes() == 0)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-CLN-9: a released pack re-downloaded for an adopted asset counts as a source copy again", .timeLimit(.minutes(1)))
    func redownloadedPackCountsAsASourceCopy() async throws {
        let fixture = AppleTierFixture(
            installed: [Packs.catalog: AppleTierFixture.catalogPack(), Packs.media: pack(mediaA)],
            remote: [Packs.media: pack(mediaA)]
        )
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        let reclaim = await fixture.source.reclaimSourceCopies(
            AdoptionReport(manifestRemotePaths: [mediaA], adoptedRemotePaths: [mediaA])
        )
        #expect(reclaim.released == ["ZTronMedia"])
        #expect(await fixture.source.sourceCopyBytes() == 0)

        // The adopted blob was evicted and is fetched again: the copy finds the pack gone and downloads it.
        let updates = await collect(await fixture.source.transfer(PackAsset(mediaA, mediaA).request()))
        #expect(updates.last.map(AppleTransferTests.isStaged) == true, "\(updates)")
        #expect(await fixture.source.sourceCopyBytes() == Int64(mediaA.utf8.count), "the OS holds the pack again")
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-CLN-9: packs kept by keepPacks keep counting as source copies", .timeLimit(.minutes(1)))
    func keptPacksCount() async throws {
        let fixture = AppleTierFixture(
            installed: [Packs.media: pack(mediaA), Packs.extras: pack(extraC)],
            configuration: AppleTierConfiguration(retention: .keepPacks)
        )
        _ = await fixture.source.reclaimSourceCopies(
            AdoptionReport(manifestRemotePaths: [mediaA, extraC], adoptedRemotePaths: [mediaA, extraC])
        )
        #expect(await fixture.source.sourceCopyBytes() == Int64(mediaA.utf8.count + extraC.utf8.count))
        await fixture.source.invalidate()
    }
}
