import Foundation
import ZTronAssetModel
import ZTronAssetStorage

/// Why an entry is fetched.
package enum FetchReason: Sendable, Hashable {
    /// New in the manifest.
    case added
    /// Its content identity changed (stale until committed).
    case contentChanged
    /// Applied but never fetched, evicted or purged.
    case missingBlob
    /// Its blob vanished (R-CLN-7, I-2).
    case needsHeal
    /// A checksum-less entry whose `remotePath` changed (R-MAN-5, ADR-034).
    case legacyPathChanged
}

/// Why an entry is not fetched by this plan.
package enum SkipReason: Sendable, Hashable {
    /// Outside the run's scope.
    case outOfScope
    /// `onDemand` and the scope is not explicit (R-MAN-6).
    case onDemandPolicy
    /// Checksum-less while `allowUnverifiedAssets` is false (R-INT-5).
    case unverifiedDisallowed
    /// In integrity backoff (R-INT-3), until `nextEligibleAt`.
    case integrityQuarantined
    /// Failed until its manifest entry changes (R-INT-3).
    case failedUntilEntryChanges
    /// Beyond the largest fitting prefix of an over-budget catalog (ADR-025, sync-2 S2-07).
    case overBudget
}

/// One planned fetch, in the plan's stable order (ARCHITECTURE §7.3).
package struct PlannedFetch: Sendable, Hashable {
    /// The asset.
    package var id: AssetID
    /// Its manifest entry.
    package var entry: ManifestEntry
    /// Its content identity (the store's `publish` guard).
    package var identity: ContentIdentity
    /// The single-flight key (ADR-020).
    package var transfer: TransferID
    /// Why it is fetched.
    package var reason: FetchReason
    /// `AssetPolicy.rank`: essential 0, standard 1, onDemand 2.
    package var rank: Int
    /// Position in the manifest.
    package var manifestIndex: Int

    /// Creates a planned fetch.
    package init(
        id: AssetID,
        entry: ManifestEntry,
        identity: ContentIdentity,
        transfer: TransferID,
        reason: FetchReason,
        rank: Int,
        manifestIndex: Int
    ) {
        self.id = id
        self.entry = entry
        self.identity = identity
        self.transfer = transfer
        self.reason = reason
        self.rank = rank
        self.manifestIndex = manifestIndex
    }
}

/// One skipped entry.
package struct PlannedSkip: Sendable, Hashable {
    /// The asset.
    package var id: AssetID
    /// Why.
    package var reason: SkipReason

    /// Creates a skip.
    package init(id: AssetID, reason: SkipReason) {
        self.id = id
        self.reason = reason
    }
}

/// What reconciliation will do (R-SYN-8). The store computes the same from the same inputs in
/// `AssetStore.apply`; a seeded property test pins `ApplyReport == ReconcileStep` (ADR-030).
package struct ReconcileStep: Sendable, Hashable {
    /// Metadata-only changes: index edits, zero bytes.
    package var relocations: [AssetID]
    /// Content already present as a blob (dedupe, renamed id).
    package var reuses: [AssetID]
    /// Ids gone from the manifest.
    package var prunes: [AssetID]
    /// The manifest that becomes applied.
    package var adopts: ValidatedManifest

    /// Creates a step.
    package init(relocations: [AssetID], reuses: [AssetID], prunes: [AssetID], adopts: ValidatedManifest) {
        self.relocations = relocations
        self.reuses = reuses
        self.prunes = prunes
        self.adopts = adopts
    }
}

/// The free-space verdict, decided on pure data **before** the first mutation (R-SYN-11).
package enum SpaceAssessment: Sendable, Hashable {
    /// Everything fits.
    case fits
    /// Fits after the store evicts this many bytes (the eviction plan is committed with reconcile).
    case needsEviction(bytes: Int64)
    /// Over budget: the largest fitting prefix in plan order is admitted, the rest skipped (ADR-025).
    case partial(admittedFetches: Int, skippedBytes: Int64)
    /// Nothing can be admitted without breaking the reserve: the run fails with no side effect. `required` is the plan's
    /// known bytes and `available` the room it had (the volume above the reserve plus pending reclaim, within the
    /// budget; ARCHITECTURE §7.10), the convention every `insufficientSpace` the engine reports follows.
    case insufficient(required: Int64, available: Int64)
}

