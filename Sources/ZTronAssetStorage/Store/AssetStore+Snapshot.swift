import Foundation
import ZTronAssetModel

/// Snapshot publication, the install rate and the acknowledgement protocol (R-STO-13, H-2; ADR-016, ADR-017,
/// ARCHITECTURE §5; WP-B).
///
/// The store keeps `presentTable` (one `SnapshotEntry` per present record) up to date per changed record, so a
/// publication wraps it in O(1). Versions are allocated when a snapshot is built (store-2 S2-13). `.userInitiated`
/// installs at once; `.prefetch` and `.bulk` install at most once per `snapshotInstallInterval`, the trailing
/// install being a deadline that `runDueWork()` serves. Only an acknowledgement that the sink installed the offered
/// snapshot of this store's own epoch counts (store-2 S2-02, `acknowledges`): it starts the deletion grace of the
/// keys the acknowledged snapshot lacks, on the awake clock.
extension AssetStore {
    /// Re-derives the snapshot entry of `id` after its record changed.
    func refreshPresentEntry(_ id: AssetID) {
        guard let layout = self.state.core.layout, let record = self.state.core.records[id] else {
            self.state.core.presentTable[id] = nil
            return
        }
        self.state.core.presentTable[id] = SnapshotTable.entry(for: record, layout: layout)
    }

    /// Publishes the current state at `urgency` (store-wide install-rate rule, ARCHITECTURE §5).
    func publishSnapshotInternal(urgency: AssetPriority) async {
        guard self.state.core.phase == .open || self.state.core.phase == .opening else {
            return
        }
        if urgency != .userInitiated, let opens = self.installWindowOpens(), self.environment.time.monotonicNow() < opens {
            self.state.core.snapshots.installDue = true
            return
        }
        // REENTRANCY: R6 — `installSnapshot` re-validates the acknowledgement after its own await.
        await self.installSnapshot()
    }

    /// When the bulk/prefetch install window opens again, or `nil` when nothing was installed yet.
    func installWindowOpens() -> MonotonicInstant? {
        self.state.core.snapshots.lastInstallAt.map { $0.adding(seconds: max(0, self.configuration.snapshotInstallInterval)) }
    }

    /// Builds a snapshot of the current state (version allocated now) and installs it, then folds the
    /// acknowledgement in (REENTRANCY R6).
    func installSnapshot() async {
        self.state.core.snapshots.version += 1
        let snapshot = AssetSnapshot(
            key: SnapshotKey(epoch: self.state.core.launchEpoch, version: self.state.core.snapshots.version),
            indexGeneration: self.state.core.committedGeneration,
            entries: self.state.core.presentTable
        )
        self.state.core.snapshots.installDue = false
        self.state.core.snapshots.lastInstallAt = self.environment.time.monotonicNow()
        let start = self.environment.time.uptimeNow()
        self.state.core.snapshots.lastInstallStart = start
        // REENTRANCY: R6 — the ack counts only if the sink installed this very snapshot (`acknowledges`), which
        // implies `installed.epoch == launchEpoch`; `acknowledgedVersion = max`; the ack time is read on the awake
        // clock after the await; accesses merge through `recordAccesses`; `retired` is released here, off the main
        // actor; a publication that arrived during the install set `installDue` again and keeps the trailing install
        // due; nothing is recorded once the store closed.
        let ack = await self.installCounted(snapshot)
        guard self.state.core.phase != .closed else {
            return
        }
        if AssetStore.acknowledges(ack, snapshot.key, epoch: self.state.core.launchEpoch) {
            self.state.core.metrics.acknowledgedInstalls += 1
            let acknowledged = max(self.state.core.snapshots.acknowledgedVersion, ack.installed.version)
            self.state.core.snapshots.acknowledgedVersion = acknowledged
            let previousStart = self.state.core.snapshots.lastAcknowledgedInstallStart
            self.state.core.snapshots.lastAcknowledgedInstallStart = previousStart.map { max($0, start) } ?? start
            self.startGrace(acknowledgedVersion: acknowledged, at: self.environment.time.uptimeNow())
        }
        self.recordAccessesInternal(ack.accesses)
    }

    /// Whether `ack` proves that readers now see the snapshot `offered` (store-2 S2-02, ADR draft B-17): the sink
    /// replaced its snapshot with this one (`retired` is set only by an install that swapped) and reports exactly
    /// its key, of this store's epoch. A refused install proves nothing, even when the key the sink keeps carries
    /// this epoch: a replacement store whose epoch repeats on a wiped root would otherwise take the previous
    /// store's snapshot for its own (review probe P2). A refusal in favour of a newer snapshot of this store is
    /// not counted either; that newer install's own acknowledgement is.
    static func acknowledges(_ ack: InstallAck, _ offered: SnapshotKey, epoch: UInt64) -> Bool {
        ack.retired != nil && ack.installed == offered && offered.epoch == epoch && offered.version > 0
    }

    /// Starts the awake-clock grace of every doomed key the acknowledged snapshot lacks (ADR-017).
    private func startGrace(acknowledgedVersion: UInt64, at uptime: MonotonicInstant) {
        let eligibleAt = uptime.adding(seconds: self.configuration.policy.deletionGrace)
        for (key, blobState) in self.state.core.blobTable {
            guard case .doomed(var info) = blobState, info.eligibleAt == nil, info.sinceSnapshotVersion <= acknowledgedVersion else {
                continue
            }
            info.eligibleAt = eligibleAt
            self.state.core.blobTable[key] = .doomed(info)
        }
    }

    /// Merges reader access stamps into `lastAccess` (R-CLN-4 LRU input), clamping future times to now
    /// (store-2 S2-19).
    func recordAccessesInternal(_ stamps: [AssetID: Date]) {
        guard !stamps.isEmpty else {
            return
        }
        let now = self.environment.time.now()
        var changed = false
        for (id, stamp) in stamps {
            guard var record = self.state.core.records[id] else {
                continue
            }
            let clamped = min(stamp, now)
            if clamped > record.lastAccess {
                record.lastAccess = clamped
                self.state.core.records[id] = record
                changed = true
            }
        }
        if changed {
            self.markDirtyInternal(.lazy)
        }
    }
}
