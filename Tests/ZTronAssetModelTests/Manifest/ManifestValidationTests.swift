import Foundation
import Testing
import ZTronAssetModel

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
        for broken in ["", "[", "[{}", "[1,]", "[] x", "{\"assets\":[],}", "nul", "[\"\u{01}\"]", "[01]"] {
            #expect(throws: ManifestError.undecodable(.notJSON), "\(broken.debugDescription)") {
                try ManifestDecoder.decode(Data(broken.utf8))
            }
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

        // Path components: at most 32 (the index's per-record limit, store design §2.3).
        let components = { (count: Int) in "\"localPathComponents\":[" + Array(repeating: "\"d\"", count: count).joined(separator: ",") + "]" }
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
            (#"{"identifier":"a","fileExtension":"png","remotePath":"m/a.png","localPathComponents":[],"byteSize":1e3}"#, .malformedField("byteSize")),
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

    @Test("R-MAN-2: remotePath must be relative, without parent segments, scheme, authority or control characters")
    func remotePathRules() throws {
        let accepted = ["media/ab/x.png", "ZTronMedia/images/a.b.c.heic", "a..b/c", "x/.../y", "a/./b", "dir/%41.png", "a/b?c"]
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
        ]
        for (path, violations) in rejected {
            #expect(
                ManifestDecoder.violations(of: Self.entry(remotePath: path), limits: ManifestLimits())
                    == violations.map { .remotePathInvalid($0) },
                "\(path.debugDescription)"
            )
        }
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
