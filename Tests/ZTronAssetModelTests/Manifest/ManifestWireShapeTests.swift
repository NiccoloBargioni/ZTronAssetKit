import Foundation
import Testing
import ZTronAssetModel

extension ModelSuites {
    /// R-MAN-1 and the shipped-series half of R-MAN-4: both wire shapes of every example manifest (ADR-008).
    @Suite("Manifest wire shapes")
    struct ManifestWireShapeTests {
        /// The seven legacy keys a bare-array entry may carry (README §1).
        private static let legacyKeys: Set<String> = [
            "identifier", "fileExtension", "remotePath", "localPathComponents", "localFileName", "byteSize", "checksum",
        ]

        @Test("R-MAN-1: both wire shapes of every shipped example manifest decode and round-trip with unknown fields ignored")
        func shippedManifestsDecodeAndRoundTrip() throws {
            let expectations = try ManifestFixtures.expectations()
            for tierName in ManifestFixtures.tiers {
                let tier = try #require(expectations.tiers[tierName])
                for (version, file) in tier.series.sorted(by: { $0.key < $1.key }) {
                    let manifest = try ManifestFixtures.decode(file.file)
                    #expect(manifest.shape == .bareArray, "\(file.file)")
                    #expect(manifest.count == file.assetCount, "\(tierName) \(version)")
                    #expect(manifest.entries.map(\.identifier).sortedRaw == file.identifiers, "\(file.file)")
                    #expect(manifest.quarantined.isEmpty, "\(file.file)")
                    #expect(manifest.digest == ContentHash.sha256(of: try ManifestFixtures.data(file.file)))
                    try self.expectLegacyKeysOnly(manifest, source: file.file)
                    try self.expectRoundTrip(manifest, source: file.file)
                }

                let envelope = try ManifestFixtures.decode(tier.envelope.file)
                #expect(envelope.shape == .envelope(schemaVersion: tier.envelope.schemaVersion))
                #expect(envelope.count == tier.envelope.assetCount)
                #expect(envelope.entries.map(\.identifier).sortedRaw == tier.envelope.identifiers)
                #expect(envelope.quarantined.isEmpty)
                try self.expectRoundTrip(envelope, source: tier.envelope.file)

                // Unknown fields (`buildInfo` at the top, `blurHash` on one asset) are ignored: stripped of the R-MAN-6
                // extension fields, the envelope's assets are exactly the bare v1 assets, in the same order.
                let bare = try ManifestFixtures.decode(try #require(tier.series["v1"]).file)
                let stripped = envelope.entries.map { entry -> ManifestEntry in
                    var copy = entry
                    copy.tags = []
                    copy.policy = .standard
                    return copy
                }
                #expect(stripped == bare.entries, "\(tierName): envelope assets differ from v1 beyond tags and policy")
                let blurHashEntry = try #require(envelope.entry(for: "bo6.tm.easter.egg.control.room.icon"))
                #expect(blurHashEntry == bare.entry(for: "bo6.tm.easter.egg.control.room.icon"))
            }
        }

        @Test("R-MAN-1: an envelope whose assets precede its schemaVersion decodes like one that declares it first")
        func envelopeMemberOrderDoesNotMatter() throws {
            let assets = try String(decoding: ManifestFixtures.data("manifests/aws/v1.json"), as: UTF8.self)
            let first = try ManifestDecoder.decode(Data("{\"schemaVersion\": 1, \"assets\": \(assets)}".utf8))
            let last = try ManifestDecoder.decode(Data("{\"note\": [1, {\"a\": null}], \"assets\": \(assets), \"schemaVersion\": 1}".utf8))
            #expect(first.entries == last.entries)
            #expect(first.shape == .envelope(schemaVersion: 1))
            #expect(last.shape == .envelope(schemaVersion: 1))
        }

        @Test("R-MAN-1: whitespace, a UTF-8 byte order mark and escaped key and value spellings decode like the plain text")
        func equivalentSpellingsDecodeAlike() throws {
            let plain = #"[{"identifier":"a.b","fileExtension":"png","remotePath":"media/a.png","localPathComponents":["A"]}]"#
            let spelled = "\u{FEFF}\n\t [ { \"\\u0069dentifier\" : \"a\\u002eb\", \"fileExtension\":\"p\\u006eg\",\r\n"
                + #""remotePath":"media\/a.png","localPathComponents":[ "A" ] } ] "#
            let a = try ManifestDecoder.decode(Data(plain.utf8))
            let b = try ManifestDecoder.decode(Data(spelled.utf8))
            #expect(a.entries == b.entries)
            #expect(b.entries.first?.identifier == "a.b")
            #expect(b.entries.first?.remotePath == "media/a.png")
        }

        @Test("R-MAN-1: an escaped key or policy names a field only when its decoded bytes spell the name, in every escape form")
        func escapedKeysMatchByDecodedBytes() throws {
            let head = #"{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":[]"#
            func decode(_ members: String) throws -> ValidatedManifest {
                try ManifestDecoder.decode(Data(("[" + head + "," + members + "}]").utf8))
            }
            // \u escapes spelling a known key of each length that two field names share (8, 10, 13), or a policy value.
            let checksum = String(repeating: "ab", count: 32)
            let spelled = try #require(try decode(
                #""\u0062yteSize":7,"\u0063hecksum":""# + checksum + #"","t\u0061gs":["x"],"polic\u0079":"\u0065ssential","localFileNam\u0065":"n""#
            ).entries.first)
            #expect(spelled.byteSize == 7 && spelled.checksum?.hex == checksum && spelled.tags == ["x"])
            #expect(spelled.policy == .essential && spelled.localFileName == "n")
            let required = #"[{"\u0069dentifier":"a","fil\u0065Extension":"png","r\u0065motePath":"m/a.png","localPathComponent\u0073":[]}]"#
            #expect(try ManifestDecoder.decode(Data(required.utf8)).entries.first?.remotePath == "m/a.png")

