import Foundation

/// How much the module vouches for an asset's bytes (R-INT-5).
public enum AssetIntegrity: String, Sendable, Hashable, Codable {
    /// The bytes hashed to the manifest's checksum when written (R-INT-2, R-INT-6).
    case verified
    /// A checksum-less entry: existence-only trust (R-MAN-5), flagged in every report.
    case unverified
}

/// A file the module hands out: the answer of `lookup` and `resolve` (R-CAR-1, R-STO-13).
///
/// The URL points into `blobs/` and stays readable for at least `StoragePolicy.deletionGrace` of awake time after
/// the snapshot without it is installed, and for the whole duration of a lease (ADR-017). Consumers that may
/// re-read the path later (for example `UIImage(contentsOfFile:)`, which reloads purged data from the path)
/// load through `Data` or hold a lease (`withAsset`).
public struct AssetLocation: Sendable, Hashable {
    /// The asset.
    public let id: AssetID
    /// `…/v1/blobs/<aa>/<sha256>.<ext>`.
    public let url: URL
    /// The blob's (validated, lowercased) extension.
    public let fileExtension: AssetFileExtension
    /// Bytes on disk.
    public let byteSize: Int64
    /// Verified or not (R-INT-5).
    public let integrity: AssetIntegrity
    /// The manifest announced new content that is not committed yet; the old bytes are served meanwhile (prior-art
    /// parity).
    public let isStale: Bool

    /// Creates a location.
    public init(id: AssetID, url: URL, fileExtension: AssetFileExtension, byteSize: Int64, integrity: AssetIntegrity, isStale: Bool) {
        self.id = id
        self.url = url
        self.fileExtension = fileExtension
        self.byteSize = byteSize
        self.integrity = integrity
        self.isStale = isStale
    }
}

/// The sync stamp, persisted **inside** `index.bin` (R-STO-2, R-SYN-9), never in `UserDefaults` (D-6).
public struct SyncStamp: Sendable, Hashable, Codable {
    /// `"<CFBundleShortVersionString>+<CFBundleVersion>"` at completion.
    public var appVersion: String
    /// Wall-clock completion time (`TimeSource.now()`).
    public var completedAt: Date
    /// The manifest's entity tag at completion.
    public var manifestETag: ETag?
    /// The applied manifest's digest at completion.
    public var manifestDigest: ContentHash

    /// Creates a stamp.
    public init(appVersion: String, completedAt: Date, manifestETag: ETag?, manifestDigest: ContentHash) {
        self.appVersion = appVersion
        self.completedAt = completedAt
        self.manifestETag = manifestETag
        self.manifestDigest = manifestDigest
    }
}
