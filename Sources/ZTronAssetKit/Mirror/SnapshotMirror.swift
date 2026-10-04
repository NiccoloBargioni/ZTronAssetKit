import Foundation
import ZTronAssetModel
import ZTronAssetStorage

/// The main-actor copy of the store's snapshot (R-STO-13, H-2, ADR-016; WP-G).
///
/// `lookup` is one dictionary probe on an immutable value: O(1), no I/O, no lock, no task (P-1, P-8). `install`
/// is the store's `SnapshotSink`: it swaps only for a greater `SnapshotKey` (out-of-order and foreign-epoch
/// installs are ignored) and returns the key readers see **now**, which is the acknowledgement I-3 relies on,
/// plus the ids looked up since the previous install (LRU without timers, R-CLN-4). `reset()` is explicit and is
/// never an install of `.empty` (store-2 S2-02).
@MainActor
package final class SnapshotMirror: SnapshotSink {
    private var current: AssetSnapshot
    private var accesses: [AssetID: Date]
    private let time: any TimeSource
    /// `lookup` hits (R-OBS-2).
    package private(set) var hits: Int
    /// `lookup` misses (R-OBS-2).
    package private(set) var misses: Int

    /// Starts empty; callable from the nonisolated `AssetClient.init` (P-12).
    nonisolated package init(time: any TimeSource) {
        self.current = .empty
        self.accesses = [:]
        self.time = time
        self.hits = 0
        self.misses = 0
    }

    /// The installed snapshot's key.
    package var installedKey: SnapshotKey {
        self.current.key
    }

    /// Installs a newer snapshot and acknowledges what readers see; the replaced snapshot travels back in the
    /// acknowledgement so it is released off the main actor (sync-2 S2-12).
    package func install(_ snapshot: AssetSnapshot) -> InstallAck {
        var retired: AssetSnapshot?
        if snapshot.key > self.current.key {
            retired = self.current
            self.current = snapshot
        }
        let drained = self.accesses
        self.accesses = [:]
        return InstallAck(installed: self.current.key, accesses: drained, retired: retired)
    }

    /// Drops the snapshot (shutdown): `lookup` returns `nil` afterwards (R-SYN-15).
    package func reset() {
        self.current = .empty
        self.accesses = [:]
    }

    /// O(1), no I/O; records the access for LRU (bounded by catalog size: one stamp per id, latest wins).
    package func lookup(_ id: AssetID, extensions: [String]) -> AssetLocation? {
        guard let location = self.current.location(for: id, extensions: extensions) else {
            self.misses += 1
            return nil
        }
        self.hits += 1
        self.accesses[id] = self.time.now()
        return location
    }
}
