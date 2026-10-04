import Foundation
import Testing
import ZTronAssetModel

extension ModelSuites {
    /// R-MAN-2: the manifest is untrusted input. Structural violations reject it with a typed error; per-entry
    /// violations quarantine only that entry with a diagnostic.
    @Suite("Manifest validation")
    struct ManifestValidationTests {
        /// The per-entry violation each negative fixture must produce (README §5).
        private static let expectedViolations: [String: ManifestEntryViolation] = [
            "manifests/invalid/bad-extension-empty.json": .fileExtensionInvalid,
            "manifests/invalid/bad-extension-too-long.json": .fileExtensionInvalid,
            "manifests/invalid/bad-extension.json": .fileExtensionInvalid,
            "manifests/invalid/byte-size-negative.json": .byteSizeOutOfRange(-1),
            "manifests/invalid/checksum-non-hex.json": .checksumInvalid,
            "manifests/invalid/checksum-wrong-length.json": .checksumInvalid,
            "manifests/invalid/identifier-control-character.json": .identifierControlCharacter,
            "manifests/invalid/identifier-empty.json": .identifierEmpty,
            "manifests/invalid/remote-path-absolute.json": .remotePathInvalid(.absolute),
            "manifests/invalid/remote-path-embedded-dotdot.json": .remotePathInvalid(.parentSegment),
            "manifests/invalid/remote-path-scheme-authority.json": .remotePathInvalid(.scheme),
            "manifests/invalid/remote-path-traversal-dotdot.json": .remotePathInvalid(.parentSegment),
        ]

        /// The typed error each rejected fixture must produce, by reason class.
        private static let expectedErrors: [String: ManifestError] = [
            "duplicate-identifiers": .duplicateIdentifier("bo7.ri.music.main.theme"),
            "undecodable-not-json": .undecodable(.notJSON),
            "undecodable-nesting-depth": .undecodable(.nestingTooDeep),
            "unsupported-schema-version": .unsupportedSchemaVersion(99),
        ]

