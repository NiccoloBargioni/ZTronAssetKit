import Foundation
import ZTronAssetKit

/// R-CAR-6 shim (ADR-033): the prior art's manifest entry, field for field
/// (`ZTronCarouselCore/Sources/ZTronCarouselCore/CDN/CDNAsset.swift`, read-only), so existing call sites and the
/// published wire format keep compiling. It converts to and from `ManifestEntry`.
public struct CDNAsset: Sendable, Hashable, Codable {
    /// The asset identifier.
    public let identifier: String
    /// The file extension without a dot.
    public let fileExtension: String
    /// The path relative to the provider's base URL.
    public let remotePath: String
    /// The prior art's directory hierarchy (metadata only in the new store).
    public let localPathComponents: [String]
    /// The prior art's file name override.
    public let localFileName: String?
    /// The size in bytes, if published.
    public let byteSize: Int?
    /// The checksum, if published (an opaque string in the prior art; the new store needs 64 hex characters).
    public let checksum: String?

    /// The prior art's initialiser, with its defaults.
    public init(
        identifier: String,
        fileExtension: String,
        remotePath: String,
        localPathComponents: [String] = [],
        localFileName: String? = nil,
        byteSize: Int? = nil,
        checksum: String? = nil
    ) {
        self.identifier = identifier
        self.fileExtension = fileExtension
        self.remotePath = remotePath
        self.localPathComponents = localPathComponents
        self.localFileName = localFileName
        self.byteSize = byteSize
        self.checksum = checksum
    }

    /// `localFileName`, else the last dot-separated segment of `identifier` (the prior art's rule).
    public var resolvedFileName: String {
        if let localFileName {
            return localFileName
        }
        return self.identifier.split(separator: ".").last.map(String.init) ?? self.identifier
    }

    /// The entry the new module stores. A checksum that is not 64 hex characters becomes "no checksum": the entry
    /// is then checksum-less (R-MAN-5), exactly as unverifiable as it was in the prior art.
    public var manifestEntry: ManifestEntry {
        ManifestEntry(
            identifier: AssetID(self.identifier),
            fileExtension: self.fileExtension,
            remotePath: self.remotePath,
            localPathComponents: self.localPathComponents,
            localFileName: self.localFileName,
            byteSize: self.byteSize.map(Int64.init),
            checksum: self.checksum.flatMap { ContentHash(hex: $0) }
        )
    }

    /// The shim view of a stored entry.
    public init(entry: ManifestEntry) {
        self.init(
            identifier: entry.identifier.rawValue,
            fileExtension: entry.fileExtension,
            remotePath: entry.remotePath,
            localPathComponents: entry.localPathComponents,
            localFileName: entry.localFileName,
            byteSize: entry.byteSize.map { Int($0) },
            checksum: entry.checksum?.hex
        )
    }
}
