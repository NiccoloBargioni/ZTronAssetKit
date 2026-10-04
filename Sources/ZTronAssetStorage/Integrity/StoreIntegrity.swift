import Foundation
import ZTronAssetModel

/// Quarantine, deep verification and persisted failure bookkeeping (R-CLN-8, R-INT-3, R-INT-4, R-NET-6; WP-C,
/// ADR-046, ADR-032).
extension AssetStore {
    /// Quarantines the entry and dooms its blob as `.corrupt` (R-CLN-8, ADR-018).
    package func reportUnreadable(_ id: AssetID) async throws(StoreError) {
        fatalError("WP-C: AssetStore.reportUnreadable not implemented")
    }

    /// Deep verification from the oldest `verifiedAt`, within a byte budget and a deadline (R-INT-4); resumes at
    /// `state.integrity.cursor`.
    package func verifyIntegrity(byteBudget: Int64, until deadline: MonotonicInstant) async throws(StoreError)
        -> VerificationReport
    {
        fatalError("WP-C: AssetStore.verifyIntegrity not implemented")
    }

    /// Records an integrity failure for content that failed verification (R-INT-3), persisted: a quarantine with
    /// backoff, then `failed(.integrity)` after `maxIntegrityAttempts`. The engine calls it for transport and store
    /// integrity failures alike (ADR-032).
    package func recordIntegrityFailure(_ ids: [AssetID], identity: ContentIdentity) async throws(StoreError) {
        fatalError("WP-C: AssetStore.recordIntegrityFailure not implemented")
    }

    /// Marks every id in `ids` whose record still has content identity `identity` as `failed(reason)`, persisted
    /// (`markDirty(.soon)`), so neither a later run nor a relaunch fetches it until the manifest entry's identity
    /// changes; WP-B's `apply` clears it then (ARCHITECTURE §7.6, ADR-032). Records whose identity already changed
    /// are left alone (the failure is about content that is no longer wanted). `reason` is `.notFound` for a
    /// 404/410 (R-NET-6) or `.unreadable`; integrity failures go through `recordIntegrityFailure(_:identity:)`,
    /// which backs off first.
    package func recordFailure(_ ids: [AssetID], identity: ContentIdentity, reason: FailureReason) async throws(StoreError) {
        fatalError("WP-C: AssetStore.recordFailure not implemented")
    }
}
