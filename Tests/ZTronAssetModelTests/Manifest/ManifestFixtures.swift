import Foundation
import Testing
import ZTronAssetModel

/// Read-only access to `Tests/Fixtures/manifests` (ADR-008) and its machine-readable `expectations.json`.
///
/// Located through `#filePath`, so nothing is a SwiftPM resource and no working directory is assumed. Nothing here
/// writes anywhere.
enum ManifestFixtures {
    /// `Tests/Fixtures`, three levels above this file's directory.
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    /// The bytes of a fixture, by its path relative to `Tests/Fixtures`.
    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: self.root.appendingPathComponent(relativePath))
    }

    /// Decodes a fixture with the default remote-manifest options.
    static func decode(_ relativePath: String, options: ManifestDecodingOptions = ManifestDecodingOptions()) throws
        -> ValidatedManifest
    {
        let bytes = try self.data(relativePath)
        return try ManifestDecoder.decode(bytes, options: options)
    }

    /// `expectations.json`, decoded.
    static func expectations() throws -> Expectations {
        try JSONDecoder().decode(Expectations.self, from: self.data("manifests/expectations.json"))
    }

    /// The fixture tiers.
    static let tiers = ["aws", "apple"]
}

/// The shape of `Tests/Fixtures/manifests/expectations.json` (README §6).
struct Expectations: Decodable {
    /// One file of a series.
    struct SeriesFile: Decodable {
        var file: String
        var assetCount: Int
        var identifiers: [String]
    }

    /// The envelope file of a tier.
    struct Envelope: Decodable {
        var file: String
        var schemaVersion: Int
        var assetCount: Int
        var identifiers: [String]
    }

    /// One transition and its five classes, identifiers sorted by UTF-8 bytes.
    struct Transition: Decodable {
        var fromFile: String
        var toFile: String
        var added: [String]
        var removed: [String]
        var contentChanged: [String]
        var metadataChanged: [String]
        var unchanged: [String]
    }

    /// One tier.
    struct Tier: Decodable {
        var series: [String: SeriesFile]
        var envelope: Envelope
        var transitions: [String: Transition]
        var extraTransitions: [String: Transition]
    }

    /// One negative fixture.
    struct Invalid: Decodable {
        var wireShape: String
        var outcome: String
        var reasonClass: String?
        var quarantinedIndices: [Int]?
        var quarantinedIdentifiers: [String]?
        var survivingIdentifiers: [String]?
        var duplicateIdentifier: String?
        var schemaVersion: Int?
    }

    var classes: [String]
    var tiers: [String: Tier]
    var invalid: [String: Invalid]
}

extension Array where Element == AssetID {
    /// Raw identifiers sorted by UTF-8 bytes, the order `expectations.json` uses.
    var sortedRaw: [String] {
        self.sorted().map(\.rawValue)
    }
}
