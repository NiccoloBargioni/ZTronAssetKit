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
package actor ScriptedSnapshotSink: SnapshotSink, CensusWaiting {
    private var behaviour: SnapshotSinkBehaviour
    private var current: AssetSnapshot = .empty
    private var pendingAccesses: [AssetID: Date] = [:]
    private var offered: [SnapshotKey] = []
    /// Waits for a number of offered installs (`CensusWaiting`).
    var censusWaiters = CensusWaiters()

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

    /// Suspends until at least `count` installs were offered, or until the calling task is cancelled (a test past its
    /// time limit), when it returns with fewer offered so the caller's following expectations fail instead of the run
    /// hanging (L2 follow-up).
    package func waitForInstalls(atLeast count: Int) async {
        // REENTRANCY: TS2 — nothing: a terminal wait (l2fu-1); no state is read afterwards (the caller re-reads
        // `offeredKeys`).
        _ = await self.awaitCensus(target: count, met: { self.offered.count >= $0 }, registered: nil)
    }

    /// Suspends until at least `count` installs were offered; throws `CancellationError` when the calling task is
    /// cancelled first, so a test past its time limit ends at once.
    package func requireInstalls(atLeast count: Int) async throws(CancellationError) {
        // REENTRANCY: TS2 — nothing: a terminal wait (l2fu-1); no state is read afterwards.
        guard await self.awaitCensus(target: count, met: { self.offered.count >= $0 }, registered: nil) else {
            throw CancellationError()
        }
    }

    /// Test seam for the wait itself: `true` once at least `count` installs were offered, `false` when the calling
    /// task was cancelled first; `registered` runs on the actor once the wait is registered.
    package func waitForInstalls(atLeast count: Int, registered: @escaping @Sendable () -> Void) async -> Bool {
        // REENTRANCY: TS2 — nothing: a terminal wait (l2fu-1); no state is read afterwards.
        await self.awaitCensus(target: count, met: { self.offered.count >= $0 }, registered: registered)
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
        self.censusWaiters.resume { $0 <= count }
    }
}
