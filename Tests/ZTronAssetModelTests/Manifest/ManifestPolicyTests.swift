import Foundation
import Testing
import ZTronAssetModel

extension ModelSuites {
    /// R-MAN-6: the optional `tags` and `policy` extension fields, and that leaving them out changes nothing.
    @Suite("Manifest extension fields")
    struct ManifestPolicyTests {
        @Test("R-MAN-6: absent tags and policy reproduce the prior art's behaviour")
        func absentFieldsReproducePriorArt() throws {
            let legacy = try ManifestFixtures.decode("manifests/aws/v1.json")
            // Decoded as untagged, standard entries, by the lenient decoder and by the strict Codable path alike.
            #expect(legacy.entries.allSatisfy { $0.tags.isEmpty && $0.policy == .standard })
            let strict = try JSONDecoder().decode([ManifestEntry].self, from: ManifestFixtures.data("manifests/aws/v1.json"))
            #expect(strict == legacy.entries)

            // An explicit default is the same entry, so it is "unchanged" to the diff, and re-encodes as legacy.
            let explicit = #"[{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":[],"tags":[],"policy":"standard"}]"#
            let absent = #"[{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":[]}]"#
            let withDefaults = try ManifestDecoder.decode(Data(explicit.utf8))
            let without = try ManifestDecoder.decode(Data(absent.utf8))
            #expect(withDefaults.entries == without.entries)
            #expect(ManifestDiff.compute(from: without, to: withDefaults).isEmpty)
            let reencoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(withDefaults.entries)) as? [[String: Any]])
            #expect(reencoded.first.map { Set($0.keys) } == ["identifier", "fileExtension", "remotePath", "localPathComponents"])

            // The prior art fetched every asset: untagged standard entries are all in the default scope, none in a tag
            // scope.
            #expect(legacy.entries.allSatisfy { AssetScope.all.contains($0) })
            #expect(legacy.entries.allSatisfy { !AssetScope.tags(["easter-egg"]).contains($0) })
            #expect(!AssetScope.all.isExplicit)

            // Among explicit policies, an entry without one is fetched exactly where an explicit `standard` entry is:
            // after essential, before on-demand, in manifest order among its peers (AssetPolicy's own order, then
            // position). Spelling the absent policy out changes no position.
            func fetchOrder(_ firstPolicy: String) throws -> [AssetID] {
                let members = [firstPolicy, #","policy":"onDemand""#, #","policy":"essential""#, #","policy":"standard""#, ""]
                let entries = members.enumerated().map { index, policy in
                    #"{"identifier":"e\#(index)","fileExtension":"png","remotePath":"m/\#(index).png","localPathComponents":[]"# + policy + "}"
                }
                let manifest = try ManifestDecoder.decode(Data(("[" + entries.joined(separator: ",") + "]").utf8))
                return manifest.entries.enumerated()
                    .sorted { $0.element.policy < $1.element.policy || ($0.element.policy == $1.element.policy && $0.offset < $1.offset) }
                    .map(\.element.identifier)
            }
            #expect(try fetchOrder("") == ["e2", "e0", "e3", "e4", "e1"])
            #expect(try fetchOrder(#","policy":"standard""#) == fetchOrder(""))
            #expect(try fetchOrder(#","policy":"essential""#) != fetchOrder(""))
        }

        @Test("R-MAN-6: tags and policy decode from the envelope and order fetches essential, then standard, then on-demand")
        func extensionFieldsDecodeAndRank() throws {
            let envelope = try ManifestFixtures.decode("manifests/aws/v1.envelope.json")
            let icon = try #require(envelope.entry(for: "bo7.ri.easter.egg.vehytherion.temple.icon"))
            #expect(icon.tags == ["easter-egg", "icon"] && icon.policy == .essential)
            #expect(envelope.entry(for: "bo7.ri.cinematic.intro")?.policy == .onDemand)
            #expect(envelope.entry(for: "waw.ndu.title.card")?.policy == .standard)
            #expect(envelope.entries.filter { AssetScope.tags(["easter-egg"]).contains($0) }.map(\.identifier).sorted()
                == ["bo7.ri.easter.egg.vehytherion.temple.icon", "bo7.ri.easter.egg.vehytherion.temple.map"])
            #expect(AssetPolicy.allCases.sorted() == [.essential, .standard, .onDemand])
            #expect(AssetPolicy.allCases.map(\.rank) == [0, 1, 2])
            #expect(AssetPolicy.essential < .standard && AssetPolicy.standard < .onDemand)

            let ranked = envelope.entries.enumerated().sorted { ($0.element.policy.rank, $0.offset) < ($1.element.policy.rank, $1.offset) }
            let policies = ranked.map(\.element.policy)
            #expect(policies == policies.sorted())
            #expect(policies.first == .essential && policies.last == .onDemand)
        }

        @Test("R-CAR-5: identifier, prefix and tag scopes select by exact identifier bytes, UTF-8 prefix and any shared tag")
        func scopesSelectEntries() {
            let entry = ManifestEntry(identifier: "bo7.ri.map", fileExtension: "png", remotePath: "m/x.png", tags: ["a", "b"])
            #expect(AssetScope.identifiers(["bo7.ri.map"]).contains(entry))
            #expect(!AssetScope.identifiers(["bo7.ri.Map"]).contains(entry))
            #expect(AssetScope.identifiers([]).isExplicit)
            #expect(AssetScope.prefix("bo7.ri.").contains(entry))
            #expect(!AssetScope.prefix("bo6.").contains(entry))
            #expect(AssetScope.tags(["z", "b"]).contains(entry))
            #expect(!AssetScope.tags([]).contains(entry))
            #expect(!AssetScope.prefix("bo7").isExplicit && !AssetScope.tags(["a"]).isExplicit)
        }
    }
}
