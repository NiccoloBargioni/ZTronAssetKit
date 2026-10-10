import Foundation
import ZTronAssetModel

/// How soon a mutation must reach disk (store.md §4.6, P-5). WP-B.
enum DirtyUrgency: Sendable, Hashable {
    /// Access times and DOOMED pruning: rides along with the next commit, `flush()` or `close()`.
    case lazy
    /// Publications, quarantines, pins: one commit within `commitMinimumInterval`, reported through
    /// `nextDeadline()`.
    case soon
}

/// The primitives WP-B provides for WP-C's extension files (ADR-046). Contract signatures, implemented by WP-B in
/// Stage 2 level L2 and used by WP-C in level L3, so WP-C never re-implements reference counting, commit
/// scheduling, snapshot publication, hashing or blob placement, and edits a WP-B file only under an orchestrator ruling
/// (at L3: this file, ruling R2; `AssetStore+Apply.swift` and `ApplyPlan.swift`, rulings R1, R3 and R6; ADR-052).
/// `doomOrphans(_:)` was added at the L3 close-out (CCR-1, orchestrator ruling R2).
extension AssetStore {
    /// Throws unless the store is open: `.notOpen` while `created` or `opening`, `.closed` once `close()` began
    /// (store-1 S1-09, store-2 S2-07). Every mutating entry point of both packages calls it first and again after
    /// each await (ARCHITECTURE §10).
    func ensureOpen() throws(StoreError) {
        try self.ensureOpenInternal()
    }

    /// Moves a record to a residency **without** a blob (`absent`, `needsHeal`, `quarantined`, `failed`), releasing
    /// its reference to its previous blob; a blob left without references is doomed with `reason` (ADR-018:
    /// `unreferenced` for eviction, `purged` for purge, `corrupt` for quarantine). Synchronous, so no window; marks
    /// the state dirty (`.soon`). A transition **to** `present` goes through
    /// `adoptVerifiedFile(at:digest:byteCount:for:)`.
    func setResidency(_ residency: Residency, of id: AssetID, dooming reason: DoomReason) {
        self.setResidencyInternal(residency, of: id, dooming: reason)
    }

    /// Records that the in-memory state changed: `.soon` schedules one coalesced commit (P-5), `.lazy` rides along.
    func markDirty(_ urgency: DirtyUrgency) {
        self.markDirtyInternal(urgency)
    }

    /// Returns once a generation holding every mutation made before the call is committed at `durability`
    /// (store.md §4.6 `requireCommitted`; REENTRANCY R5). Used by purge, pins, migration phases and deletion paths.
    func requireCommitted(_ durability: CommitDurability) async throws(StoreError) {
        // REENTRANCY: R5, R17 — the loop inside re-reads coverage, the window and the phase after each await.
        try await self.requireCommittedInternal(durability)
    }

    /// Builds the snapshot of current state (version allocated synchronously, store-2 S2-13) and installs it now
    /// (`.userInitiated`) or within `snapshotInstallInterval` (`.prefetch`, `.bulk`; the trailing install is a
    /// `nextDeadline()`), merging the acknowledgement as REENTRANCY R6 says (ADR-016).
    func publishSnapshot(urgency: AssetPriority) async {
        // REENTRANCY: R6, R17 — the acknowledgement is validated and merged inside.
        await self.publishSnapshotInternal(urgency: urgency)
    }

    /// Deletes up to `maxKeys` blobs that are deletable **now** (ARCHITECTURE §4.4, leases read from
    /// `state.cleanup`), in sorted order and units of `deletionBatchSize` (P-13); used by `runDueWork()` and by
    /// WP-C's `purge` after its grace wait. Failed unlinks stay doomed with backoff.
    func reapDeletable(maxKeys: Int) async -> CleanupResult {
        // REENTRANCY: R7, R9 — every key is re-checked before its unit and the phase after it.
        await self.reap(maxKeys: maxKeys)
    }

    /// Streaming SHA-256 of a file in `hashChunkBytes` units on the bulk executor, cancellation-aware between units
    /// (R-INT-1, P-6, store.md §5.1). Used by `publish`, deep verification (R-INT-4) and legacy migration.
    func hashFile(at url: URL) async throws(StoreError) -> (digest: ContentHash, byteCount: Int64) {
        // REENTRANCY: R2, R16 — the caller re-validates its records after the hash.
        try await self.hashFileInternal(at: url)
    }

    /// The tail of publication (ARCHITECTURE §4.3 steps 7–10) for a file the caller already hashed: gains the
    /// reference (`acquireReference`: dedupe onto a live key, rescue an `unreferenced` doom, await an in-flight
    /// publication or deletion of the key), places the file with a barrier and an exclusive rename (or removes the
    /// duplicate), and makes every id in `ids` whose record still expects `digest` present. Used by legacy migration
    /// (ADR-029); `publish` itself ends with it. It marks the state dirty but publishes **no** snapshot: every caller
    /// then calls `publishSnapshot(urgency:)` at its own urgency (`publish` at its argument, `migrateLegacy` at
    /// `.bulk`, `adoptLegacyNow` at `.userInitiated`), so the install rate is decided in exactly one place.
    func adoptVerifiedFile(
        at url: URL,
        digest: ContentHash,
        byteCount: Int64,
        for ids: [AssetID]
    ) async throws(StoreError) -> [AssetID: AssetLocation] {
        // REENTRANCY: R3, R4, R11, R18 — every record is re-validated after the placement unit.
        try await self.adoptVerifiedFileInternal(at: url, digest: digest, byteCount: byteCount, for: ids)
    }

    /// Dooms blobs found on disk that the store does not know, instead of unlinking them (orphan GC; CCR-1, added by
    /// orchestrator ruling R2 at the L3 close-out). Each key of `orphans` (with its listed size) that is neither in the
    /// blob table nor being placed becomes `doomed(unreferenced)` with that size, eligible once `deletionGrace` has
    /// passed on the awake clock from now, and stops being a launch orphan, so `apply` no longer binds it as one
    /// (ruling R1). The reaper then unlinks it under the I-3 protocol (a fresh acknowledgement after the grace, no
    /// lease, a store neither degraded nor unavailable), and a publication or an adoption of the key before that rescues
    /// it (ADR-018): no binder can lose the file to the sweep any more. Synchronous, so no window; the doom rides along
    /// with the next commit (`.lazy`). Returns the keys it doomed, sorted.
    func doomOrphans(_ orphans: [BlobKey: Int64]) -> [BlobKey] {
        let eligibleAt = self.environment.time.uptimeNow().adding(seconds: self.configuration.policy.deletionGrace)
        var doomed: [BlobKey] = []
        for (key, size) in orphans.sorted(by: { $0.key < $1.key })
        where self.state.core.blobTable[key] == nil && !self.state.core.publishing.contains(key) {
            // Never in any snapshot, so the grace starts now rather than at an acknowledgement.
            self.state.core.blobTable[key] = .doomed(
                DoomInfo(reason: .unreferenced, sinceSnapshotVersion: self.state.core.snapshots.version, droppedInGeneration: 0, eligibleAt: eligibleAt)
            )
            self.state.core.blobBytes[key] = max(0, size)
            self.state.core.orphans[key] = nil
            doomed.append(key)
        }
        if !doomed.isEmpty {
            self.markDirtyInternal(.lazy)
        }
        return doomed
    }
}
