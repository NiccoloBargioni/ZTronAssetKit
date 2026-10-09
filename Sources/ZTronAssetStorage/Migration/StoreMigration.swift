import Foundation
import ZTronAssetModel

/// Legacy migration (R-STO-11, H-10; WP-C, ADR-029, ADR-046): adopt-by-hash via same-volume rename in committed
/// phases.
extension AssetStore {
    /// **Hook called by WP-B's `open()`** when `configuration.legacy.enabled`: legacy phase 1 inside `open()`
    /// (plan from the prior art's `manifest.json` and `local-checksums.json` decoded under `configuration.limits`
    /// with duplicates kept first, driven by a **non-following** recursive listing; one ordered commit) or, when the
    /// persisted phase is `inProgress`, the plan is rebuilt. Returns whether phase 2 has work
    /// (`OpenReport.legacyMigrationPending`). Publishes no snapshot (no snapshot precedes reconciliation, S1-18).
    ///
    /// Its direct writes to `state.core` (ARCHITECTURE §1.1 rule 1, round 4): it installs the legacy manifest as
    /// `appliedManifest` (with `etag` `nil`) only while the applied manifest is empty, inserts records only for ids
    /// that manifest lists and the index lacks, each as `absent(.neverFetched)` with `expectedBlob`, and sets
    /// `degraded` when `manifest.json` cannot be decoded. It cannot call `apply`: async APIs await `open()`
    /// (REENTRANCY R1).
    ///
    /// Nothing happens in a lifetime that cannot write (B-34) or whose legacy root cannot be stat-ed. Without a legacy
    /// tree before migration started, the prior art's stamp is removed and never migrated (D-6). A legacy entry is
    /// planned only when its file appears in the listing and its bytes have a verifiable digest (the manifest checksum,
    /// or for a checksum-less entry the prior art's local checksum); everything else is dropped and downloaded again. A
    /// failed phase-1 commit leaves the writes dirty for the launch commit; phase 2 commits before it moves a file.
    func runLegacyPhaseOne() async throws(StoreError) -> Bool {
        // REENTRANCY: R1, R11 — `performLegacyPhaseOne` re-checks the phase (`opening`) after each of its units.
        try await self.performLegacyPhaseOne()
    }

    /// Adopts up to `maxFiles` legacy files (hash, then `adoptVerifiedFile`), publishing snapshots as it goes at bulk
    /// urgency; phases 3 and 4 run when nothing remains. Phase 3 sets `state.core.stamp` (every entry adopted) or
    /// `state.core.syncDue` (directly or through `markSyncDue()`), then commits durably.
    ///
    /// Progress is cumulative over the lifetime; `finished` once the tree and the key are gone (also when there was
    /// nothing to migrate). A cancelled caller gets `.cancelled` and the file it was hashing stays queued; a file whose
    /// bytes do not verify, that vanished or that no record wants any more counts as dropped. Phase 3 never overrides a
    /// newer stamp the engine wrote meanwhile.
    package func migrateLegacy(maxFiles: Int) async throws(StoreError) -> LegacyMigrationProgress {
        try await self.performMigrateLegacy(maxFiles: maxFiles)
    }

    /// Adopt-on-demand for a `resolve` or lease of a legacy id not yet adopted (store-2 S2-09); installs its
    /// snapshot at once.
    ///
    /// Returns the asset's current location when it is present (adopted or not), `nil` when it is neither present nor a
    /// legacy file still to adopt, or when its file did not verify.
    package func adoptLegacyNow(_ id: AssetID) async throws(StoreError) -> AssetLocation? {
        try await self.performAdoptLegacyNow(id)
    }
}
