import Foundation
import ZTronAssetModel

/// The root as `open()`'s first unit left it: created, locked, attributed (ARCHITECTURE §4.5).
struct PreparedRoot: Sendable {
    /// The layout under the resolved base.
    var layout: StoreLayout
    /// The held lock.
    var lock: FileLockToken
    /// `blobs/` did not exist (OS-purge evidence when the index had present records, R-CLN-7).
    var blobsRecreated: Bool
}

/// What the launch listing of `blobs/` found (256 units).
struct BlobListing: Sendable, Hashable {
    /// Every well-named blob in the right fan-out, with its size.
    var onDisk: [BlobKey: Int64]
    /// Everything else under `blobs/`: names that do not parse, files in the wrong fan-out, links, other kinds.
    /// Deleted at launch, never adopted (ARCHITECTURE §3).
    var foreign: [URL]
}

/// The first `open()` unit and the launch listing, as pure functions over the file system (ARCHITECTURE §4.5).
enum OpenUnits {
    /// Resolves the base directory of a location (ADR-001, R-STO-10).
    static func base(of location: StorageLocation, fileSystem: any FileSystem) throws(FileSystemError) -> URL {
        switch location {
        case .applicationSupport:
            return try fileSystem.standardDirectory(.applicationSupport)
        case .caches:
            return try fileSystem.standardDirectory(.caches)
        case .custom(let url):
            return url
        }
    }

    /// Creates `ZTronAssetKit` (barrier-syncing `<base>` after creating it, store-1 S1-02) and `v1`, takes the
    /// lock (R-STO-9), re-applies missing attributes (R-STO-8) and creates `blobs/` and `staging/`. Releases the
    /// lock on every failure after taking it (store-1 S1-08).
    static func prepare(fileSystem: any FileSystem, location: StorageLocation) -> Result<PreparedRoot, StoreError> {
        let layout: StoreLayout
        do throws(FileSystemError) {
            let base = try OpenUnits.base(of: location, fileSystem: fileSystem)
            layout = StoreLayout(base: base)
            let containerExisted = try fileSystem.itemInfo(at: layout.container) != nil
            try fileSystem.createDirectory(at: layout.container)
            if !containerExisted {
                try fileSystem.synchronizeDirectory(at: base, level: .barrier)
            }
            let rootExisted = try fileSystem.itemInfo(at: layout.root) != nil
            try fileSystem.createDirectory(at: layout.root)
            if !rootExisted {
                try fileSystem.synchronizeDirectory(at: layout.container, level: .barrier)
            }
        } catch {
            return .failure(.fileSystem(error))
        }
        let lock: FileLockToken
        switch StoreLock.acquire(fileSystem: fileSystem, layout: layout) {
        case .success(let token):
            lock = token
        case .failure(let error):
            return .failure(error)
        }
        do throws(FileSystemError) {
            if OpenUnits.needsAttributes(try fileSystem.storeAttributes(at: layout.root)) {
                try fileSystem.applyStoreAttributes(.storeDefault, at: layout.root)
            }
            let blobsExisted = try OpenUnits.makeDirectory(layout.blobsDirectory, fileSystem)
            _ = try OpenUnits.makeDirectory(layout.stagingDirectory, fileSystem)
            return .success(PreparedRoot(layout: layout, lock: lock, blobsRecreated: !blobsExisted))
        } catch {
            fileSystem.releaseLock(lock)
            return .failure(.fileSystem(error))
        }
    }

    /// Whether the root lacks backup exclusion or carries another protection class than the store's (a restore can
    /// drop them, store.md §4.8).
    static func needsAttributes(_ attributes: StoreAttributes) -> Bool {
        if !attributes.excludedFromBackup {
            return true
        }
        guard let protection = attributes.protection else {
            return false
        }
        return protection != StoreAttributes.storeDefault.protection
    }

    /// Creates a store directory, applying the store's attributes when it is new; returns whether it existed.
    private static func makeDirectory(_ url: URL, _ fileSystem: any FileSystem) throws(FileSystemError) -> Bool {
        let existed = try fileSystem.itemInfo(at: url) != nil
        try fileSystem.createDirectory(at: url)
        if !existed {
            try fileSystem.applyStoreAttributes(.storeDefault, at: url)
        }
        return existed
    }

    /// Whether `name` is a fan-out directory name: two lowercase hexadecimal digits.
    static func isFanOutName(_ name: String) -> Bool {
        let utf8 = Array(name.utf8)
        return utf8.count == 2
            && utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }

    /// Splits one fan-out listing into well-named blobs and foreign items (R-SEC-2: links are never followed).
    static func classify(fanOut: String, items: [FileItemInfo], layout: StoreLayout, into listing: inout BlobListing) {
        let directory = layout.blobsDirectory.appendingPathComponent(fanOut, isDirectory: true)
        for item in items {
            if item.kind == .file, let key = StoreLayout.parseBlobName(item.name), key.hash.fanOut == fanOut {
                listing.onDisk[key] = item.byteSize
            } else {
                listing.foreign.append(directory.appendingPathComponent(item.name, isDirectory: item.kind == .directory))
            }
        }
    }
}