            // The same decoded length as a field name but other bytes: an unknown member, ignored. Two-byte (U+00E9),
            // three-byte (U+4E2D) and four-byte (a surrogate pair) scalars, and a simple or \u escape that differs only
            // at the last byte.
            let unknown = [
                #""byteSi\u00e9":"x""#, #""chec\u4e2dm":"x""#, #""\ud83d\ude00\ud83d\ude00":"x""#, #""\ud83d\ude00":"x""#,
                #""byteSiz\/":"x""#, #""checksu\u006e":"x""#, #""tag\u007a":"x""#, #""ta\u0067t":"x""#,
                #""identifi\u00e9":"x""#, #""remotePat\u0069":"x""#, #""localFileNa\u00e9":"x""#, #""fileExtensio\/":"x""#,
            ]
            for member in unknown {
                let manifest = try decode(member)
                let entry = manifest.entries.first
                #expect(manifest.quarantined.isEmpty && entry?.identifier == "a" && entry?.remotePath == "m/a.png", "\(member)")
                #expect(entry?.byteSize == nil && entry?.checksum == nil && entry?.tags == [] && entry?.localFileName == nil, "\(member)")
            }
            // A policy value is compared the same way: one byte off is not a policy.
            let quarantined = try decode(#""policy":"essentia\u006d""#).quarantined
            #expect(quarantined.map(\.violation) == [.malformedField("policy")])
        }

        @Test("R-MAN-1: non-ASCII text and surrogate-pair escapes decode to the same UTF-8 identifiers")
        func unicodeEscapesDecode() throws {
            let raw = #"[{"identifier":"caf\u00e9.\ud83d\ude00.\u4e2d","fileExtension":"png","remotePath":"m/x.png","localPathComponents":["Ünïcødé","日本"]}]"#
            let manifest = try ManifestDecoder.decode(Data(raw.utf8))
            let entry = try #require(manifest.entries.first)
            #expect(entry.identifier == AssetID("café.😀.中"))
            #expect(entry.localPathComponents == ["Ünïcødé", "日本"])
        }

        /// Re-encoding a decoded manifest and decoding it again yields the same entries, as a bare array and as an
        /// envelope.
        private func expectRoundTrip(_ manifest: ValidatedManifest, source: String) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let array = try encoder.encode(manifest.entries)
            let again = try ManifestDecoder.decode(array)
            #expect(again.entries == manifest.entries, "\(source) bare round trip")

            let assets = String(decoding: array, as: UTF8.self)
            let envelope = try ManifestDecoder.decode(Data("{\"assets\":\(assets),\"schemaVersion\":1}".utf8))
            #expect(envelope.entries == manifest.entries, "\(source) envelope round trip")
            #expect(envelope.shape == .envelope(schemaVersion: 1))
        }

        /// A legacy entry re-encodes with only the seven legacy keys, and with exactly the keys its source carried.
        private func expectLegacyKeysOnly(_ manifest: ValidatedManifest, source: String) throws {
            let original = try #require(
                try JSONSerialization.jsonObject(with: ManifestFixtures.data(source)) as? [[String: Any]]
            )
            let reencoded = try #require(
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest.entries)) as? [[String: Any]]
            )
            #expect(original.count == reencoded.count)
            for (before, after) in zip(original, reencoded) {
                #expect(Set(after.keys).isSubset(of: Self.legacyKeys), "\(source): \(after.keys.sorted())")
                #expect(Set(after.keys) == Set(before.keys), "\(source): \(before["identifier"] ?? "?")")
            }
        }
    }
}
