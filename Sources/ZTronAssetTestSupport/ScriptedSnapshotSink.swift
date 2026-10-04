import Foundation
import ZTronAssetModel
import ZTronAssetStorage

/// How a `ScriptedSnapshotSink` answers an install (ADR-016).
package enum SnapshotSinkBehaviour: Sendable, Hashable {
    /// Installs a strictly newer key and acknowledges what readers see, exactly like `SnapshotMirror`.
    case acknowledge
    /// Keeps its snapshot and acknowledges that (older) key: a sink that missed the install.
    case ignore
    /// Claims this key whatever was offered: an older or foreign-epoch acknowledgement that must never count
    /// (store-2 S2-02).
    case report(SnapshotKey)
}

/// A scriptable `SnapshotSink` for Storage and Sync tests, which cannot import the facade's `SnapshotMirror`
/// (H-2, I-3; WP-B, WP-C, WP-F).
///
/// It acknowledges, ignores, or reports an older or foreign key on demand, returns the accesses the test recorded
/// (LRU, R-CLN-4) in the next acknowledgement, records every key offered, and lets a test wait for installs without
/// polling. Drives `R-CLN-5: a sink that keeps an older or foreign snapshot never counts as acknowledgement` and the
/// fresh-acknowledgement tests of ADR-017. An actor: no lock, no availability gate.
package actor ScriptedSnapshotSink: SnapshotSink {
    private var behaviour: SnapshotSinkBehaviour
    private var current: AssetSnapshot = .empty
    private var pendingAccesses: [AssetID: Date] = [:]
    private var offered: [SnapshotKey] = []
    private var installWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Creates a sink with an initial behaviour.
    package init(behaviour: SnapshotSinkBehaviour = .acknowledge) {
        self.behaviour = behaviour
    }

    /// Changes how later installs are answered.
    package func setBehaviour(_ behaviour: SnapshotSinkBehaviour) {
        self.behaviour = behaviour
    }

    /// Records a reader's access; the next acknowledgement returns it (latest time per id wins).
    package func recordAccess(_ id: AssetID, at time: Date) {
        self.pendingAccesses[id] = max(time, self.pendingAccesses[id] ?? time)
    }

    /// Every key offered to `install`, in order.
    package var offeredKeys: [SnapshotKey] {
        self.offered
    }

    /// The snapshot readers would see.
    package var installed: AssetSnapshot {
        self.current
    }

    /// Suspends until at least `count` installs were offered.
    package func waitForInstalls(atLeast count: Int) async {
        if self.offered.count >= count {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.installWaiters.append((count, continuation))
        }
    }

    /// Answers according to the behaviour; the replaced snapshot is returned in `retired`, as the mirror does.
    package func install(_ snapshot: AssetSnapshot) -> InstallAck {
        self.offered.append(snapshot.key)
        let accesses = self.pendingAccesses
        self.pendingAccesses = [:]
        var retired: AssetSnapshot?
        let acknowledged: SnapshotKey
        switch self.behaviour {
        case .acknowledge:
            if snapshot.key > self.current.key {
                retired = self.current
                self.current = snapshot
            }
            acknowledged = self.current.key
        case .ignore:
            acknowledged = self.current.key
        case .report(let key):
            acknowledged = key
        }
        self.notifyInstallWaiters()
        return InstallAck(installed: acknowledged, accesses: accesses, retired: retired)
    }

    private func notifyInstallWaiters() {
        let count = self.offered.count
        var ready: [CheckedContinuation<Void, Never>] = []
        self.installWaiters.removeAll { waiter in
            if waiter.count <= count {
                ready.append(waiter.continuation)
                return true
            }
            return false
        }
        for continuation in ready {
            continuation.resume()
        }
    }
}
