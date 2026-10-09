import Foundation
import ZTronAssetModel

/// Everything `open()` installs from the loaded generation, computed in one bulk unit off the actor (C2): launch
/// reconciliation and the snapshot table of 10,000 present records took about 60 ms in release on the actor (review
/// probe P4), so `open()` now only assigns the results.
struct LaunchState: Sendable {
    /// The loaded generation, or an empty one.
    var content: IndexContent
    /// The index lineage: the loaded one, or one derived from the seed for a new or unreadable index.
    var storeID: StoreIdentifier
    /// The next generation to allocate; the launch commit takes it, and it is the launch epoch (ADR draft B-5).
    var nextGeneration: UInt64
    /// The newest committed generation: the loaded one, except when the load rule chose `index.tmp`. That one is
    /// committed only once the launch commit promoted it to `index.bin` (`promotion`); until then it is
    /// `IndexLoadOutcome.survivingGeneration`, the newest valid generation outside `index.tmp` (ADR draft B-28).
    var committedGeneration: UInt64
    /// The index name that holds `committedGeneration`: the chosen file, or the surviving one when the load chose
    /// `index.tmp`; the load validated it in full, trailer included (close-out cycle 5). `nil` when nothing was loaded.
    var committedFile: IndexFile?
    /// The generation of the loaded `index.tmp`, which the next commit renames to `index.bin` before it writes
    /// `index.tmp` again (ADR draft B-28); `nil` when the load rule chose another file.
    var promotion: UInt64?
    /// Records, blob table and orphans reconciled with the listing.
    var reconciled: LaunchReconciliation.Result
    /// The snapshot entry of every present reconciled record.
    var presentTable: [AssetID: SnapshotEntry]
    /// Degraded until the next `apply` plus adoption (R-STO-4, store-1 S1-11).
    var degraded: Bool
    /// `.ioFailure` when the load could not stat or read an index file (`IndexLoadOutcome.unreadable`): the lifetime
    /// serves the loaded state read-only and writes no index file, so it never commits over a generation it did not
    /// read (ADR draft B-34); a later launch reads again.
    var unavailable: StorageUnavailableReason?

    /// What the launch counts committed, and where, once `open()`'s root barrier ran (ADR draft B-36): `committedGeneration`
    /// in `committedFile` when the barrier ordered the names the load read, and nothing (0) when it failed. A killed
    /// process may have renamed an index file and died before its root sync; until a root sync orders that name, a power
    /// loss can bring the older names back, so the loaded generation is not yet durable. Counting it committed let the
    /// reaper unlink a blob that the generation a power loss brings back still binds or expects, and let the ENOSPC
    /// fallback and step 4 treat `index.bin` as the committed file. The next successful commit (its own root sync) raises
    /// the committed generation. `pendingPromotion` is `promotion` either way.
    func ledger(rootOrdered: Bool) -> IndexCommitLedger {
        IndexCommitLedger(
            committedGeneration: rootOrdered ? self.committedGeneration : 0,
            committedFile: rootOrdered && self.committedGeneration > 0 ? self.committedFile : nil,
            pendingPromotion: self.promotion
        )
    }

    /// Builds the launch state; pure.
    static func build(
        outcome: IndexLoadOutcome,
        onDisk: [BlobKey: Int64],
        blobsRecreated: Bool,
        seed: UInt64,
        now: Date,
        layout: StoreLayout
    ) -> LaunchState {
        let derived = StoreIdentifier.derived(fromSeed: seed)
        let content = outcome.content ?? IndexContent.empty(storeID: derived)
        let nextGeneration = max(outcome.nextGeneration, 1)
        let reconciled = LaunchReconciliation.reconcile(
            content: content,
            onDisk: onDisk,
            blobsRecreated: blobsRecreated,
            openGeneration: nextGeneration,
            now: now
        )
        return LaunchState(
            content: content,
            storeID: content.storeID == .zero ? derived : content.storeID,
            nextGeneration: nextGeneration,
            committedGeneration: outcome.chosen == .temporary ? outcome.survivingGeneration : content.generation,
            committedFile: outcome.chosen == .temporary ? outcome.survivingFile : outcome.chosen,
            promotion: outcome.chosen == .temporary ? content.generation : nil,
            reconciled: reconciled,
            presentTable: SnapshotTable.build(records: reconciled.records, layout: layout),
            // No valid index although blobs exist (or an index existed but failed), or an index file was unreadable.
            degraded: outcome.degraded || (outcome.content == nil && !onDisk.isEmpty) || !outcome.unreadable.isEmpty,
            unavailable: outcome.unreadable.isEmpty ? nil : .ioFailure
        )
    }
}