/// Planner inputs beyond manifest, view, scope and free space.
package struct PlanningPolicy: Sendable, Hashable {
    /// R-INT-5.
    package var allowUnverifiedAssets: Bool
    /// `onDemand` entries are eligible (explicit scopes, sync.md §12.2).
    package var includeOnDemand: Bool
    /// ADR-025.
    package var admitLargestFittingPrefix: Bool
    /// Eviction may make room (R-SYN-11 "policy permitting"): `StoragePolicy.evictionPermitted`.
    package var evictionPermitted: Bool
    /// The wall clock, for `nextEligibleAt` comparisons (passed in: the planner reads no clock).
    package var now: Date

    /// Creates a policy.
    package init(
        allowUnverifiedAssets: Bool,
        includeOnDemand: Bool,
        admitLargestFittingPrefix: Bool,
        evictionPermitted: Bool,
        now: Date
    ) {
        self.allowUnverifiedAssets = allowUnverifiedAssets
        self.includeOnDemand = includeOnDemand
        self.admitLargestFittingPrefix = admitLargestFittingPrefix
        self.evictionPermitted = evictionPermitted
        self.now = now
    }

    /// The policy of a run under `storage` (ADR-048): unverified admission, the largest-fitting-prefix rule and the
    /// eviction switch come from the client's `StoragePolicy`, so no knob is dropped between configuration and
    /// planner. Pure.
    package init(storage: StoragePolicy, includeOnDemand: Bool, now: Date) {
        self.init(
            allowUnverifiedAssets: storage.allowUnverifiedAssets,
            includeOnDemand: includeOnDemand,
            admitLargestFittingPrefix: storage.admitLargestFittingPrefix,
            evictionPermitted: storage.evictionPermitted,
            now: now
        )
    }
}

/// A sync plan (R-SYN-1): pure output of `SyncPlanner.plan`, deterministic and independent of dictionary order.
package struct SyncPlan: Sendable, Hashable {
    /// The view generation it was computed against.
    package var baseGeneration: UInt64
    /// The digest of the manifest it applies.
    package var manifestDigest: ContentHash
    /// Applied first, in one store commit (R-SYN-8).
    package var reconcile: ReconcileStep
    /// In `(rank, manifestIndex)` order.
    package var fetches: [PlannedFetch]
    /// In manifest order.
    package var skipped: [PlannedSkip]
    /// Counts and bytes.
    package var totals: PlanTotals
    /// The space verdict.
    package var space: SpaceAssessment

    /// Creates a plan.
    package init(
        baseGeneration: UInt64,
        manifestDigest: ContentHash,
        reconcile: ReconcileStep,
        fetches: [PlannedFetch],
        skipped: [PlannedSkip],
        totals: PlanTotals,
        space: SpaceAssessment
    ) {
        self.baseGeneration = baseGeneration
        self.manifestDigest = manifestDigest
        self.reconcile = reconcile
        self.fetches = fetches
        self.skipped = skipped
        self.totals = totals
        self.space = space
    }
}

/// The pure planner (R-SYN-1, P-4; WP-F): O(M + S + F log F), no dictionary iteration feeds the output.
package enum SyncPlanner {
    /// Plans a run: `(manifest, snapshot, scope, policy, freeSpace) → SyncPlan`.
    package static func plan(
        manifest: ValidatedManifest,
        snapshot: StorePlanningView,
        scope: AssetScope,
        policy: PlanningPolicy,
        freeSpace: FreeSpace
    ) -> SyncPlan {
        PlanBuilder.plan(manifest: manifest, snapshot: snapshot, scope: scope, policy: policy, freeSpace: freeSpace)
    }
}

/// The planner seam of `SyncEngine` (sync-2 S2-26, ARCHITECTURE §14): the engine calls it off the actor (RE-S07).
/// Production uses `StandardSyncPlanner`; engine tests inject a planner that records its inputs or returns a crafted
/// plan, so engine paths that a real manifest reaches only rarely stay testable (Sync ≥ 90 %).
package protocol SyncPlanning: Sendable {
    /// Plans a run; must be pure and deterministic like `SyncPlanner.plan` (R-SYN-1).
    func plan(
        manifest: ValidatedManifest,
        snapshot: StorePlanningView,
        scope: AssetScope,
        policy: PlanningPolicy,
        freeSpace: FreeSpace
    ) -> SyncPlan
}

/// The production planner: `SyncPlanner.plan`.
package struct StandardSyncPlanner: SyncPlanning {
    /// Creates the planner (stateless).
    package init() {}

    /// Delegates to `SyncPlanner.plan`.
    package func plan(
        manifest: ValidatedManifest,
        snapshot: StorePlanningView,
        scope: AssetScope,
        policy: PlanningPolicy,
        freeSpace: FreeSpace
    ) -> SyncPlan {
        SyncPlanner.plan(manifest: manifest, snapshot: snapshot, scope: scope, policy: policy, freeSpace: freeSpace)
    }
}
