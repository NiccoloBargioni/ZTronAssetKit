import Foundation
import Testing
import ZTronAssetAppleHosted
import ZTronAssetModel
import ZTronAssetTestSupport

private func location(_ remotePath: String) -> PackLocation {
    PackLocation(remotePath: remotePath)!
}

@Suite("Apple-hosted contracts")
struct AppleHostedContractTests {
    @Test("R-APL-5: tier selection is correct for all 16 input combinations")
    func tierSelectionTable() {
        #expect(TierInputs.allCases.count == 16)
        for inputs in TierInputs.allCases {
            let expected: Result<AssetTier, TierUnavailable>
            if inputs.osSupportsAppleTier && inputs.appleConfigured && !inputs.awsOnly {
                expected = .success(.appleHosted)
            } else if inputs.awsConfigured {
                expected = .success(.aws)
            } else {
                expected = .failure(.noSourceConfigured)
            }
            #expect(TierSelection.select(inputs) == expected, "inputs: \(inputs)")
        }
    }

    @available(macOS 15.0, *)
    @Test("R-APL-5: the awsOnly kill switch selects AWS on an OS that supports the Apple tier", .timeLimit(.minutes(1)))
    func killSwitchSelectsAWS() async throws {
        let aws = FakeRemoteSource(originID: "https://cdn.example.com:443")
        let configuration = RemoteConfiguration(
            http: HTTPSourceConfiguration(baseURL: try #require(URL(string: "https://cdn.example.com/"))),
            appleHosted: AppleTierConfiguration(),
            awsOnly: true
        )
        var awsBuilds = 0
        let resolved = AppleHostedTier.resolve(
            configuration: configuration,
            staging: FakeStagingSink(),
            packBackend: FakePackBackend(),
            makeAWS: { _ in
                awsBuilds += 1
                return aws
            }
        )
        let source = try resolved.get()
        #expect(source.originID == "https://cdn.example.com:443")
        #expect(source.capabilities.tier == .aws)
        #expect(awsBuilds == 1)

        let none = AppleHostedTier.resolve(
            configuration: RemoteConfiguration(http: nil, appleHosted: nil, awsOnly: false),
            staging: FakeStagingSink(),
            packBackend: FakePackBackend(),
            makeAWS: { _ in aws }
        )
        #expect(throws: TierUnavailable.noSourceConfigured) { try none.get() }
    }

    @Test("R-SEC-2: pack locations reject traversal, empty and dot segments and invalid pack ids")
    func packLocationValidation() {
        let valid = PackLocation(remotePath: "ZTronMedia/images/bo7.menu.background.heic")
        #expect(valid?.pack.rawValue == "ZTronMedia")
        #expect(valid?.path == "images/bo7.menu.background.heic")
        for hostile in [
            "ZTronMedia", "ZTronMedia/", "/ZTronMedia/a.png", "../ZTronMedia/a.png", "ZTronMedia/../a.png",
            "ZTronMedia/./a.png", "ZTronMedia//a.png", "../a.png", "./a.png", "Z Media/a.png",
            "ZTronMedia/a\u{0}.png", "ZTronMedia/a\n.png", String(repeating: "a", count: 65) + "/a.png",
        ] {
            #expect(PackLocation(remotePath: hostile) == nil, "\(hostile.debugDescription)")
        }
        #expect(PackID(rawValue: ".") == nil)
        #expect(PackID(rawValue: "..") == nil)
        #expect(PackID(rawValue: "ZTron.Catalog-1_a") != nil)
    }

    @Test("R-CLN-10: a media pack is released only after every catalog entry in it is adopted or excluded")
    func releaseRequiresEveryEntry() {
        let catalog = PackID(rawValue: "ZTronCatalog")!
        let entries = [
            location("ZTronMedia/a.png"), location("ZTronMedia/b.png"), location("ZTronExtras/c.wav"),
            location("ZTronCatalog/catalog.json"),
        ]
        func plan(adopted: Set<PackLocation>, excluded: Set<PackLocation> = [], released: Set<PackID> = []) -> [String] {
            PackReleasePlanner.packsToRelease(
                catalogEntries: entries,
                adopted: adopted,
                excluded: excluded,
                catalogPack: catalog,
                retention: .releaseAfterAdoption,
                alreadyReleased: released
            ).map(\.rawValue)
        }
        #expect(plan(adopted: [location("ZTronMedia/a.png")]) == [])
        #expect(plan(adopted: [location("ZTronMedia/a.png"), location("ZTronMedia/b.png")]) == ["ZTronMedia"])
        #expect(
            plan(adopted: [location("ZTronMedia/a.png")], excluded: [location("ZTronMedia/b.png"), location("ZTronExtras/c.wav")])
                == ["ZTronExtras", "ZTronMedia"]
        )
        let everything = Set(entries)
        #expect(plan(adopted: everything, released: [PackID(rawValue: "ZTronMedia")!]) == ["ZTronExtras"])
    }

    @Test("R-CLN-10: the catalog pack is never released and keepPacks never releases")
    func catalogAndKeepPacks() {
        let catalog = PackID(rawValue: "ZTronCatalog")!
        let entries = [location("ZTronCatalog/catalog.json"), location("ZTronMedia/a.png")]
        let all = Set(entries)
        #expect(
            PackReleasePlanner.packsToRelease(
                catalogEntries: entries, adopted: all, excluded: [], catalogPack: catalog,
                retention: .releaseAfterAdoption, alreadyReleased: []
            ).map(\.rawValue) == ["ZTronMedia"]
        )
        #expect(
            PackReleasePlanner.packsToRelease(
                catalogEntries: entries, adopted: all, excluded: [], catalogPack: catalog,
                retention: .keepPacks, alreadyReleased: []
            ).isEmpty
        )
    }
}
