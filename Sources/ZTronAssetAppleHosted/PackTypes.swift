import ZTronAssetModel

/// A validated asset-pack identifier: 1…64 bytes of `[A-Za-z0-9._-]`, never `.` or `..` (transport-1 TR1-12).
///
/// These seam types mention no BackgroundAssets type, so they compile and are tested on every host
/// (R-APL-1: all logic runs against `FakePackBackend`).
public struct PackID: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The identifier.
    public let rawValue: String

    /// Validates `rawValue`.
    public init?(rawValue: String) {
        let utf8 = Array(rawValue.utf8)
        guard (1...64).contains(utf8.count), rawValue != ".", rawValue != ".." else {
            return nil
        }
        for byte in utf8 {
            let allowed =
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
            guard allowed else {
                return nil
            }
        }
        self.rawValue = rawValue
    }

    /// Orders by identifier (deterministic release order).
    public static func < (lhs: PackID, rhs: PackID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The identifier.
    public var description: String {
        self.rawValue
    }
}

/// A file inside a pack: the Apple tier's `remotePath` is `"<packID>/<path inside pack>"` (SPEC §2.3).
///
/// The path is untrusted manifest text: every component must be non-empty, not `.` or `..`, and free of control
/// characters; the whole path is relative and at most 1,024 bytes (R-SEC-2 defence in depth; it is only ever
/// passed to BackgroundAssets, never joined to a file URL).
public struct PackLocation: Hashable, Sendable, CustomStringConvertible {
    /// The pack.
    public let pack: PackID
    /// The path inside the pack.
    public let path: String

    /// Parses `"<packID>/<path>"`; `nil` for anything else.
    public init?(remotePath: String) {
        guard remotePath.utf8.count <= 1_024, let slash = remotePath.firstIndex(of: "/") else {
            return nil
        }
        guard let pack = PackID(rawValue: String(remotePath[..<slash])) else {
            return nil
        }
        let path = String(remotePath[remotePath.index(after: slash)...])
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            return nil
        }
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                return nil
            }
            guard !component.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                return nil
            }
        }
        self.pack = pack
        self.path = path
    }

    /// `"<packID>/<path>"`.
    public var description: String {
        "\(self.pack.rawValue)/\(self.path)"
    }
}

/// Pack download progress as a value (D-12: the SDK's payload is a live `Foundation.Progress`, converted at the
/// backend boundary).
public struct PackProgress: Sendable, Hashable {
    /// Completed units.
    public var completed: Int64
    /// Total units.
    public var total: Int64

    /// Creates progress.
    public init(completed: Int64, total: Int64) {
        self.completed = completed
        self.total = total
    }
}

/// Pack failures, mapped by `PackErrorMapping` into `TransferError` (never integrity for undocumented errors,
/// transport.md §11.1).
public enum PackError: Error, Sendable, Hashable {
    /// The pack does not exist.
    case packNotFound
    /// The file is not in the pack.
    case fileNotFound
    /// More bytes than the cap.
    case tooLarge(limit: Int64)
    /// A read failed.
    case readFailed
    /// An undocumented system error (APPLE-API-VERIFICATION §1.8, UNVERIFIED types).
    case system(domain: String, code: Int)
}

/// The outcome of `checkForUpdates()` (R-APL-2d): returns after scheduling, never waits for downloads.
public struct PackUpdateCheck: Sendable, Hashable {
    /// Packs the system is updating.
    public var updating: Set<PackID>
    /// Packs the system removed.
    public var removed: Set<PackID>

    /// Creates a result.
    public init(updating: Set<PackID>, removed: Set<PackID>) {
        self.updating = updating
        self.removed = removed
    }
}

/// Reads one pack file in bounded chunks. Opens lazily on the first read, so every blocking call happens inside
/// the store's bulk executor (via `StagingSink.writeStaged`).
public protocol PackFileReader: ChunkSource {}

/// The seam over `AssetPackManager` (R-APL-1). Only `LiveAssetPackBackend.swift` touches BackgroundAssets; tests
/// use `FakePackBackend` (Tests/ZTronAssetAppleHostedTests, ADR-040).
public protocol PackBackend: Sendable {
    /// A lazy reader of `path` in `pack` (non-blocking to create).
    func reader(for path: String, in pack: PackID) -> any PackFileReader
    /// Makes the pack local; progress arrives as values.
    func ensureAvailable(_ pack: PackID, progress: AsyncStream<PackProgress>.Continuation?) async throws(PackError)
    /// Best-effort update check.
    func checkForUpdates() async throws(PackError) -> PackUpdateCheck
    /// Removes a whole pack (R-CLN-10).
    func remove(_ pack: PackID) async throws(PackError)
    /// Bytes the OS holds for an installed pack, when known (StorageReport, transport-2 T2-13).
    func installedBytes(of pack: PackID) async -> Int64?
}

/// The pure release decision of H-7 / R-CLN-10 (ADR-027).
public enum PackReleasePlanner {
    /// The media packs to release now, sorted: never the catalog pack, never with `.keepPacks`, never twice, and
    /// only when **every** catalog entry mapped to the pack is adopted (durably committed) or excluded by the
    /// keep-scope, i.e. the client's retention scope (`AssetStore.adoptionReport()`, ADR-027).
    public static func packsToRelease(
        catalogEntries: [PackLocation],
        adopted: Set<PackLocation>,
        excluded: Set<PackLocation>,
        catalogPack: PackID,
        retention: PackRetention,
        alreadyReleased: Set<PackID>
    ) -> [PackID] {
        guard retention == .releaseAfterAdoption else {
            return []
        }
        var complete: [PackID: Bool] = [:]
        for entry in catalogEntries where entry.pack != catalogPack && !alreadyReleased.contains(entry.pack) {
            let settled = adopted.contains(entry) || excluded.contains(entry)
            complete[entry.pack] = (complete[entry.pack] ?? true) && settled
        }
        return complete.filter { $0.value }.keys.sorted()
    }
}
