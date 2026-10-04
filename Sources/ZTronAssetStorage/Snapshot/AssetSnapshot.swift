import Foundation
import ZTronAssetModel

/// Orders snapshots across store instances (ADR-016, store-2 S2-02).
///
/// `epoch` is the store's launch epoch (the generation allocated at `open()`, persisted and strictly increasing
/// across instances), `version` counts publications within an instance. A mirror installs a snapshot only if its
/// key is greater, and the store counts an acknowledgement only for its own epoch, so a reopened store can never
/// mistake an ignored install for one that happened.
package struct SnapshotKey: Hashable, Comparable, Sendable {
    /// The publishing store instance's launch epoch.
    package let epoch: UInt64
    /// The publication counter within that instance, allocated synchronously **when the snapshot is built**
    /// (store-2 S2-13).
    package let version: UInt64

    /// Creates a key.
    package init(epoch: UInt64, version: UInt64) {
        self.epoch = epoch
        self.version = version
    }

    /// The key of the empty snapshot every mirror starts with.
    package static let zero = SnapshotKey(epoch: 0, version: 0)

    /// Orders by epoch, then version.
    package static func < (lhs: SnapshotKey, rhs: SnapshotKey) -> Bool {
        (lhs.epoch, lhs.version) < (rhs.epoch, rhs.version)
    }
}

/// One present asset in a snapshot: its precomputed location, so `lookup` builds no URL (P-1).
package struct SnapshotEntry: Hashable, Sendable {
    /// Where the bytes are; never a staging path (I-4 by construction).
    package let location: AssetLocation
    /// `policy == .essential`.
    package let essential: Bool

    /// Creates an entry.
    package init(location: AssetLocation, essential: Bool) {
        self.location = location
        self.essential = essential
    }
}

/// The immutable value readers use for synchronous lookups (R-STO-13, H-2).
///
/// Only *present* assets (current or stale content) appear. Publishing a snapshot is a single main-actor
/// assignment in `SnapshotMirror`, so readers never see torn state. Only sinks that acknowledge through
/// `SnapshotSink` may hand out URLs derived from a snapshot; the engine resolves through
/// `AssetStore.location(for:extensions:recordingAccess:)` instead (store-2 S2-12, ADR-016).
package struct AssetSnapshot: Sendable {
    /// Ordering key (ADR-016).
    package let key: SnapshotKey
    /// The index generation the snapshot reflects (diagnostics, events).
    package let indexGeneration: UInt64
    /// Present assets.
    package let entries: [AssetID: SnapshotEntry]

    /// Creates a snapshot.
    package init(key: SnapshotKey, indexGeneration: UInt64, entries: [AssetID: SnapshotEntry]) {
        self.key = key
        self.indexGeneration = indexGeneration
        self.entries = entries
    }

    /// The snapshot of an empty or not-yet-opened store.
    package static let empty = AssetSnapshot(key: .zero, indexGeneration: 0, entries: [:])

    /// O(1): one dictionary probe, then a case-insensitive match against `extensions` (any extension when empty).
    /// No I/O, no allocation on a miss.
    package func location(for id: AssetID, extensions: [String]) -> AssetLocation? {
        guard let entry = self.entries[id] else {
            return nil
        }
        guard !extensions.isEmpty else {
            return entry.location
        }
        let wanted = entry.location.fileExtension
        for candidate in extensions where AssetFileExtension(candidate) == wanted {
            return entry.location
        }
        return nil
    }
}

/// The store's acknowledgement protocol with the main-actor mirror (H-2, I-3, ADR-016).
///
/// `install` returns only after the mirror swapped its snapshot (or decided to keep a newer one). The store
/// treats the returned `installed` key as the acknowledgement: a blob becomes deletable only once an acknowledged
/// snapshot **of its own epoch** without it exists (store-2 S2-02). The returned access stamps feed LRU (R-CLN-4)
/// without timers or polling (P-14).
package protocol SnapshotSink: Sendable {
    /// Installs `snapshot` if its key is newer than the current one and acknowledges what is installed now.
    func install(_ snapshot: AssetSnapshot) async -> InstallAck
}

/// What a sink reports back from `install`.
package struct InstallAck: Sendable {
    /// The key of the snapshot the readers see **after** the call (not necessarily the one passed in).
    package let installed: SnapshotKey
    /// Ids looked up since the previous install, with the latest wall-clock time of each (bounded by catalog size).
    package let accesses: [AssetID: Date]
    /// The snapshot the install replaced, handed back so its (possibly last) reference is released by the store,
    /// off the main actor: releasing a 100,000-entry dictionary on main costs milliseconds (sync-2 S2-12, P-8).
    package let retired: AssetSnapshot?

    /// Creates an acknowledgement.
    package init(installed: SnapshotKey, accesses: [AssetID: Date], retired: AssetSnapshot? = nil) {
        self.installed = installed
        self.accesses = accesses
        self.retired = retired
    }
}
