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
    @Test(
        "R-CLN-10: a released pack a transfer downloaded again for an adopted asset stays installed until the next catalog generation",
        .timeLimit(.minutes(1))
    )
    func redownloadedPackStaysUntilTheNextGeneration() async throws {
        // ADR-027 as ruled at the L2 close-out (cycle 3): a pack is released at most once per catalog generation and
        // never re-armed within one, so an adopted blob evicted and fetched again leaves its pack installed.
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

        #expect(await fixture.source.reclaimSourceCopies(report).released.isEmpty, "same catalog generation")
        #expect(fixture.backend.installedPacks.contains(Packs.media), "the pack stays until the next generation")
        #expect(await fixture.source.sourceCopyBytes() == Int64(mediaA.utf8.count), "and its bytes count as a source copy")
        #expect(fixture.backend.calls.filter { $0 == .remove(Packs.media) }.count == 1)

        fixture.backend.install(Packs.catalog, files: AppleTierFixture.catalogPack(Data(#"{"version":2}"#.utf8)))
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false, sequence: 2))
        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronMedia"], "a new catalog generation")
        #expect(!fixture.backend.installedPacks.contains(Packs.media))
        #expect(await fixture.source.sourceCopyBytes() == 0)
        #expect(fixture.backend.calls.filter { $0 == .remove(Packs.media) }.count == 2)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test(
        "R-CLN-10: a pack a transfer downloaded again while its release call was running stays released for that generation",
        .timeLimit(.minutes(1))
    )
    func redownloadDuringReleaseStaysReleased() async throws {
        let fixture = AppleTierFixture(
            installed: [Packs.catalog: AppleTierFixture.catalogPack(), Packs.media: pack(mediaA)],
            remote: [Packs.media: pack(mediaA)]
        )
        let report = AdoptionReport(manifestRemotePaths: [mediaA], adoptedRemotePaths: [mediaA])
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
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

        #expect(await fixture.source.reclaimSourceCopies(report).released.isEmpty, "released once in this generation")
        #expect(fixture.backend.installedPacks.contains(Packs.media), "the copy stays until the next generation")
        #expect(await fixture.source.sourceCopyBytes() == Int64(mediaA.utf8.count))
        #expect(fixture.backend.calls.filter { $0 == .remove(Packs.media) }.count == 1)

        fixture.backend.install(Packs.catalog, files: AppleTierFixture.catalogPack(Data(#"{"version":2}"#.utf8)))
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false, sequence: 2))
        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronMedia"], "a new catalog generation")
        #expect(await fixture.source.sourceCopyBytes() == 0)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test(
        "R-CLN-10: requesting an excluded asset after its pack's release removes the pack once per catalog generation, never in a loop",
        .timeLimit(.minutes(1))
    )
    func excludedAssetRequestsNeverLoopTheRelease() async throws {
        // Verifier probe PROBE-C1-1g (ADR-027): the retention scope excludes `viewed`, which the pack holds; the store
        // evicts out-of-scope entries first, so the asset is viewed on demand again and again. Re-arming the release
        // on each staged copy removed and downloaded the whole pack once per request-then-maintenance round.
        let adopted = PackAsset("ZTronMedia/a.bin", "adopted asset")
        let viewed = PackAsset("ZTronMedia/x.bin", "excluded by the retention scope, viewed on demand")
        let files = [adopted.path: adopted.bytes, viewed.path: viewed.bytes]
        let fixture = AppleTierFixture(
            installed: [Packs.catalog: AppleTierFixture.catalogPack(), Packs.media: files],
            remote: [Packs.media: files]
        )
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        let report = AdoptionReport(
            manifestRemotePaths: [adopted.remotePath, viewed.remotePath],
            adoptedRemotePaths: [adopted.remotePath],
            excludedRemotePaths: [viewed.remotePath]
        )
        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronMedia"])
        for round in 1...4 {
            let updates = await collect(await fixture.source.transfer(viewed.request(sequence: UInt32(round + 1))))
            #expect(updates.last.map(AppleTransferTests.isStaged) == true, "round \(round): \(updates)")
            #expect(await fixture.source.reclaimSourceCopies(report).released.isEmpty, "round \(round): released again")
        }
        #expect(fixture.backend.calls.filter { $0 == .remove(Packs.media) }.count == 1, "one removal per generation")
        #expect(fixture.backend.calls.filter { $0 == .ensure(Packs.media) }.count == 1, "one download per generation")
        #expect(fixture.backend.installedPacks.contains(Packs.media))

        // A new catalog generation releases the pack once again, and again never more than once.
        fixture.backend.install(Packs.catalog, files: AppleTierFixture.catalogPack(Data(#"{"version":2}"#.utf8)))
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false, sequence: 2))
        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronMedia"], "a new catalog generation")
        for round in 5...6 {
            let updates = await collect(await fixture.source.transfer(viewed.request(sequence: UInt32(round + 1))))
            #expect(updates.last.map(AppleTransferTests.isStaged) == true, "round \(round): \(updates)")
            #expect(await fixture.source.reclaimSourceCopies(report).released.isEmpty, "round \(round): released again")
        }
        #expect(fixture.backend.calls.filter { $0 == .remove(Packs.media) }.count == 2, "one removal per generation")
        #expect(fixture.backend.calls.filter { $0 == .ensure(Packs.media) }.count == 2, "one download per generation")
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
    @Test(
        "R-CLN-9: sourceCopyBytes sums the installed bytes of adopted media packs, and a pack the OS removed adds nothing",
        .timeLimit(.minutes(1))
    )
    func sourceCopyBytesCountsAdoptedPacks() async throws {
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
    @Test(
        "R-CLN-9: a released pack downloaded again on demand counts as a source copy until a later catalog generation releases it",
        .timeLimit(.minutes(1))
    )
    func releasedPackBackOnDemandCounts() async throws {
        // Verifier probe VC3-E (ADR-027 as ruled at the L2 close-out, cycle 3): the retention scope excludes the only
        // entry of the extras pack, so the first reclaim releases it. The store evicts the out-of-scope blob first, so
        // viewing the asset again downloads the pack on demand, and no later report names the entry adopted. The pack
        // stays installed for the rest of the generation, and the OS holds its bytes until a reclaim removes it.
        let adopted = PackAsset(mediaA, "adopted asset")
        let viewed = PackAsset(extraC, "excluded by the retention scope, viewed on demand")
        let fixture = AppleTierFixture(
            installed: [
                Packs.catalog: AppleTierFixture.catalogPack(),
                Packs.media: [adopted.path: adopted.bytes],
                Packs.extras: [viewed.path: viewed.bytes],
            ],
            remote: [Packs.extras: [viewed.path: viewed.bytes]]
        )
        fixture.backend.setInstalledBytes(Packs.media, 7_000)
        fixture.backend.setInstalledBytes(Packs.extras, 4_096)
        let report = AdoptionReport(
            manifestRemotePaths: [adopted.remotePath, viewed.remotePath],
            adoptedRemotePaths: [adopted.remotePath],
            excludedRemotePaths: [viewed.remotePath]
        )
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronExtras", "ZTronMedia"])
        #expect(await fixture.source.sourceCopyBytes() == 0, "a removed pack reports no bytes")

        let updates = await collect(await fixture.source.transfer(viewed.request()))
        #expect(updates.last.map(AppleTransferTests.isStaged) == true, "\(updates)")
        #expect(await fixture.source.reclaimSourceCopies(report).released.isEmpty, "same catalog generation")
        #expect(fixture.backend.installedPacks.contains(Packs.extras), "the pack stays until the next generation")
        #expect(await fixture.source.sourceCopyBytes() == 4_096, "the OS holds the released pack again")
        #expect(fixture.backend.calls.filter { $0 == .remove(Packs.extras) }.count == 1)

        // A new catalog digest alone removes nothing: the pack counts until a reclaim of that generation releases it.
        fixture.backend.install(Packs.catalog, files: AppleTierFixture.catalogPack(Data(#"{"version":2}"#.utf8)))
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false, sequence: 2))
        #expect(await fixture.source.sourceCopyBytes() == 4_096, "new generation, not yet released in it")
        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronExtras", "ZTronMedia"])
        #expect(!fixture.backend.installedPacks.contains(Packs.extras))
        #expect(await fixture.source.sourceCopyBytes() == 0)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test(
        "R-CLN-9: a pack whose release straddles a new catalog generation and comes back counts until that generation releases it",
        .timeLimit(.minutes(1))
    )
    func releaseAcrossGenerationsCounts() async throws {
        let viewed = PackAsset(extraC, "excluded by the retention scope, viewed on demand")
        let files = [viewed.path: viewed.bytes]
        let fixture = AppleTierFixture(
            installed: [Packs.catalog: AppleTierFixture.catalogPack(), Packs.extras: files],
            remote: [Packs.extras: files]
        )
        let report = AdoptionReport(
            manifestRemotePaths: [viewed.remotePath],
            adoptedRemotePaths: [],
            excludedRemotePaths: [viewed.remotePath]
        )
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false))
        fixture.backend.holdRemove(Packs.extras)
        let reclaim = Task {
            await fixture.source.reclaimSourceCopies(report)
        }
        await fixture.backend.waitFor(.remove(Packs.extras))

        // While the removal planned in the first generation runs, a new catalog opens the next generation and the
        // asset is viewed again, which downloads the pack on demand.
        fixture.backend.install(Packs.catalog, files: AppleTierFixture.catalogPack(Data(#"{"version":2}"#.utf8)))
        _ = try await fixture.source.fetchManifest(AppleTierFixture.manifestRequest(allowsUpdateCheck: false, sequence: 2))
        let updates = await collect(await fixture.source.transfer(viewed.request()))
        #expect(updates.last.map(AppleTransferTests.isStaged) == true, "\(updates)")
        fixture.backend.releaseRemove(Packs.extras)
        #expect(await reclaim.value.released == ["ZTronExtras"], "removed by the first generation's plan")

        #expect(fixture.backend.installedPacks.contains(Packs.extras))
        #expect(await fixture.source.sourceCopyBytes() == Int64(viewed.bytes.count), "released, and the OS holds it again")
        #expect(await fixture.source.reclaimSourceCopies(report).released == ["ZTronExtras"], "the new generation releases it")
        #expect(await fixture.source.sourceCopyBytes() == 0)
        #expect(fixture.backend.calls.filter { $0 == .remove(Packs.extras) }.count == 2)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test(
        "R-CLN-9: a pack whose planned removal is still running or failed counts as a source copy until a removal succeeds",
        .timeLimit(.minutes(1))
    )
    func packAwaitingRemovalCounts() async throws {
        // Verifier probe PROBE-C5-3 (R-CLN-9 as ruled at the L2 merge): the retention scope excludes the only entry of
        // the extras pack, so no report names it adopted and nothing released it yet. Its planned removal fails with a
        // system error, so the OS still holds the pack, and its bytes count until a removal succeeds.
        let excluded = PackAsset(extraC, "excluded by the retention scope")
        let fixture = AppleTierFixture(installed: [
            Packs.catalog: AppleTierFixture.catalogPack(), Packs.extras: [excluded.path: excluded.bytes],
        ])
        fixture.backend.setInstalledBytes(Packs.extras, 4_096)
        let report = AdoptionReport(
            manifestRemotePaths: [excluded.remotePath],
            adoptedRemotePaths: [],
            excludedRemotePaths: [excluded.remotePath]
        )
        fixture.backend.failRemove(Packs.extras, with: .system(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        fixture.backend.holdRemove(Packs.extras)
        let reclaim = Task {
            await fixture.source.reclaimSourceCopies(report)
        }
        await fixture.backend.waitFor(.remove(Packs.extras))
        #expect(await fixture.source.sourceCopyBytes() == 4_096, "the planned removal has not returned yet")

        fixture.backend.releaseRemove(Packs.extras)
        let failed = await reclaim.value
        #expect(failed.released.isEmpty)
        #expect(failed.failed.keys.sorted() == ["ZTronExtras"])
        #expect(fixture.backend.installedPacks.contains(Packs.extras))
        #expect(await fixture.source.sourceCopyBytes() == 4_096, "the removal failed, so the OS still holds the pack")

        fixture.backend.failRemove(Packs.extras, with: nil)
        #expect(await fixture.source.reclaimSourceCopies(report) == ReclaimReport(released: ["ZTronExtras"]))
        #expect(await fixture.source.sourceCopyBytes() == 0, "a removed pack reports no bytes")
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test(
        "R-CLN-9: a pack whose planned removal is running counts as a source copy even after a later survey finds it unsettled",
        .timeLimit(.minutes(1))
    )
    func removalInFlightCountsAcrossSurveys() async throws {
        // Verifier probe VP-A3 (R-CLN-9 as ruled at the L2 merge): reclaim A plans the excluded-only extras pack and its
        // removal is held, to fail with a system error. Meanwhile reclaim B surveys a newer report in which the pack
        // gained an entry nobody adopted yet, so B's survey no longer finds it settled. A's removal still runs and the
        // OS still holds the pack, so its bytes count whatever B's survey found. Once A's removal failed, the pack
        // counts only while the last survey finds it settled: B's does not, so it counts again once a survey does.
        let excluded = PackAsset(extraC, "excluded by the retention scope")
        let fixture = AppleTierFixture(installed: [
            Packs.catalog: AppleTierFixture.catalogPack(), Packs.extras: [excluded.path: excluded.bytes],
        ])
        fixture.backend.setInstalledBytes(Packs.extras, 4_096)
        let settledReport = AdoptionReport(
            manifestRemotePaths: [excluded.remotePath],
            adoptedRemotePaths: [],
            excludedRemotePaths: [excluded.remotePath]
        )
        let unsettledReport = AdoptionReport(
            manifestRemotePaths: [excluded.remotePath, "ZTronExtras/d.wav"],
            adoptedRemotePaths: [],
            excludedRemotePaths: [excluded.remotePath]
        )
        fixture.backend.failRemove(Packs.extras, with: .system(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        fixture.backend.holdRemove(Packs.extras)
        let reclaimA = Task {
            await fixture.source.reclaimSourceCopies(settledReport)
        }
        await fixture.backend.waitFor(.remove(Packs.extras))
        #expect(await fixture.source.sourceCopyBytes() == 4_096, "A's planned removal has not returned yet")

        #expect(await fixture.source.reclaimSourceCopies(unsettledReport) == ReclaimReport(), "B plans nothing")
        #expect(fixture.backend.installedPacks.contains(Packs.extras))
        #expect(await fixture.source.sourceCopyBytes() == 4_096, "A's removal still runs, whatever B's survey found")

        fixture.backend.releaseRemove(Packs.extras)
        #expect(await reclaimA.value.failed.keys.sorted() == ["ZTronExtras"])
        #expect(fixture.backend.installedPacks.contains(Packs.extras))
        #expect(await fixture.source.sourceCopyBytes() == 0, "failed, and the last survey no longer plans its removal")

        #expect(await fixture.source.reclaimSourceCopies(settledReport).failed.keys.sorted() == ["ZTronExtras"])
        #expect(await fixture.source.sourceCopyBytes() == 4_096, "failed again, and the last survey finds it settled")

        fixture.backend.failRemove(Packs.extras, with: nil)
        #expect(await fixture.source.reclaimSourceCopies(settledReport) == ReclaimReport(released: ["ZTronExtras"]))
        #expect(await fixture.source.sourceCopyBytes() == 0, "a removed pack reports no bytes")
        #expect(fixture.backend.calls.filter { $0 == .remove(Packs.extras) }.count == 3)
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, *)
    @Test("R-CLN-9: sourceCopyBytes saturates instead of trapping when the installed sizes sum past Int64.max", .timeLimit(.minutes(1)))
    func sourceCopyBytesSaturates() async throws {
        // Verifier probe PROBE-R3-2: `PackBackend` is public, so any injected backend can report such sizes.
        let fixture = AppleTierFixture(
            installed: [Packs.media: pack(mediaA), Packs.extras: pack(extraC)],
            configuration: AppleTierConfiguration(retention: .keepPacks)
        )
        fixture.backend.setInstalledBytes(Packs.media, Int64.max / 2 + 1)
        fixture.backend.setInstalledBytes(Packs.extras, Int64.max / 2 + 1)
        _ = await fixture.source.reclaimSourceCopies(
            AdoptionReport(manifestRemotePaths: [mediaA, extraC], adoptedRemotePaths: [mediaA, extraC])
        )
        #expect(await fixture.source.sourceCopyBytes() == Int64.max)

        fixture.backend.setInstalledBytes(Packs.media, Int64.max)
        fixture.backend.setInstalledBytes(Packs.extras, -5)
        #expect(await fixture.source.sourceCopyBytes() == Int64.max, "a negative size counts as nothing")
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
