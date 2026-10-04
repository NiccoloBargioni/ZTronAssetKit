import Foundation
import Testing
import ZTronAssetModel

extension ModelSuites {
    /// Which error a manifest with several problems is rejected with, and the agreement of the decoder with
    /// `ManifestDecoder.violations(of:limits:)` (R-MAN-1, R-MAN-2; ADR draft A-4.3, A-4.5, A-4.9, verifier round 3).
    @Suite("Manifest verdicts")
    struct ManifestVerdictTests {
        @Test("R-MAN-2: an envelope's verdict never depends on member order: an error of the document outranks one inside its assets")
        func envelopeVerdictIgnoresMemberOrder() {
            // The entries sit at depth 4 (envelope, assets, entry, path components); `assets` has one entry over the limit,
            // `duplicated` a repeated identifier.
            let options = ManifestDecodingOptions(limits: ManifestLimits(maxEntries: 2, maxNestingDepth: 4))
            let entry = { (identifier: String) in ManifestValidationTests.entryJSON(identifier: identifier) }
            let assets = "[" + entry("a") + "," + entry("b") + "," + entry("c") + "]"
            let duplicated = "[" + entry("a") + "," + entry("a") + "]"
            let members: [(String, ManifestError)] = [
                (#""x":[1 2]"#, .undecodable(.notJSON)),
                (#""x":[[[[1]]]]"#, .undecodable(.nestingTooDeep)),
                (#""x":"\ud800""#, .undecodable(.notJSON)),
                (#""schemaVersion":1"#, .undecodable(.unexpectedShape)),
                (#""assets":[]"#, .undecodable(.unexpectedShape)),
            ]
            for (member, expected) in members {
                for body in [assets, duplicated] {
                    let orders = [
                        "{\"schemaVersion\":1,\"assets\":\(body),\(member)}",
                        "{\(member),\"schemaVersion\":1,\"assets\":\(body)}",
                        "{\"assets\":\(body),\(member),\"schemaVersion\":1}",
                        "{\"assets\":\(body),\"schemaVersion\":1,\(member)}",
                    ]
                    for text in orders {
                        #expect(throws: expected, "\(text)") { try ManifestDecoder.decode(Data(text.utf8), options: options) }
                    }
                }
            }
            // With nothing else wrong, the assets' own error is reported in every order.
            for (body, expected) in [(assets, ManifestError.tooManyEntries(count: 3, limit: 2)), (duplicated, .duplicateIdentifier("a"))] {
                for text in ["{\"schemaVersion\":1,\"assets\":\(body)}", "{\"assets\":\(body),\"schemaVersion\":1}"] {
                    #expect(throws: expected, "\(text)") { try ManifestDecoder.decode(Data(text.utf8), options: options) }
                }
            }
        }

        @Test("R-MAN-2: a repeated identifier is reported at its second occurrence, before any error later in the assets")
        func duplicateIsReportedAtItsSecondOccurrence() {
            let entry = { (identifier: String) in ManifestValidationTests.entryJSON(identifier: identifier) }
            let twoEntries = ManifestDecodingOptions(limits: ManifestLimits(maxEntries: 2))
            let list = { (entries: [String]) in Data(("[" + entries.joined(separator: ",") + "]").utf8) }
            #expect(throws: ManifestError.duplicateIdentifier("a")) { try ManifestDecoder.decode(list([entry("a"), entry("a"), entry("b"), entry("c")]), options: twoEntries) }
            #expect(throws: ManifestError.tooManyEntries(count: 3, limit: 2)) {
                try ManifestDecoder.decode(list([entry("a"), entry("b"), entry("c"), entry("a")]), options: twoEntries)
            }
            // A quarantined occurrence counts under reject (ADR draft A-4.3), and keepFirst has no duplicate error.
            let quarantinedFirst = list([ManifestValidationTests.entryJSON(identifier: "a", fileExtension: "p.g"), entry("a"), entry("b"), entry("c")])
            #expect(throws: ManifestError.duplicateIdentifier("a")) { try ManifestDecoder.decode(quarantinedFirst, options: twoEntries) }
            let keepFirst = ManifestDecodingOptions(limits: ManifestLimits(maxEntries: 2), duplicates: .keepFirst)
            #expect(throws: ManifestError.tooManyEntries(count: 3, limit: 2)) {
                try ManifestDecoder.decode(list([entry("a"), entry("a"), entry("b")]), options: keepFirst)
            }
            // A repeat comes before the allocation estimate, which is judged only once the whole payload was surveyed.
            let dense = ManifestCorpus.shortComponentEntries(length: 16, maxBytes: 256 * 1_024)
            let denseTail = String(decoding: dense.dropFirst(), as: UTF8.self)
            let repeatedFirst = Data(("[" + entry("a") + "," + entry("a") + "," + denseTail).utf8)
            #expect(throws: ManifestError.duplicateIdentifier("a")) { try ManifestDecoder.decode(repeatedFirst) }
            // Without the repeat, the same payload is over the estimate's limit.
            let distinct = Data(("[" + entry("a") + "," + entry("b") + "," + denseTail).utf8)
            let error = #expect(throws: ManifestError.self) { try ManifestDecoder.decode(distinct) }
            guard case .decodedSizeExceeded(let estimated, let limit)? = error else {
                Issue.record("expected decodedSizeExceeded, got \(String(describing: error))")
                return
            }
            #expect(estimated > limit)
        }

        @Test("R-MAN-2: the decoder quarantines an entry exactly when violations(of:) reports a violation, and with the first, under any limits")
        func decoderAgreesWithViolationsUnderAnyLimits() throws {
            let seed: UInt64 = ProcessInfo.processInfo.environment["ZTRON_MANIFEST_RULES_SEED"].flatMap(UInt64.init) ?? 0xA6EE_0003
            print("R-MAN-2 rules agreement: seed \(seed) (replay with ZTRON_MANIFEST_RULES_SEED=\(seed))")
            var random = SplitMix64(seed: seed)
            func pick<Value>(_ values: [Value]) -> Value {
                values[Int(random.next() % UInt64(values.count))]
            }
            let identifiers = ["", "a", "ab", "abc", "a\u{1}", "a\u{85}b", "é", "日本", "0123456789abcdef", "x/y"]
            let extensions = ["", "p", "png", "PNG1", "toolong12", "p.g"]
            let paths = ["", "m", "m/a.png", "/abs", "../x", "a:b", "//h/x", "a\u{7F}", "a?b", "a#b", "media/0123456"]
            let componentCounts = [0, 1, 32, 33]
            let sizes: [Int64?] = [nil, 0, 5, -1, 101, Int64.max]
            let tagLists: [[String]] = [[], ["t"], ["", "t"], ["abc"], ["abcd"], ["a", "b", "c"]]
            var disagreements: [String] = []
            for round in 0..<3_000 {
                let limits = ManifestLimits(
                    maxIdentifierBytes: pick([-1, 0, 1, 2, 256]), maxRemotePathBytes: pick([-1, 0, 1, 8, 1_024]),
                    maxAssetBytes: pick([-1, 0, 100, 4 << 30]), maxTagBytes: pick([-1, 0, 1, 3, 128]),
                    maxTagsPerEntry: pick([-1, 0, 1, 2, 64])
                )
                let entry = ManifestEntry(
                    identifier: AssetID(pick(identifiers)), fileExtension: pick(extensions), remotePath: pick(paths),
                    localPathComponents: Array(repeating: "d", count: pick(componentCounts)), localFileName: pick([nil, "n"]),
                    byteSize: pick(sizes), tags: pick(tagLists)
                )
                let escaping = random.next() % 3
                let json = Self.json(of: entry, escaping: escaping, explicitEmptyTags: random.next() % 2 == 0)
                let expected = ManifestDecoder.violations(of: entry, limits: limits)
                let manifest = try ManifestDecoder.decode(Data(("[" + json + "]").utf8), options: ManifestDecodingOptions(limits: limits))
                let decoded = manifest.quarantined.map(\.violation)
                let agrees = expected.isEmpty ? manifest.count == 1 && decoded.isEmpty : manifest.count == 0 && decoded == [expected[0]]
                if !agrees {
                    disagreements.append("round \(round) \(json) \(limits): violations(of:) \(expected), decoder \(decoded)")
                }
            }
            #expect(disagreements.isEmpty, "\(disagreements.count) disagreements, first: \(disagreements.prefix(3))")
        }

        @Test("R-MAN-1: a trailing comma decodes exactly where the prior art's JSONDecoder accepted one")
        func trailingCommasMatchThePriorArt() throws {
            /// The prior art's asset (ZTronCarouselCore's `CDNAsset`), decoded with a plain `JSONDecoder`.
            struct PriorArtAsset: Decodable, Equatable {
                var identifier: String
                var fileExtension: String
                var remotePath: String
                var localPathComponents: [String]
            }
            let entry = #"{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":["A"]}"#
            let cases = [
                "[\(entry)]", "[\(entry),]", "[\(entry) , ]", "[\(entry)\n,\n]",
                #"[{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":["A",],}]"#,
                #"[{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":["A"],"x":[1,{"y":[2,],},],}]"#,
                "[\(entry),,]", "[,]", "[,\(entry)]", "[\(entry),\(entry),,]", #"[{,"identifier":"a"}]"#, "[\(entry) ,, ]",
                #"[{"identifier":"a",,"fileExtension":"png"}]"#, "[\(entry),",
            ]
            for text in cases {
                let priorArt = try? JSONDecoder().decode([PriorArtAsset].self, from: Data(text.utf8))
                let decoded = try? ManifestDecoder.decode(Data(text.utf8))
                #expect((decoded != nil) == (priorArt != nil), "\(text.debugDescription): prior art \(priorArt != nil), decoder \(decoded != nil)")
                if let decoded, let priorArt {
                    let entries = decoded.entries.map {
                        PriorArtAsset(identifier: $0.identifier.rawValue, fileExtension: $0.fileExtension, remotePath: $0.remotePath, localPathComponents: $0.localPathComponents)
                    }
                    #expect(entries == priorArt, "\(text.debugDescription)")
                }
            }
            // The envelope, new with this package, follows the same rule.
            let envelope = try ManifestDecoder.decode(Data(#"{"schemaVersion":1,"assets":[\#(entry),],}"#.utf8))
            #expect(envelope.count == 1 && envelope.shape == .envelope(schemaVersion: 1))
            #expect(throws: ManifestError.undecodable(.notJSON)) { try ManifestDecoder.decode(Data(#"{"schemaVersion":1,,"assets":[]}"#.utf8)) }
        }

        @Test("R-MAN-2: a raised nesting limit is honoured past 64 levels of mixed objects and arrays, and a mismatched closer there is not JSON")
        func deepNestingPastTheInlineStack() throws {
            // Levels alternate between arrays and objects, so the skipped value's container stack must remember each one
            // past the 64 levels it keeps inline (fix round 3).
            func nested(_ levels: Int, breakAt broken: Int? = nil) -> String {
                var open = ""
                var close = ""
                for level in 0..<levels {
                    let isObject = level.isMultiple(of: 2)
                    open += isObject ? "{\"k\":" : "["
                    let closer = isObject ? "}" : "]"
                    close = (level == broken ? (isObject ? "]" : "}") : closer) + close
                }
                return open + "1" + close
            }
            let entry = { (member: String) in #"[{"identifier":"a","fileExtension":"p","remotePath":"r","localPathComponents":[],"x":"# + member + "}]" }
            // The bare array and the entry take two of the 1,000 levels.
            let deep = ManifestDecodingOptions(limits: ManifestLimits(maxNestingDepth: 1_000))
            for levels in [63, 64, 65, 128, 129, 998] {
                let manifest = try ManifestDecoder.decode(Data(entry(nested(levels)).utf8), options: deep)
                #expect(manifest.count == 1, "\(levels) levels")
            }
            #expect(throws: ManifestError.undecodable(.nestingTooDeep)) { try ManifestDecoder.decode(Data(entry(nested(999)).utf8), options: deep) }
            for broken in [0, 63, 64, 65, 130, 500] {
                #expect(throws: ManifestError.undecodable(.notJSON), "closer broken at \(broken)") {
                    try ManifestDecoder.decode(Data(entry(nested(600, breakAt: broken)).utf8), options: deep)
                }
            }
        }

        // MARK: - Helpers

        /// The entry's JSON text, its strings escaped not at all (0), in their first scalar (1) or entirely (2).
        private static func json(of entry: ManifestEntry, escaping: UInt64, explicitEmptyTags: Bool) -> String {
            let quote = { (text: String) in Self.quoted(text, escaping: escaping) }
            var members = [
                "\"identifier\":" + quote(entry.identifier.rawValue),
                "\"fileExtension\":" + quote(entry.fileExtension),
                "\"remotePath\":" + quote(entry.remotePath),
                "\"localPathComponents\":[" + entry.localPathComponents.map(quote).joined(separator: ",") + "]",
            ]
            if let name = entry.localFileName {
                members.append("\"localFileName\":" + quote(name))
            }
            if let size = entry.byteSize {
                members.append("\"byteSize\":\(size)")
            }
            if !entry.tags.isEmpty || explicitEmptyTags {
                members.append("\"tags\":[" + entry.tags.map(quote).joined(separator: ",") + "]")
            }
            return "{" + members.joined(separator: ",") + "}"
        }

        /// A JSON string literal for `text`: control characters, quotes and backslashes are always escaped, and the
        /// first or every scalar is spelled as a `\u` escape (a surrogate pair beyond the BMP) when asked.
        private static func quoted(_ text: String, escaping: UInt64) -> String {
            var result = "\""
            for (offset, scalar) in text.unicodeScalars.enumerated() {
                let escapeAll = escaping == 2 || (escaping == 1 && offset == 0)
                if escapeAll || scalar.value < 0x20 || scalar == "\"" || scalar == "\\" {
                    result += Self.unicodeEscape(scalar)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
            return result + "\""
        }

        private static func unicodeEscape(_ scalar: Unicode.Scalar) -> String {
            let units = String(scalar).utf16.map { String(format: "\\u%04x", $0) }
            return units.joined()
        }
    }
}
