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
