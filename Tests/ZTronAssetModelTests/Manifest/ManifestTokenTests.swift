import Foundation
import Testing
@testable import ZTronAssetModel

extension ModelSuites {
    /// The decoder's building blocks below `ManifestDecoder`: how string tokens are compared and hashed for the
    /// duplicate rules, and the rules' first-violation shortcuts (fix round 3).
    @Suite("Manifest tokens")
    struct ManifestTokenTests {
        @Test("R-MAN-2: identifiers are compared and hashed by their decoded bytes whatever their escapes, without a copy")
        func tokensCompareByDecodedBytes() throws {
            // Spellings of the same identifiers, raw and escaped: ASCII across eight-byte words, two-, three- and
            // four-byte scalars (a surrogate pair), and simple escapes.
            let groups: [[String]] = [
                [#""a""#, #""\u0061""#],
                [#""abcdefgh""#, #""abcdefg\u0068""#, #""\u0061bcdefgh""#],
                [#""abcdefghi""#, #""abcdefgh\u0069""#],
                [#""é.日😀""#, #""\u00e9.\u65e5\ud83d\ude00""#, #""é.\u65E5😀""#],
                [#""a/b""#, #""a\/b""#],
                [#""bo7.ri.easter.egg.asset.12""#, #""bo7.ri.easter.egg.asset.1\u0032""#],
                [#""b""#, #""\u0062""#],
            ]
            let differing = [#""abcdefgi""#, #""abcdefgH""#, #""é.日😁""#, #""a\\b""#, #""bo7.ri.easter.egg.asset.13""#]
            let texts = groups.flatMap { $0 } + differing
            let payload = Data(texts.joined(separator: " ").utf8)
            try payload.withUnsafeBytes { bytes throws(ManifestError) in
                var cursor = JSONCursor(bytes: bytes, maxDepth: 4)
                var tokens: [JSONString] = []
                for _ in texts {
                    cursor.skipWhitespace()
                    tokens.append(try cursor.scanString())
                }
                func hash(_ token: JSONString) -> Int {
                    var hasher = Hasher()
                    cursor.hash(token, into: &hasher)
                    return hasher.finalize()
                }
                func decoded(_ token: JSONString) -> [UInt8] {
                    var iterator = cursor.decodedBytes(iterating: token)
                    var bytes: [UInt8] = []
                    while let byte = iterator.next() {
                        bytes.append(byte)
                    }
                    return bytes
                }
                var group = [Int]()
                for (index, members) in groups.enumerated() {
                    group += Array(repeating: index, count: members.count)
                }
                group += differing.indices.map { groups.count + $0 }
                for (i, lhs) in tokens.enumerated() {
                    // The iterator decodes exactly what the copying decoder does.
                    #expect(decoded(lhs) == cursor.decodedBytes(of: lhs), "\(texts[i])")
                    #expect(cursor.string(startingAt: lhs.start).map { $0.end == lhs.end && $0.decodedCount == lhs.decodedCount } == true)
                    for (j, rhs) in tokens.enumerated() {
                        let equal = decoded(lhs) == decoded(rhs)
                        #expect(cursor.string(lhs, equalsString: rhs) == equal, "\(texts[i]) vs \(texts[j])")
                        if equal {
                            #expect(hash(lhs) == hash(rhs), "\(texts[i]) vs \(texts[j])")
                        }
                        // Spellings of one identifier are equal exactly when they are in the same group.
                        #expect(equal == (group[i] == group[j]), "\(texts[i]) vs \(texts[j])")
                    }
                }
            }

            // The survey's table finds the repeats among them, and keeps every distinct one.
            let entries = texts.map { #"{"identifier":\#($0),"fileExtension":"png","remotePath":"m","localPathComponents":[]}"# }
            let keepFirst = try ManifestDecoder.decode(Data(("[" + entries.joined(separator: ",") + "]").utf8), options: ManifestDecodingOptions(duplicates: .keepFirst))
            #expect(keepFirst.count == groups.count + differing.count, "\(keepFirst.entries.map(\.identifier))")
            #expect(keepFirst.quarantinedCount == texts.count - keepFirst.count)
        }

        @Test("R-MAN-2: the rules' first violation is the first of every violation, and an in-memory manifest of any size rejects a repeat")
        func firstViolationsAndInMemoryRepeats() throws {
            let limits = ManifestLimits(maxIdentifierBytes: 2, maxRemotePathBytes: 3)
            for identifier in ["", "a", "abc", "a\u{1}", "abc\u{1}"] {
                let first = ManifestRules.withUTF8(of: identifier) { ManifestRules.firstIdentifierViolation(utf8: $0, limits: limits) }
                let all = ManifestRules.withUTF8(of: identifier) { ManifestRules.identifierViolations(utf8: $0, limits: limits) }
                #expect(first == all.first, "\(identifier.debugDescription)")
            }
            for path in ["", "m", "/abcd", "a:b//c", "../x?y", "abcd\u{1}", "a?b"] {
                let first = ManifestRules.withUTF8(of: path) { ManifestRules.firstRemotePathViolation(utf8: $0, limits: limits) }
                let all = ManifestRules.withUTF8(of: path) { ManifestRules.remotePathViolations(utf8: $0, limits: limits) }
                #expect(first == all.first, "\(path.debugDescription)")
            }
            // Past the linear-lookup limit the in-memory initialiser indexes, and still rejects a repeat.
            let entries = (0..<12).map { ManifestEntry(identifier: AssetID("id.\($0 % 11)"), fileExtension: "png", remotePath: "m") }
            #expect(throws: ManifestError.duplicateIdentifier("id.0")) { try ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data())) }
            let distinct = try ValidatedManifest(entries: Array(entries.prefix(11)), quarantinedCount: 3, digest: ContentHash.sha256(of: Data()))
            #expect(distinct.position(of: "id.10") == 10 && distinct.contains("id.0") && !distinct.contains("id.11"))
            #expect(distinct.quarantinedCount == 3 && distinct.quarantined.isEmpty)
            #expect(ManifestFootprint.table(count: 0, stride: 24) == 0)
        }
    }
}