        @Test("R-MAN-2: every structural violation rejects the manifest and every per-entry violation quarantines only that entry")
        func negativeFixturesRejectOrQuarantine() throws {
            let expectations = try ManifestFixtures.expectations()
            #expect(expectations.invalid.count == 16)
            for (file, expected) in expectations.invalid.sorted(by: { $0.key < $1.key }) {
                let bytes = try ManifestFixtures.data(file)
                switch expected.outcome {
                case "entryQuarantined":
                    let manifest = try ManifestDecoder.decode(bytes)
                    #expect(manifest.quarantined.map(\.index) == expected.quarantinedIndices, "\(file)")
                    #expect(manifest.quarantined.compactMap { $0.identifier?.rawValue } == expected.quarantinedIdentifiers, "\(file)")
                    #expect(manifest.quarantined.allSatisfy { $0.identifier != nil }, "\(file)")
                    #expect(manifest.entries.map(\.identifier).sortedRaw == expected.survivingIdentifiers, "\(file)")
                    #expect(manifest.quarantined.map(\.violation) == [Self.expectedViolations[file]].compactMap { $0 }, "\(file)")
                case "manifestRejected":
                    let reason = try #require(expected.reasonClass)
                    let error = try #require(Self.expectedErrors[reason], "no expected error for \(reason)")
                    #expect(throws: error, "\(file)") { try ManifestDecoder.decode(bytes) }
                default:
                    Issue.record("unknown outcome \(expected.outcome) for \(file)")
                }
            }

            // Structural violations the fixtures do not cover.
            let tooLarge = ManifestDecodingOptions(limits: ManifestLimits(maxPayloadBytes: 10))
            #expect(throws: ManifestError.payloadTooLarge(bytes: 11, limit: 10)) {
                try ManifestDecoder.decode(Data(repeating: 0x20, count: 11), options: tooLarge)
            }
            let twoEntries = ManifestDecodingOptions(limits: ManifestLimits(maxEntries: 2))
            #expect(throws: ManifestError.tooManyEntries(count: 3, limit: 2)) {
                try ManifestDecoder.decode(Data("[{},{},{}]".utf8), options: twoEntries)
            }
            for shape in [#"{"schemaVersion":1}"#, #"{"assets":[]}"#, "42", #""text""#, "null", #"{"schemaVersion":1,"assets":{}}"#] {
                #expect(throws: ManifestError.undecodable(.unexpectedShape), "\(shape)") {
                    try ManifestDecoder.decode(Data(shape.utf8))
                }
            }
            for broken in ["", "[", "[{}", "[1,,]", "[,]", "[] x", "{\"assets\":[],,}", "nul", "[\"\u{01}\"]", "[01]"] {
                #expect(throws: ManifestError.undecodable(.notJSON), "\(broken.debugDescription)") {
                    try ManifestDecoder.decode(Data(broken.utf8))
                }
            }
        }

        @Test("R-MAN-2: an envelope declaring an unsupported schemaVersion is rejected as unsupported whatever its assets member looks like")
        func unsupportedVersionWinsOverShape() {
            // A later schema may restructure `assets` (or drop it): a v1 client must say "unsupported version", not
            // "corrupt manifest", in either member order (ManifestError.unsupportedSchemaVersion, ADR draft A-4.9).
            let unsupported = [
                #"{"schemaVersion":2,"assets":[]}"#,
                #"{"schemaVersion":2,"assets":{"a":{}}}"#,
                #"{"assets":{"a":{}},"schemaVersion":2}"#,
                #"{"schemaVersion":2,"packs":[]}"#,
                #"{"packs":[],"schemaVersion":2}"#,
                #"{"schemaVersion":2,"assets":[],"assets":[]}"#,
                #"{"assets":[],"assets":[],"schemaVersion":2}"#,
                #"{"assets":"x","schemaVersion":2,"assets":7}"#,
                #"{"schemaVersion":2,"assets":[],}"#,
            ]
            for text in unsupported {
                #expect(throws: ManifestError.unsupportedSchemaVersion(2), "\(text)") { try ManifestDecoder.decode(Data(text.utf8)) }
            }
            #expect(throws: ManifestError.unsupportedSchemaVersion(0)) { try ManifestDecoder.decode(Data(#"{"assets":7,"schemaVersion":0}"#.utf8)) }
            // A supported version keeps the v1 shape rule: assets present, an array, and not repeated.
            let malformed = [
                #"{"schemaVersion":1,"assets":{"a":{}}}"#,
                #"{"assets":{"a":{}},"schemaVersion":1}"#,
                #"{"schemaVersion":1,"packs":[]}"#,
                #"{"schemaVersion":1,"assets":[],"assets":[]}"#,
                #"{"assets":[],"assets":[],"schemaVersion":1}"#,
                #"{"assets":[],"schemaVersion":1,"assets":[]}"#,
                #"{"assets":{"a":{}}}"#,
            ]
            for text in malformed {
                #expect(throws: ManifestError.undecodable(.unexpectedShape), "\(text)") { try ManifestDecoder.decode(Data(text.utf8)) }
            }
            // A document that is not JSON, or nests too deep, is that whatever version it declares, in either member
            // order: the version is judged only once the whole document has been read.
            let notJSON = [
                #"{"assets":{"a":},"schemaVersion":2}"#, #"{"schemaVersion":2,"assets":{"a":}}"#,
                #"{"schemaVersion":2,"assets":[]"#, #"{"schemaVersion":2,"assets":[],,}"#, #"{"schemaVersion":2,"assets":[]} x"#,
            ]
            for text in notJSON {
                #expect(throws: ManifestError.undecodable(.notJSON), "\(text)") { try ManifestDecoder.decode(Data(text.utf8)) }
            }
            let deep = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
            for text in [#"{"schemaVersion":2,"assets":"# + deep + "}", #"{"assets":"# + deep + #","schemaVersion":2}"#] {
                #expect(throws: ManifestError.undecodable(.nestingTooDeep)) { try ManifestDecoder.decode(Data(text.utf8)) }
            }
        }

        @Test("R-MAN-2: limit boundaries accept the limit and reject one past it")
        func limitBoundaries() throws {
            // Payload size.
            let payload = Data("[]".utf8)
            #expect(try ManifestDecoder.decode(payload, options: Self.options(ManifestLimits(maxPayloadBytes: 2))).count == 0)
            #expect(throws: ManifestError.payloadTooLarge(bytes: 2, limit: 1)) {
                try ManifestDecoder.decode(payload, options: Self.options(ManifestLimits(maxPayloadBytes: 1)))
            }

            // Entry count.
            let three = Self.payload((0..<3).map { Self.entryJSON(identifier: "id.\($0)") })
            #expect(try ManifestDecoder.decode(three, options: Self.options(ManifestLimits(maxEntries: 3))).count == 3)
            #expect(throws: ManifestError.tooManyEntries(count: 3, limit: 2)) {
                try ManifestDecoder.decode(three, options: Self.options(ManifestLimits(maxEntries: 2)))
            }

            // Identifier bytes, counted in UTF-8 ("é" is two bytes).
            let limits = ManifestLimits(maxIdentifierBytes: 6, maxRemotePathBytes: 8, maxAssetBytes: 100, maxTagBytes: 3, maxTagsPerEntry: 2)
            try Self.expectAccepted(Self.entryJSON(identifier: "a.déf"), limits: limits)
            try Self.expectQuarantined(Self.entryJSON(identifier: "a.déf1"), as: .identifierTooLong(bytes: 7), limits: limits)

            // remotePath bytes.
            try Self.expectAccepted(Self.entryJSON(remotePath: "m/é.png"), limits: limits)
            try Self.expectQuarantined(Self.entryJSON(remotePath: "m/aé.png"), as: .remotePathInvalid(.tooLong(bytes: 9)), limits: limits)

            // byteSize within 0...maxAssetBytes.
            try Self.expectAccepted(Self.entryJSON(extra: #""byteSize":0"#), limits: limits)
            try Self.expectAccepted(Self.entryJSON(extra: #""byteSize":100"#), limits: limits)
            try Self.expectQuarantined(Self.entryJSON(extra: #""byteSize":101"#), as: .byteSizeOutOfRange(101), limits: limits)
            try Self.expectQuarantined(Self.entryJSON(extra: #""byteSize":-1"#), as: .byteSizeOutOfRange(-1), limits: limits)

            // fileExtension is 1...8 ASCII letters or digits.
            try Self.expectAccepted(Self.entryJSON(fileExtension: "a"), limits: limits)
            try Self.expectAccepted(Self.entryJSON(fileExtension: "AbCd5678"), limits: limits)
            try Self.expectQuarantined(Self.entryJSON(fileExtension: "AbCd56789"), as: .fileExtensionInvalid, limits: limits)
            try Self.expectQuarantined(Self.entryJSON(fileExtension: ""), as: .fileExtensionInvalid, limits: limits)

            // checksum is exactly 64 hex characters, either case.
            let hex = String(repeating: "aB", count: 32)
            try Self.expectAccepted(Self.entryJSON(extra: "\"checksum\":\"\(hex)\""), limits: limits)
            try Self.expectQuarantined(Self.entryJSON(extra: "\"checksum\":\"\(hex)0\""), as: .checksumInvalid, limits: limits)
            try Self.expectQuarantined(Self.entryJSON(extra: "\"checksum\":\"\(hex.dropLast())\""), as: .checksumInvalid, limits: limits)

            // Tags: each 1...maxTagBytes bytes, at most maxTagsPerEntry of them.
            try Self.expectAccepted(Self.entryJSON(extra: #""tags":["abc","d"]"#), limits: limits)
            try Self.expectQuarantined(Self.entryJSON(extra: #""tags":["abcd"]"#), as: .tagInvalid, limits: limits)
            try Self.expectQuarantined(Self.entryJSON(extra: #""tags":["a","b","c"]"#), as: .tagInvalid, limits: limits)
            try Self.expectQuarantined(Self.entryJSON(extra: #""tags":[""]"#), as: .tagInvalid, limits: limits)

            // Path components: at most 32 (the index's per-record limit, store design §2.3). Three-byte ones: 32 one-byte
            // components alone need four times their payload (a 640-byte array for 128 bytes), over R-MAN-3's bound.
            let components = { (count: Int) in "\"localPathComponents\":[" + Array(repeating: "\"dir\"", count: count).joined(separator: ",") + "]" }
            try Self.expectAccepted(Self.entryJSON(components: components(32)), limits: limits)
            try Self.expectQuarantined(Self.entryJSON(components: components(33)), as: .malformedField("localPathComponents"), limits: limits)

            // Nesting depth: the bare array (1), the entry (2), then an unknown field nested to the limit.
            let nested = { (levels: Int) in "\"x\":" + String(repeating: "[", count: levels) + String(repeating: "]", count: levels) }
            let depthLimits = ManifestLimits(maxNestingDepth: 10)
            try Self.expectAccepted(Self.entryJSON(extra: nested(8)), limits: depthLimits)
            #expect(throws: ManifestError.undecodable(.nestingTooDeep)) {
                try ManifestDecoder.decode(Self.payload([Self.entryJSON(extra: nested(9))]), options: Self.options(depthLimits))
            }

            // Envelope schema version.
            let envelope = { (version: Int) in Data("{\"schemaVersion\":\(version),\"assets\":[]}".utf8) }
            #expect(try ManifestDecoder.decode(envelope(2), options: ManifestDecodingOptions(maxSchemaVersion: 2)).shape == .envelope(schemaVersion: 2))
            #expect(throws: ManifestError.unsupportedSchemaVersion(3)) {
                try ManifestDecoder.decode(envelope(3), options: ManifestDecodingOptions(maxSchemaVersion: 2))
            }
            #expect(throws: ManifestError.unsupportedSchemaVersion(0)) { try ManifestDecoder.decode(envelope(0)) }
        }

        @Test("R-MAN-2: the default options enforce the SPEC's numbers: 256-byte identifiers, 1,024-byte paths, 100,000 entries, 32 MiB")
        func defaultLimitBoundaries() throws {
            let defaults = ManifestLimits()
            // Identifier: 256 UTF-8 bytes accepted, 257 quarantined.
            try Self.expectAccepted(Self.entryJSON(identifier: String(repeating: "i", count: 256)), limits: defaults)
            try Self.expectQuarantined(Self.entryJSON(identifier: String(repeating: "i", count: 257)), as: .identifierTooLong(bytes: 257), limits: defaults)
            // remotePath: 1,024 bytes accepted, 1,025 quarantined.
            try Self.expectAccepted(Self.entryJSON(remotePath: String(repeating: "p", count: 1_024)), limits: defaults)
            try Self.expectQuarantined(
                Self.entryJSON(remotePath: String(repeating: "p", count: 1_025)), as: .remotePathInvalid(.tooLong(bytes: 1_025)), limits: defaults
            )

            // Payload: 32 MiB passes the size check (and is then read: zero bytes are not JSON); one byte more is
            // rejected before any byte is read.
            let mebibytes32 = 32 * 1_024 * 1_024
            #expect(throws: ManifestError.undecodable(.notJSON)) { try ManifestDecoder.decode(Data(count: mebibytes32)) }
            #expect(throws: ManifestError.payloadTooLarge(bytes: 33_554_433, limit: 33_554_432)) {
                try ManifestDecoder.decode(Data(count: mebibytes32 + 1))
            }

            // Entries: 100,001 elements are rejected for the first one past the limit, whatever they hold. (100,000 valid
            // entries decode in the R-MAN-3 fuzz test's limit cases "… at the estimate's limit".)
            #expect(throws: ManifestError.tooManyEntries(count: 100_001, limit: 100_000)) {
                try ManifestDecoder.decode(ManifestCorpus.repeatedElements("{}", count: 100_001))
            }
            #expect(throws: ManifestError.tooManyEntries(count: 100_001, limit: 100_000)) {
                try ManifestDecoder.decode(ManifestCorpus.repeatedElements("0", count: 100_001))
            }
            #expect(defaults == ManifestLimits(
                maxEntries: 100_000, maxPayloadBytes: 33_554_432, maxIdentifierBytes: 256, maxRemotePathBytes: 1_024,
                maxAssetBytes: 4_294_967_296, maxNestingDepth: 64, maxTagBytes: 128, maxTagsPerEntry: 64, maxQuarantineDiagnostics: 256
            ))
        }

        @Test("R-MAN-1: an integral byteSize decodes in every number spelling the prior art's JSONDecoder accepted")
        func integralByteSizeSpellings() throws {
            let entry = { (byteSize: String) in Self.entryJSON(extra: "\"byteSize\":\(byteSize)") }
            let integral: [(String, Int64)] = [
                ("1234", 1_234), ("1234.0", 1_234), ("1.234e3", 1_234), ("1E3", 1_000), ("1e+3", 1_000), ("12340e-1", 1_234),
                ("100E-2", 1), ("0.0", 0), ("-0", 0), ("-0.0e5", 0), ("0e999999999999", 0), ("0.000e-999999999999", 0),
                ("1.50000e1", 15), ("4294967296.000", 4_294_967_296),
            ]
            for (spelling, value) in integral {
                let manifest = try ManifestDecoder.decode(Self.payload([entry(spelling)]))
                #expect(manifest.entries.first?.byteSize == value, "\(spelling): \(manifest.quarantined)")
            }
            let quarantined: [(String, ManifestEntryViolation)] = [
                ("1.5", .malformedField("byteSize")), ("1e-1", .malformedField("byteSize")), ("1.2345e3", .malformedField("byteSize")),
                ("10e-2", .malformedField("byteSize")), ("1e-999999999999", .malformedField("byteSize")),
                ("1e400", .byteSizeOutOfRange(Int64.max)), ("-1e400", .byteSizeOutOfRange(Int64.min)), ("-1.0", .byteSizeOutOfRange(-1)),
                ("4294967297.0", .byteSizeOutOfRange(4_294_967_297)), ("9223372036854775808.0", .byteSizeOutOfRange(Int64.max)),
                ("-9223372036854775808.0", .byteSizeOutOfRange(Int64.min)),
            ]
            for (spelling, violation) in quarantined {
                let manifest = try ManifestDecoder.decode(Self.payload([entry(spelling)]))
                #expect(manifest.count == 0 && manifest.quarantined.map(\.violation) == [violation], "\(spelling)")
            }
        }

        @Test("R-MAN-2: a repeated identifier rejects a remote manifest and keeps only the first occurrence under keepFirst")
        func duplicatePolicies() throws {
            let payload = Self.payload([
                Self.entryJSON(identifier: "a", remotePath: "m/1.png"),
                Self.entryJSON(identifier: "b"),
                Self.entryJSON(identifier: "a", remotePath: "m/2.png"),
                Self.entryJSON(identifier: "a", fileExtension: "bad!"),
            ])
            #expect(throws: ManifestError.duplicateIdentifier("a")) { try ManifestDecoder.decode(payload) }

            let legacy = try ManifestDecoder.decode(payload, options: ManifestDecodingOptions(duplicates: .keepFirst))
            #expect(legacy.entries.map(\.identifier) == ["a", "b"])
            #expect(legacy.entry(for: "a")?.remotePath == "m/1.png")
            #expect(legacy.quarantined == [
                QuarantinedEntry(index: 2, identifier: "a", violation: .malformedField("identifier")),
                QuarantinedEntry(index: 3, identifier: "a", violation: .malformedField("identifier")),
            ])

            // keepFirst keeps the first occurrence that can be kept: a quarantined first occurrence does not make a
            // later valid one a duplicate (the legacy file of the valid entry is then adopted, not re-downloaded). A
            // remote manifest stays strict: the repeated identifier rejects it.
            let quarantinedFirst = Self.payload([
                Self.entryJSON(identifier: "a", fileExtension: "p.ng"),
                Self.entryJSON(identifier: "a", remotePath: "m/valid.png"),
                Self.entryJSON(identifier: "a", fileExtension: "bad!"),
                Self.entryJSON(identifier: "a", remotePath: "m/later.png"),
            ])
            #expect(throws: ManifestError.duplicateIdentifier("a")) { try ManifestDecoder.decode(quarantinedFirst) }
            let kept = try ManifestDecoder.decode(quarantinedFirst, options: ManifestDecodingOptions(duplicates: .keepFirst))
            #expect(kept.entries.map(\.remotePath) == ["m/valid.png"])
            #expect(kept.quarantined == [
                QuarantinedEntry(index: 0, identifier: "a", violation: .fileExtensionInvalid),
                QuarantinedEntry(index: 2, identifier: "a", violation: .malformedField("identifier")),
                QuarantinedEntry(index: 3, identifier: "a", violation: .malformedField("identifier")),
            ])
        }

        @Test("R-MAN-2: keepFirst finds a repeated identifier whatever its escapes and keeps every distinct one")
        func keepFirstComparesDecodedIdentifiers() throws {
            let keepFirst = ManifestDecodingOptions(duplicates: .keepFirst)
            let spelled = Self.payload([
                Self.entryJSON(identifier: "ab", remotePath: "m/1.png"),
                #"{"identifier":"ab","fileExtension":"png","remotePath":"m/2.png","localPathComponents":[]}"#,
                #"{"identifier":"ab","fileExtension":"png","remotePath":"m/3.png","localPathComponents":[]}"#,
                #"{"identifier":"ac","fileExtension":"png","remotePath":"m/4.png","localPathComponents":[]}"#,
                Self.entryJSON(identifier: "ac", remotePath: "m/5.png"),
            ])
            let kept = try ManifestDecoder.decode(spelled, options: keepFirst)
            #expect(kept.entries.map(\.remotePath) == ["m/1.png", "m/4.png"])
            #expect(kept.quarantined.map(\.index) == [1, 2, 4])
            #expect(kept.quarantined.allSatisfy { $0.violation == .malformedField("identifier") })

            // Identifiers of every length up to the limit, every other one escaped, then all of them again with the other
            // spelling: each distinct identifier is kept once and each repeat is quarantined.
            let identifiers = (1...256).map { String(repeating: "x", count: $0) }
            let spell = { (identifier: String, escaped: Bool) in escaped ? "\\u0078" + identifier.dropFirst() : identifier }
            var entries: [String] = []
            for round in 0..<2 {
                for (index, identifier) in identifiers.enumerated() {
                    let escaped = (index + round).isMultiple(of: 2)
                    entries.append("{\"identifier\":\"\(spell(identifier, escaped))\",\"fileExtension\":\"png\",\"remotePath\":\"m/\(round)\",\"localPathComponents\":[]}")
                }
            }
            let all = try ManifestDecoder.decode(Self.payload(entries), options: keepFirst)
            #expect(all.entries.map(\.identifier.rawValue) == identifiers)
            #expect(all.entries.allSatisfy { $0.remotePath == "m/0" })
            #expect(all.quarantined.map(\.index) == Array(256..<512))
            #expect(throws: ManifestError.duplicateIdentifier("x")) { try ManifestDecoder.decode(Self.payload(entries)) }
        }

        @Test("R-MAN-2: a missing, null or mistyped field quarantines its entry under that field's name")
        func malformedFieldsQuarantine() throws {
            let cases: [(String, ManifestEntryViolation)] = [
                (#"{"fileExtension":"png","remotePath":"m/a.png","localPathComponents":[]}"#, .malformedField("identifier")),
                (#"{"identifier":7,"fileExtension":"png","remotePath":"m/a.png","localPathComponents":[]}"#, .malformedField("identifier")),
                (#"{"identifier":"a","remotePath":"m/a.png","localPathComponents":[]}"#, .malformedField("fileExtension")),
                (#"{"identifier":"a","fileExtension":null,"remotePath":"m/a.png","localPathComponents":[]}"#, .malformedField("fileExtension")),
                (#"{"identifier":"a","fileExtension":"png","localPathComponents":[]}"#, .malformedField("remotePath")),
                (#"{"identifier":"a","fileExtension":"png","remotePath":"m/a.png"}"#, .malformedField("localPathComponents")),
                (#"{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":["x",1]}"#, .malformedField("localPathComponents")),
                (#"{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":"x"}"#, .malformedField("localPathComponents")),
                (#"{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":[],"localFileName":5}"#, .malformedField("localFileName")),
                (#"{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":[],"byteSize":"5"}"#, .malformedField("byteSize")),
                (#"{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":[],"byteSize":1.5}"#, .malformedField("byteSize")),
                (#"{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":[],"byteSize":1e-1}"#, .malformedField("byteSize")),
                (#"{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":[],"checksum":false}"#, .malformedField("checksum")),
                (#"{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":[],"tags":"t"}"#, .malformedField("tags")),
                (#"{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":[],"tags":[1]}"#, .malformedField("tags")),
                (#"{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":[],"policy":"archive"}"#, .malformedField("policy")),
                (#"{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":[],"policy":1}"#, .malformedField("policy")),
                (#"{"identifier":"a","identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":[]}"#, .malformedField("identifier")),
                (#"["identifier"]"#, .malformedField("entry")),
                ("null", .malformedField("entry")),
            ]
            for (json, violation) in cases {
                let manifest = try ManifestDecoder.decode(Data("[\(json),\(Self.entryJSON(identifier: "ok"))]".utf8))
                #expect(manifest.quarantined.map(\.violation) == [violation], "\(json)")
                #expect(manifest.quarantined.map(\.index) == [0], "\(json)")
                #expect(manifest.entries.map(\.identifier) == ["ok"], "\(json)")
            }

            // Optional fields given as null are absent, exactly as when they are omitted.
            let nulls = #"{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":[],"localFileName":null,"byteSize":null,"checksum":null,"tags":null,"policy":null}"#
            let entry = try #require(try ManifestDecoder.decode(Data("[\(nulls)]".utf8)).entries.first)
            #expect(entry == ManifestEntry(identifier: "a", fileExtension: "png", remotePath: "m/a.png"))
        }

        @Test("R-MAN-2: remotePath must be relative, without parent segments, scheme, authority, control characters, query or fragment")
        func remotePathRules() throws {
            let accepted = ["media/ab/x.png", "ZTronMedia/images/a.b.c.heic", "a..b/c", "x/.../y", "a/./b", "dir/%41.png", "a/%3F.png",
                "a/%2e%2e.png", "a/..%2"]
            for path in accepted {
                #expect(ManifestDecoder.violations(of: Self.entry(remotePath: path), limits: ManifestLimits()).isEmpty, "\(path)")
            }
            let rejected: [(String, [RemotePathViolation])] = [
                ("", [.empty]),
                ("/abs", [.absolute]),
                ("//cdn.example/x", [.authority, .absolute]),
                ("../x", [.parentSegment]),
                ("a/../../b", [.parentSegment]),
                ("a/..", [.parentSegment]),
                ("a/%2E%2e/b", [.parentSegment]),
                ("https://evil/x", [.scheme, .authority]),
                ("mailto:x", [.scheme]),
                ("c:/x", [.scheme]),
                ("a/b\u{7F}", [.controlCharacter]),
                ("a/\u{85}b", [.controlCharacter]),
                ("a\nb", [.controlCharacter]),
                // A query or fragment is quarantined (orchestrator decision 3, fix round 3). The path ends at one (RFC 3986
                // §4.2), so a parent segment just before one is still one, and one inside it is not.
                ("a/b?c", [.queryOrFragment]),
                ("a/b?x=..", [.queryOrFragment]),
                ("a#", [.queryOrFragment]),
                ("a/..?x", [.parentSegment, .queryOrFragment]),
                ("..#frag", [.parentSegment, .queryOrFragment]),
                ("../a?b", [.parentSegment, .queryOrFragment]),
                ("/a?b", [.absolute, .queryOrFragment]),
                // Percent-encoded slashes and backslashes separate segments too: the origin or the transport may decode
                // or normalise them (ADR draft A-4.7).
                ("a/..%2Fb", [.parentSegment]),
                ("%2e%2e%2fsecret", [.parentSegment]),
                ("a\\..\\b", [.parentSegment]),
                ("a%5C..%5cb", [.parentSegment]),
                ("..\\x", [.parentSegment]),
            ]
            for (path, violations) in rejected {
                #expect(
                    ManifestDecoder.violations(of: Self.entry(remotePath: path), limits: ManifestLimits())
                        == violations.map { .remotePathInvalid($0) },
                    "\(path.debugDescription)"
                )
            }
            // The decoder quarantines such an entry with the first violation, and keeps the rest of the manifest.
            let manifest = try ManifestDecoder.decode(Self.payload([Self.entryJSON(remotePath: "m/a.png?v=2"), Self.entryJSON(identifier: "ok")]))
            #expect(manifest.quarantined.map(\.violation) == [.remotePathInvalid(.queryOrFragment)])
            #expect(manifest.entries.map(\.identifier) == ["ok"])
        }

        @Test("R-MAN-2: violations(of:) reports every rule an entry breaks, in field order")
        func violationsListEveryRule() {
            var entry = Self.entry(remotePath: "/x/../y")
            entry.identifier = AssetID(String(repeating: "\u{1}", count: 3))
            entry.fileExtension = "p.g"
            entry.byteSize = -5
            entry.tags = ["", "ok"]
            entry.localPathComponents = Array(repeating: "d", count: 33)
            let limits = ManifestLimits(maxIdentifierBytes: 2)
            #expect(ManifestDecoder.violations(of: entry, limits: limits) == [
                .identifierTooLong(bytes: 3),
                .identifierControlCharacter,
                .fileExtensionInvalid,
                .remotePathInvalid(.absolute),
                .remotePathInvalid(.parentSegment),
                .malformedField("localPathComponents"),
                .byteSizeOutOfRange(-5),
                .tagInvalid,
            ])
            #expect(ManifestDecoder.violations(of: Self.entry(identifier: ""), limits: limits) == [.identifierEmpty])
            #expect(ManifestDecoder.violations(of: Self.entry(), limits: ManifestLimits()).isEmpty)
        }

        @Test("R-MAN-2: identifiers with C0, DEL or C1 control characters are quarantined and other text is accepted")
        func identifierControlCharacters() throws {
            for scalar in ["\u{0}", "\u{1F}", "\u{7F}", "\u{80}", "\u{9F}"] {
                #expect(
                    ManifestDecoder.violations(of: Self.entry(identifier: AssetID("a\(scalar)b")), limits: ManifestLimits()) == [.identifierControlCharacter],
                    "\(scalar.debugDescription)"
                )
            }
            for text in ["a b", "a\u{A0}b", "日本.語", "a\u{200B}b", "😀"] {
                #expect(ManifestDecoder.violations(of: Self.entry(identifier: AssetID(text)), limits: ManifestLimits()).isEmpty, "\(text)")
            }
        }

        // MARK: - Helpers

        private static func options(_ limits: ManifestLimits) -> ManifestDecodingOptions {
            ManifestDecodingOptions(limits: limits)
        }

        private static func entry(identifier: AssetID = "a.b", remotePath: String = "media/a.png") -> ManifestEntry {
            ManifestEntry(identifier: identifier, fileExtension: "png", remotePath: remotePath)
        }

        /// One entry's JSON text; `extra` is appended verbatim as further members.
        static func entryJSON(
            identifier: String = "a.b",
            fileExtension: String = "png",
            remotePath: String = "m/a.png",
            components: String = "\"localPathComponents\":[\"A\"]",
            extra: String? = nil
        ) -> String {
            var members = [
                "\"identifier\":\(Self.quoted(identifier))",
                "\"fileExtension\":\(Self.quoted(fileExtension))",
                "\"remotePath\":\(Self.quoted(remotePath))",
                components,
            ]
            if let extra {
                members.append(extra)
            }
            return "{" + members.joined(separator: ",") + "}"
        }

        static func payload(_ entries: [String]) -> Data {
            Data(("[" + entries.joined(separator: ",") + "]").utf8)
        }

        private static func quoted(_ text: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: (try? encoder.encode(text)) ?? Data(), as: UTF8.self)
        }

        private static func expectAccepted(_ json: String, limits: ManifestLimits, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let manifest = try ManifestDecoder.decode(Self.payload([json]), options: Self.options(limits))
            #expect(manifest.count == 1, "\(json)", sourceLocation: sourceLocation)
            #expect(manifest.quarantined.isEmpty, "\(json): \(manifest.quarantined)", sourceLocation: sourceLocation)
        }

        private static func expectQuarantined(
            _ json: String,
            as violation: ManifestEntryViolation,
            limits: ManifestLimits,
            sourceLocation: SourceLocation = #_sourceLocation
        ) throws {
            let manifest = try ManifestDecoder.decode(Self.payload([json]), options: Self.options(limits))
            #expect(manifest.count == 0, "\(json)", sourceLocation: sourceLocation)
            #expect(manifest.quarantined.map(\.violation) == [violation], "\(json)", sourceLocation: sourceLocation)
        }
    }
}

extension ModelSuites {
    /// The lexical corners of R-MAN-2/R-MAN-3: every malformed token is a typed `notJSON`, every well-formed but
    /// unusual spelling decodes.
    @Suite("Manifest lexical corners")
    struct ManifestLexicalTests {
        @Test("R-MAN-2: malformed escapes, surrogates, UTF-8, numbers, literals and keys reject the manifest as not JSON")
        func malformedTokensAreNotJSON() {
            let broken = [
                #"[{"x":"\"#,                       // a backslash as the last byte
                #"[{"x":"\uD83D"}]"#,               // a high surrogate alone
                #"[{"x":"\uD83Dx"}]"#,              // a high surrogate followed by text
                #"[{"x":"\uD83D\u0041"}]"#,         // a high surrogate followed by a non-low escape
                #"[{"x":"\uDE00"}]"#,               // a low surrogate alone
                #"[{"x":"\u12"#,                    // a \u escape cut short by the end of the payload
                #"[{"x":"\u12"}]"#,                 // a \u escape with too few hex digits
                #"[{"x":"\u12G4"}]"#,               // a non-hex digit
                #"[{"x":"\q"}]"#,                   // an unknown escape
                #"[{"x":-}]"#,                      // a sign without digits
                #"[{"x":1.}]"#,                     // a fraction without digits
                #"[{"x":1e}]"#,                     // an exponent without digits
                #"[{"x":tru"#,                      // a truncated literal
                #"[{"x":nul}]"#,                    // a misspelled literal
                #"[{1:2}]"#,                        // a key that is not a string
                #"[{"x" 1}]"#,                      // a missing colon
                #"[{"x":[1}]}]"#,                   // a mismatched closer
                #"{"assets":[],"schemaVersion":1"#, // an unterminated envelope
            ]
            for text in broken {
                #expect(throws: ManifestError.undecodable(.notJSON), "\(text)") { try ManifestDecoder.decode(Data(text.utf8)) }
            }
            let invalidUTF8: [[UInt8]] = [[0xC0, 0x80], [0xE0, 0x80, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80], [0xE2, 0x28, 0xA1], [0xC3]]
            for sequence in invalidUTF8 {
                let payload = Data("[{\"x\":\"".utf8) + Data(sequence) + Data("\"}]".utf8)
                #expect(throws: ManifestError.undecodable(.notJSON), "\(sequence)") { try ManifestDecoder.decode(payload) }
            }
        }

        @Test("R-MAN-1: unusual but valid spellings decode: empty containers, exponents, every escape and four-byte scalars")
        func unusualSpellingsDecode() throws {
            let text = #"[{"x":{},"y":[[],{}],"z":[true,false,null,-0,1e+5,2.5E-3],"identifier":"a\b\f\n\r\t\/","fileExtension":"png","remotePath":"m/\u00e9\uD83D\uDE00\u4E2D","localPathComponents":["\uDBFF\uDFFF"],"localFileName":"\"\\"}]"#
            let manifest = try ManifestDecoder.decode(Data(text.utf8))
            #expect(manifest.quarantined.map(\.violation) == [.identifierControlCharacter])
            #expect(manifest.quarantined.first?.identifier == AssetID("a\u{8}\u{C}\n\r\t/"))

            let valid = #"[{"identifier":"a","fileExtension":"png","remotePath":"m/\u00e9\uD83D\uDE00\u4E2D","localPathComponents":["\uDBFF\uDFFF","RAW"],"localFileName":"\"\\"}]"#
                .replacingOccurrences(of: "RAW", with: "\u{10FFFF}")
            let accepted = try ManifestDecoder.decode(Data(valid.utf8))
            let entry = try #require(accepted.entries.first)
            #expect(entry.remotePath == "m/é😀中")
            #expect(entry.localPathComponents == ["\u{10FFFF}", "\u{10FFFF}"])
            #expect(entry.localFileName == "\"\\")
        }

        @Test("R-MAN-2: an integer byteSize beyond Int64 is out of range, and the envelope's schemaVersion must be a single integer")
        func numericEdges() throws {
            let huge = #"[{"identifier":"a","fileExtension":"png","remotePath":"m","localPathComponents":[],"byteSize":99999999999999999999}]"#
            #expect(try ManifestDecoder.decode(Data(huge.utf8)).quarantined.map(\.violation) == [.byteSizeOutOfRange(Int64.max)])
            let negative = #"[{"identifier":"a","fileExtension":"png","remotePath":"m","localPathComponents":[],"byteSize":-99999999999999999999}]"#
            #expect(try ManifestDecoder.decode(Data(negative.utf8)).quarantined.map(\.violation) == [.byteSizeOutOfRange(Int64.min)])
            for envelope in [#"{"schemaVersion":1,"schemaVersion":1,"assets":[]}"#, #"{"schemaVersion":"1","assets":[]}"#,
                #"{"schemaVersion":1.0,"assets":[]}"#, #"{"schemaVersion":1,"assets":[],"assets":[]}"#]
            {
                #expect(throws: ManifestError.undecodable(.unexpectedShape), "\(envelope)") { try ManifestDecoder.decode(Data(envelope.utf8)) }
            }
            #expect(throws: ManifestError.unsupportedSchemaVersion(Int.max)) {
                try ManifestDecoder.decode(Data(#"{"schemaVersion":99999999999999999999,"assets":[]}"#.utf8))
            }
            #expect(throws: ManifestError.unsupportedSchemaVersion(-1)) { try ManifestDecoder.decode(Data(#"{"assets":[1],"schemaVersion":-1}"#.utf8)) }
        }

        @Test("R-MAN-2: rules and identifier hashing see the same bytes in bridged and native strings")
        func bridgedStringsBehaveLikeNativeOnes() throws {
            let bridgedID = NSString(string: "bo7.ri.\u{85}map") as String
            let bridgedPath = NSString(string: String(repeating: "p/", count: 600)) as String
            let entry = ManifestEntry(identifier: AssetID(bridgedID), fileExtension: NSString(string: "PNG") as String, remotePath: bridgedPath)
            #expect(ManifestDecoder.violations(of: entry, limits: ManifestLimits()) == [
                .identifierControlCharacter, .remotePathInvalid(.tooLong(bytes: 1_200)),
            ])
            let native = AssetID(String("bo7.ri.map".unicodeScalars.map(Character.init)))
            let bridged = AssetID(NSString(string: "bo7.ri.map") as String)
            #expect(native == bridged)
            #expect(native.hashValue == bridged.hashValue)
            #expect(Set([native, bridged]).count == 1)
            // A non-ASCII NSString is stored as UTF-16, so its UTF-8 is not contiguous: hashing copies it, alike.
            let utf16Backed = AssetID(NSString(string: "caf\u{E9}.\u{65E5}") as String)
            #expect(utf16Backed == AssetID("caf\u{E9}.\u{65E5}"))
            #expect(utf16Backed.hashValue == AssetID("caf\u{E9}.\u{65E5}").hashValue)
            // Canonically equivalent but byte-different identifiers are different assets.
            #expect(AssetID("caf\u{E9}") != AssetID("cafe\u{301}"))
            #expect(Set([AssetID("caf\u{E9}"), AssetID("cafe\u{301}")]).count == 2)
            // Same length, canonically equal (reordered combining marks), different bytes: still different assets.
            #expect("a\u{301}\u{323}" == "a\u{323}\u{301}")
            #expect(AssetID("a\u{301}\u{323}") != AssetID("a\u{323}\u{301}"))
        }

        @Test("R-MAN-2: a manifest built in memory rejects repeated identifiers, and the diff reports each class")
        func inMemoryManifestsRejectDuplicates() throws {
            let entry = ManifestEntry(identifier: "a", fileExtension: "png", remotePath: "m/a")
            #expect(throws: ManifestError.duplicateIdentifier("a")) {
                try ValidatedManifest(entries: [entry, entry], digest: ContentHash.sha256(of: Data()))
            }
            var moved = entry
            moved.localPathComponents = ["Elsewhere"]
            var changed = entry
            changed.remotePath = "m/b"
            let old = try ValidatedManifest(entries: [entry, ManifestEntry(identifier: "b", fileExtension: "png", remotePath: "m/b")], digest: .init(w0: 1, w1: 0, w2: 0, w3: 0))
            let metadata = ManifestDiff.compute(from: old, to: try ValidatedManifest(entries: [moved], digest: .init(w0: 2, w1: 0, w2: 0, w3: 0)))
            #expect(metadata.change(of: "a") == .metadataChanged && metadata.change(of: "b") == .removed)
            let content = ManifestDiff.compute(from: old, to: try ValidatedManifest(entries: [changed], digest: .init(w0: 3, w1: 0, w2: 0, w3: 0)))
            #expect(content.change(of: "a") == .contentChanged)
        }
    }
}
