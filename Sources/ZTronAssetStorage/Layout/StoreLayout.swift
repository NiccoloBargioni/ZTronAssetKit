import Foundation
import ZTronAssetModel

/// A blob's identity, which is also its file name: `<64 lowercase hex>.<ext>` (I-1, R-SEC-2).
package struct BlobKey: Hashable, Comparable, Sendable {
    /// SHA-256 of the bytes (our digest, never the manifest's claim, R-INT-6).
    package let hash: ContentHash
    /// The validated, lowercased extension.
    package let ext: AssetFileExtension

    /// Creates a key.
    package init(hash: ContentHash, ext: AssetFileExtension) {
        self.hash = hash
        self.ext = ext
    }

    /// `<hex>.<ext>`.
    package var fileName: String {
        "\(self.hash.hex).\(self.ext.rawValue)"
    }

    /// Orders by hash, then extension (deterministic op order, store-2 S2-08).
    package static func < (lhs: BlobKey, rhs: BlobKey) -> Bool {
        (lhs.hash, lhs.ext) < (rhs.hash, rhs.ext)
    }
}

/// The three names an index generation can have on disk (ADR-012, store.md §2.4.1).
package enum IndexFile: String, Sendable, Hashable, CaseIterable {
    /// The current generation.
    case current = "index.bin"
    /// The previous generation: a fallback against single-file corruption.
    case previous = "index.prev"
    /// The generation being committed; garbage if its trailer fails.
    case temporary = "index.tmp"
}

/// Builds **every** URL the store uses (ARCHITECTURE §3). Nothing else in the module concatenates path strings, and
/// no manifest-supplied text ever becomes a path component (R-SEC-2): blob names come from our own digest and a
/// re-validated extension, staging names from `StagingFileName` (`[0-9a-z-]` plus fixed suffixes).
package struct StoreLayout: Sendable, Hashable {
    /// `<base>/ZTronAssetKit/v1`.
    package let root: URL

    /// The layout under `base` (Application Support, Caches or a custom directory, ADR-001).
    package init(base: URL) {
        self.root = base
            .appendingPathComponent(StoreLayout.containerName, isDirectory: true)
            .appendingPathComponent(StoreLayout.versionName, isDirectory: true)
    }

    /// `ZTronAssetKit`: the directory the module creates inside `base`.
    package static let containerName = "ZTronAssetKit"
    /// `v1`: the layout version.
    package static let versionName = "v1"
    /// The `schemaVersion` the index codec writes into the header (store.md §2.3, ADR-012), exported so
    /// `DiagnosticReport.indexSchemaVersion` reports it without reading a file (R-OBS-3). A newer schema on disk
    /// makes the load degraded (§4.2); every new schema adds golden fixtures (R-STO-12).
    package static let indexSchemaVersion: UInt16 = 1

    /// `<base>/ZTronAssetKit`, whose entry in `base` must be synced at creation (store-1 S1-02).
    package var container: URL {
        self.root.deletingLastPathComponent()
    }

    /// `store.lock`: the advisory lock, never deleted by the module.
    package var lockURL: URL {
        self.root.appendingPathComponent("store.lock", isDirectory: false)
    }

    /// One of the index files.
    package func indexURL(_ file: IndexFile) -> URL {
        self.root.appendingPathComponent(file.rawValue, isDirectory: false)
    }

    /// `blobs/`.
    package var blobsDirectory: URL {
        self.root.appendingPathComponent("blobs", isDirectory: true)
    }

    /// `staging/`.
    package var stagingDirectory: URL {
        self.root.appendingPathComponent("staging", isDirectory: true)
    }

    /// `blobs/<aa>/`: the fan-out directory of a hash.
    package func fanOutDirectory(for hash: ContentHash) -> URL {
        self.blobsDirectory.appendingPathComponent(hash.fanOut, isDirectory: true)
    }

    /// `blobs/<aa>/<hex>.<ext>`.
    package func blobURL(_ key: BlobKey) -> URL {
        self.fanOutDirectory(for: key.hash).appendingPathComponent(key.fileName, isDirectory: false)
    }

    /// `staging/<TransferID>.<epoch>-<sequence>.<kind>` (ADR-013).
    package func stagingURL(_ name: StagingFileName) -> URL {
        self.stagingDirectory.appendingPathComponent(name.rawValue, isDirectory: false)
    }

    /// Parses a blob directory entry: exactly `<64 lowercase hex>.<[a-z0-9]{1,8}>`, else `nil` (foreign: deleted by
    /// launch reconciliation, never adopted).
    package static func parseBlobName(_ fileName: String) -> BlobKey? {
        let parts = fileName.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].utf8.count == 64 else {
            return nil
        }
        let lowercaseHex = parts[0].utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
        guard lowercaseHex, let hash = ContentHash(hex: parts[0]), let ext = AssetFileExtension(String(parts[1])),
            ext.rawValue == String(parts[1])
        else {
            return nil
        }
        return BlobKey(hash: hash, ext: ext)
    }
}