/// Launch reconciliation of the loaded index against the blob listing (store.md §2.6 7a–7e as amended by
/// ARCHITECTURE §4.5 and ADR-018). Pure, so it is tested without a store.
enum LaunchReconciliation {
    /// The reconciled state.
    struct Result: Sendable, Equatable {
        /// Records after `needsHeal` marking and adoption.
        var records: [AssetID: AssetRecord]
        /// Live keys with their reference counts, doomed keys from DOOMED and from corruption.
        var blobTable: [BlobKey: BlobState]
        /// Sizes of every key in `blobTable`.
        var blobBytes: [BlobKey: Int64]
        /// Listed blobs nobody references or dooms (orphan GC's input; adoptable by a later `apply`).
        var orphans: [BlobKey: Int64]
        /// Present records whose blob was missing or the wrong size.
        var missingBlobs: Int
        /// Fan-outs of adopted blobs: barrier-synced by the next commit (store-1 S1-01).
        var adoptedFanOuts: Set<String>
        /// DOOMED keys dropped because a present record referenced them (store-2 S2-04).
        var doomedRepairs: Int
        /// OS-purge evidence: the stamp is reset and a sync is due (R-CLN-7).
        var osPurgeDetected: Bool
    }

    /// Reconciles `content` with `onDisk`. `openGeneration` is the generation this launch's commit will carry: keys
    /// doomed now are dropped by it.
    static func reconcile(content: IndexContent, onDisk: [BlobKey: Int64], blobsRecreated: Bool, openGeneration: UInt64, now: Date) -> Result {
        var records = content.records
        var table: [BlobKey: BlobState] = [:]
        var bytes: [BlobKey: Int64] = [:]
        var missing = 0
        var corrupt: Set<BlobKey> = []
        let hadPresent = records.values.contains { $0.referencedBlob != nil }
        let ids = records.keys.sorted()
        // 7b: a present record keeps its blob only if it is on disk with the recorded size.
        for id in ids {
            guard var record = records[id], case .present(let key, let size, _) = record.residency else {
                continue
            }
            if onDisk[key] == size {
                table[key] = .live(references: LaunchReconciliation.references(table[key]) + 1)
                bytes[key] = size
            } else {
                if onDisk[key] != nil {
                    corrupt.insert(key)
                }
                record.residency = .needsHeal(lastBlob: key)
                records[id] = record
                missing += 1
            }
        }
        // 7a: DOOMED minus what is referenced (repaired and counted); keys no longer on disk are done.
        var repairs = 0
        for key in content.doomed.keys.sorted() {
            if case .live? = table[key] {
                repairs += 1
                continue
            }
            guard let size = onDisk[key], !corrupt.contains(key), let reason = content.doomed[key] else {
                continue
            }
            table[key] = .doomed(DoomInfo(reason: reason, sinceSnapshotVersion: 1, droppedInGeneration: content.generation))
            bytes[key] = size
        }
        // A wrong-sized file under a blob name is quarantined: never adopted, replaced by a verified publish.
        for key in corrupt.sorted() where table[key] == nil {
            table[key] = .doomed(DoomInfo(reason: .corrupt, sinceSnapshotVersion: 1, droppedInGeneration: openGeneration))
            bytes[key] = onDisk[key]
        }
        // 7c: adoption by hash (P-5 window, launch-window dedupe), only into records that accept it (ADR-018).
        var fanOuts: Set<String> = []
        for id in ids {
            guard var record = records[id], record.acceptsAdoption, let key = record.expectedKey, let size = onDisk[key] else {
                continue
            }
            if let expected = record.entry.byteSize, expected != size {
                continue
            }
            switch table[key] {
            case .live(let references)?:
                table[key] = .live(references: references + 1)
            case .doomed(let info)? where info.reason == .unreferenced:
                table[key] = .live(references: 1)
            case nil:
                table[key] = .live(references: 1)
                bytes[key] = size
            default:
                continue
            }
            let previous = record.referencedBlob
            record.residency = .present(blob: key, byteSize: size, integrity: record.entry.checksum == key.hash ? .verified : .unverified)
            record.storedAt = record.storedAt ?? now
            records[id] = record
            fanOuts.insert(key.hash.fanOut)
            if let previous, previous != key {
                let remaining = LaunchReconciliation.references(table[previous]) - 1
                table[previous] =
                    remaining > 0
                    ? .live(references: remaining)
                    : .doomed(DoomInfo(reason: .unreferenced, sinceSnapshotVersion: 1, droppedInGeneration: openGeneration))
            }
        }
        let orphans = onDisk.filter { table[$0.key] == nil }
        let osPurge = missing > 0 || (hadPresent && onDisk.isEmpty) || (blobsRecreated && hadPresent)
        return Result(
            records: records,
            blobTable: table,
            blobBytes: bytes,
            orphans: orphans,
            missingBlobs: missing,
            adoptedFanOuts: fanOuts,
            doomedRepairs: repairs,
            osPurgeDetected: osPurge
        )
    }

    private static func references(_ state: BlobState?) -> Int {
        if case .live(let references)? = state {
            return references
        }
        return 0
    }
}
