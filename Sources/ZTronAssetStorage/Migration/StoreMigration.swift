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
    func runLegacyPhaseOne() async throws(StoreError) -> Bool {
        fatalError("WP-C: AssetStore.runLegacyPhaseOne not implemented")
    }

    /// Adopts up to `maxFiles` legacy files (hash, then `adoptVerifiedFile`), publishing snapshots as it goes at bulk
    /// urgency; phases 3 and 4 run when nothing remains. Phase 3 sets `state.core.stamp` (every entry adopted) or
    /// `state.core.syncDue` (directly or through `markSyncDue()`), then commits durably.
    package func migrateLegacy(maxFiles: Int) async throws(StoreError) -> LegacyMigrationProgress {
        fatalError("WP-C: AssetStore.migrateLegacy not implemented")
    }

    /// Adopt-on-demand for a `resolve` or lease of a legacy id not yet adopted (store-2 S2-09); installs its
    /// snapshot at once.
    package func adoptLegacyNow(_ id: AssetID) async throws(StoreError) -> AssetLocation? {
        fatalError("WP-C: AssetStore.adoptLegacyNow not implemented")
    }
}
