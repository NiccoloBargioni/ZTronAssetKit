import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetSync

/// Seeded properties of the pure planner (R-SYN-1, R-SYN-8, R-SYN-11, R-INT-3, R-INT-5; sync.md §4.5). Every failure
/// names its seed, so it replays exactly.
@Suite("Planner properties")
struct PlannerPropertyTests {
    static let seeds: [UInt64] = (1...40).map { 0x5EED_0000 + $0 }

    @Test("R-SYN-1: the plan is identical for equal inputs built in different dictionary orders", arguments: PlannerPropertyTests.seeds)
    func identicalAcrossDictionaryOrders(seed: UInt64) {
        let scenario = PlanScenario.make(seed: seed)
        let first = PlanFixture.plan(scenario.manifest, scenario.view())
        let second = PlanFixture.plan(scenario.manifest, scenario.view(reversed: true))
        #expect(first == second, "seed \(seed)")
        #expect(!first.fetches.isEmpty || !first.skipped.isEmpty || !first.reconcile.prunes.isEmpty, "seed \(seed): the scenario plans some work")
    }

    @Test("R-SYN-1: every identifier lands in exactly one plan bucket", arguments: PlannerPropertyTests.seeds)
    func partition(seed: UInt64) {
        let scenario = PlanScenario.make(seed: seed)
        let plan = PlanFixture.plan(scenario.manifest, scenario.view())
        var buckets: [AssetID: Int] = [:]
        for id in plan.fetches.map(\.id) + plan.reconcile.reuses + plan.reconcile.prunes + plan.skipped.map(\.id) {
            buckets[id, default: 0] += 1
        }
        let ids = Set(scenario.manifest.entries.map(\.identifier)).union(scenario.applied.entries.map(\.identifier))
        let settled = ids.filter { buckets[$0] == nil }
        #expect(buckets.values.allSatisfy { $0 == 1 }, "seed \(seed): an id is in two buckets")
        #expect(plan.totals.unchangedCount == settled.count - Set(plan.reconcile.relocations).intersection(settled).count, "seed \(seed)")
        for id in settled {
            let record = scenario.records.first { $0.entry.identifier == id }
            #expect(record?.referencedBlob != nil, "seed \(seed): \(id) is settled without a blob")
        }
    }

    @Test("R-SYN-1: planning an applied manifest against itself yields no work")
    func identityYieldsNoWork() {
        let entries = (0..<20).map { PlanFixture.entry("e\($0)", content: $0 % 5 == 0 ? nil : UInt64($0)) }
        let manifest = PlanFixture.manifest(entries)
        let view = PlanFixture.view(applied: manifest, records: entries.map { PlanFixture.present($0) })
        let plan = PlanFixture.plan(manifest, view)
        #expect(plan.fetches.isEmpty)
        #expect(plan.reconcile.relocations.isEmpty && plan.reconcile.reuses.isEmpty && plan.reconcile.prunes.isEmpty)
        #expect(plan.skipped.isEmpty)
        #expect(plan.totals.unchangedCount == 20)
        #expect(plan.space == .fits)
    }

    @Test("R-SYN-8: a directory or file-name change plans zero downloads")
    func metadataOnlyChurnPlansNoDownload() {
        let entries = (0..<10).map { PlanFixture.entry("e\($0)", content: UInt64($0)) }
        let applied = PlanFixture.manifest(entries)
        let moved = entries.map { entry -> ManifestEntry in
            var next = entry
            next.localPathComponents = ["new", "place"]
            next.localFileName = "renamed-\(entry.identifier.rawValue)"
            return next
        }
        let plan = PlanFixture.plan(PlanFixture.manifest(moved), PlanFixture.view(applied: applied, records: entries.map { PlanFixture.present($0) }))
        #expect(plan.fetches.isEmpty)
        #expect(plan.totals.fetchBytes == 0)
        #expect(plan.reconcile.relocations == moved.map(\.identifier))
    }

    @Test("R-SYN-1: fetch order is stable and essential-first", arguments: PlannerPropertyTests.seeds)
    func fetchOrder(seed: UInt64) {
        let scenario = PlanScenario.make(seed: seed)
        let plan = PlanFixture.plan(scenario.manifest, scenario.view())
        let keys = plan.fetches.map { ($0.rank, $0.manifestIndex) }
        #expect(zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 }, "seed \(seed): fetches out of order")
        for fetch in plan.fetches {
            #expect(scenario.manifest.position(of: fetch.id) == fetch.manifestIndex, "seed \(seed)")
            #expect(fetch.rank == fetch.entry.policy.rank && fetch.transfer == fetch.entry.transferID, "seed \(seed)")
        }
        // Removing an unrelated entry never reorders the others.
        guard let victim = scenario.manifest.entries.first(where: { entry in !plan.fetches.contains { $0.id == entry.identifier } }) else {
            return
        }
        let smaller = PlanFixture.manifest(scenario.manifest.entries.filter { $0.identifier != victim.identifier })
        let replanned = PlanFixture.plan(smaller, scenario.view())
        #expect(replanned.fetches.map(\.id) == plan.fetches.map(\.id), "seed \(seed): an unrelated removal reordered fetches")
    }

    @Test("R-SYN-1: plan totals equal the sums of their lists", arguments: PlannerPropertyTests.seeds)
    func totals(seed: UInt64) {
        let scenario = PlanScenario.make(seed: seed)
        let plan = PlanFixture.plan(scenario.manifest, scenario.view())
        #expect(plan.totals.fetchCount == plan.fetches.count, "seed \(seed)")
        #expect(plan.totals.fetchUnknownSizeCount == plan.fetches.filter { $0.entry.byteSize == nil }.count, "seed \(seed)")
        #expect(plan.totals.relocationCount == plan.reconcile.relocations.count, "seed \(seed)")
        #expect(plan.totals.reuseCount == plan.reconcile.reuses.count, "seed \(seed)")
        #expect(plan.totals.pruneCount == plan.reconcile.prunes.count, "seed \(seed)")
        #expect(plan.totals.skippedCount == plan.skipped.count, "seed \(seed)")
        var seen = Set<TransferID>()
        let bytes = plan.fetches.reduce(Int64(0)) { sum, fetch in
            seen.insert(fetch.transfer).inserted ? sum + (fetch.entry.byteSize ?? 0) : sum
        }
        #expect(plan.totals.fetchBytes == bytes, "seed \(seed): one transfer's bytes count once")
        let pruned = plan.reconcile.prunes.compactMap { id in scenario.records.first { $0.entry.identifier == id } }
        let pruneBytes = pruned.reduce(Int64(0)) { sum, record in
            if case .present(_, let size, _) = record.residency {
                return sum + size
            }
            return sum
        }
        #expect(plan.totals.pruneBytes == pruneBytes, "seed \(seed)")
    }

    @Test("R-SYN-1: narrowing the scope only removes fetches", arguments: PlannerPropertyTests.seeds)
    func scopeMonotonicity(seed: UInt64) {
        let scenario = PlanScenario.make(seed: seed)
        let all = PlanFixture.plan(scenario.manifest, scenario.view())
        let narrow = PlanFixture.plan(scenario.manifest, scenario.view(), scope: .tags(["x"]))
        #expect(Set(narrow.fetches.map(\.id)).isSubset(of: Set(all.fetches.map(\.id))), "seed \(seed)")
        #expect(narrow.reconcile == all.reconcile, "seed \(seed): reconcile depends on scope")
        #expect(narrow.fetches.allSatisfy { $0.entry.tags.contains("x") }, "seed \(seed)")
        #expect(narrow.skipped.contains { $0.reason == .outOfScope } || narrow.fetches.count == all.fetches.count, "seed \(seed)")
    }

    @Test("R-SYN-11: more free space never worsens the space assessment", arguments: PlannerPropertyTests.seeds)
    func spaceIsMonotone(seed: UInt64) {
        let scenario = PlanScenario.make(seed: seed)
        func severity(_ space: SpaceAssessment) -> Int {
            switch space {
            case .fits:
                return 0
            case .needsEviction:
                return 1
            case .partial:
                return 2
            case .insufficient:
                return 3
            }
        }
        for eviction in [true, false] {
            var previous = Int.max
            for free: Int64 in [0, 500, 2_000, 8_000, 1 << 40] {
                let plan = PlanFixture.plan(scenario.manifest, scenario.view(), policy: PlanFixture.policy(eviction: eviction), space: PlanFixture.space(free: free))
                let current = severity(plan.space)
                #expect(current <= previous, "seed \(seed): \(free) free bytes worsened the assessment")
                previous = current
            }
        }
    }

    @Test("R-SYN-1: a checksum-less entry is re-fetched only when its remotePath changes")
    func legacyEntriesFollowRemotePath() {
        let legacy = PlanFixture.entry("legacy", content: nil, size: 10)
        let applied = PlanFixture.manifest([legacy])
        let view = PlanFixture.view(applied: applied, records: [PlanFixture.present(legacy)])
        var resized = legacy
        resized.byteSize = 99
        #expect(PlanFixture.plan(PlanFixture.manifest([resized]), view).fetches.isEmpty)
        var moved = legacy
        moved.remotePath = "media/other.png"
        let plan = PlanFixture.plan(PlanFixture.manifest([moved]), view)
        #expect(plan.fetches.map(\.reason) == [.legacyPathChanged])
        #expect(plan.fetches.first?.transfer == TransferID.legacy(identifier: legacy.identifier, remotePath: "media/other.png"))
    }

    @Test("R-INT-3: a quarantined entry is skipped until its manifest fingerprint changes")
    func quarantineHoldsUntilFingerprintChanges() {
        let quarantined = PlanFixture.entry("q", content: 1)
        let failed = PlanFixture.entry("f", content: 2)
        let applied = PlanFixture.manifest([quarantined, failed])
        let view = PlanFixture.view(applied: applied, records: [
            PlanFixture.record(quarantined, .quarantined(until: PlanFixture.now.addingTimeInterval(60))),
            PlanFixture.record(failed, .failed(.integrity)),
        ])
        let unchanged = PlanFixture.plan(applied, view)
        #expect(unchanged.fetches.isEmpty)
        #expect(unchanged.skipped == [PlannedSkip(id: "q", reason: .integrityQuarantined), PlannedSkip(id: "f", reason: .failedUntilEntryChanges)])
        var newQ = quarantined
        newQ.checksum = PlanFixture.hash(11)
        var newF = failed
        newF.checksum = PlanFixture.hash(12)
        let changed = PlanFixture.plan(PlanFixture.manifest([newQ, newF]), view)
        #expect(changed.fetches.map(\.id) == ["q", "f"])
        #expect(changed.skipped.isEmpty)
        // Once the backoff passed, the same fingerprint is fetched again.
        let expired = PlanFixture.view(applied: applied, records: [PlanFixture.record(quarantined, .quarantined(until: PlanFixture.now.addingTimeInterval(-1)))])
        #expect(PlanFixture.plan(PlanFixture.manifest([quarantined]), expired).fetches.map(\.id) == ["q"])
    }

    @Test("R-INT-5: unverified entries are skipped when allowUnverifiedAssets is false")
    func unverifiedSkipped() {
        let legacy = PlanFixture.entry("legacy", content: nil)
        let verified = PlanFixture.entry("verified", content: 3)
        let manifest = PlanFixture.manifest([legacy, verified])
        let view = PlanFixture.view(applied: .empty(), records: [])
        let strict = PlanFixture.plan(manifest, view, policy: PlanFixture.policy(unverified: false))
        #expect(strict.fetches.map(\.id) == ["verified"])
        #expect(strict.skipped == [PlannedSkip(id: "legacy", reason: .unverifiedDisallowed)])
        #expect(PlanFixture.plan(manifest, view).fetches.map(\.id) == ["legacy", "verified"])
    }

    @Test("R-MAN-6: on-demand entries are fetched only by explicit scopes")
    func onDemandNeedsExplicitScope() {
        let lazy = PlanFixture.entry("lazy", content: 4, policy: .onDemand)
        let manifest = PlanFixture.manifest([lazy])
        let view = PlanFixture.view(applied: .empty(), records: [])
        #expect(PlanFixture.plan(manifest, view).skipped == [PlannedSkip(id: "lazy", reason: .onDemandPolicy)])
        let explicit = PlanFixture.plan(manifest, view, scope: .identifiers(["lazy"]), policy: PlanFixture.policy(onDemand: true))
        #expect(explicit.fetches.map(\.id) == ["lazy"])
    }

    @Test("R-SYN-11: a catalog larger than the budget syncs its largest fitting prefix essential-first")
    func largestFittingPrefix() {
        let entries = [
            PlanFixture.entry("s0", content: 1, size: 400),
            PlanFixture.entry("e0", content: 2, size: 300, policy: .essential),
            PlanFixture.entry("s1", content: 3, size: 400),
            PlanFixture.entry("e1", content: 4, size: 300, policy: .essential),
        ]
        let plan = PlanFixture.plan(PlanFixture.manifest(entries), PlanFixture.view(applied: .empty(), records: []), policy: PlanFixture.policy(eviction: false), space: PlanFixture.space(budget: 1_000))
        #expect(plan.fetches.map(\.id) == ["e0", "e1", "s0"])
        #expect(plan.skipped == [PlannedSkip(id: "s1", reason: .overBudget)])
        #expect(plan.space == .partial(admittedFetches: 3, skippedBytes: 400))
        let strict = PlanFixture.plan(PlanFixture.manifest(entries), PlanFixture.view(applied: .empty(), records: []), policy: PlanFixture.policy(prefix: false, eviction: false), space: PlanFixture.space(free: 5_000, budget: 1_000, reserve: 100))
        // The plan's known bytes against the room it had: within the budget, above the reserve (ARCHITECTURE §7.10).
        #expect(strict.space == .insufficient(required: 1_400, available: 1_000))
    }

    @Test("R-SYN-11: a manifest without byteSize never fails the space check with insufficientSpace")
    func unknownSizesAreNotEstimated() {
        let entries = (0..<5).map { PlanFixture.entry("u\($0)", content: UInt64($0), size: nil) }
        let plan = PlanFixture.plan(PlanFixture.manifest(entries), PlanFixture.view(applied: .empty(), records: []), policy: PlanFixture.policy(prefix: false, eviction: false), space: PlanFixture.space(free: 0, budget: 0))
        #expect(plan.space == .fits)
        #expect(plan.totals.fetchUnknownSizeCount == 5 && plan.totals.fetchBytes == 0)
    }

    @Test("R-SYN-11: a run with nothing to fetch completes when usage exceeds the budget")
    func zeroFetchBytesAlwaysFit() {
        let entry = PlanFixture.entry("p", content: 1)
        let manifest = PlanFixture.manifest([entry])
        let plan = PlanFixture.plan(manifest, PlanFixture.view(applied: manifest, records: [PlanFixture.present(entry)]), policy: PlanFixture.policy(prefix: false, eviction: false), space: PlanFixture.space(free: 0, used: 10_000, budget: 10))
        #expect(plan.space == .fits)
    }

    @Test("R-SYN-11: an over-budget plan with eviction permitted asks for exactly the shortfall")
    func evictionShortfall() {
        let entries = [PlanFixture.entry("a", content: 1, size: 600), PlanFixture.entry("b", content: 2, size: 600)]
        let plan = PlanFixture.plan(PlanFixture.manifest(entries), PlanFixture.view(applied: .empty(), records: []), space: PlanFixture.space(free: 10_000, used: 500, budget: 1_500))
        #expect(plan.space == .needsEviction(bytes: 200))
    }

    @Test("R-SYN-1: a stale, missing or healing record is fetched for its current content")
    func fetchReasons() {
        let added = PlanFixture.entry("added", content: 1)
        let changed = PlanFixture.entry("changed", content: 2)
        let missing = PlanFixture.entry("missing", content: 3)
        let healing = PlanFixture.entry("healing", content: 4)
        var newChanged = changed
        newChanged.checksum = PlanFixture.hash(22)
        let applied = PlanFixture.manifest([changed, missing, healing])
        let view = PlanFixture.view(applied: applied, records: [
            PlanFixture.present(changed),
            PlanFixture.record(missing, .absent(.neverFetched)),
            PlanFixture.record(healing, .needsHeal(lastBlob: PlanFixture.key(PlanFixture.hash(4)))),
        ])
        let plan = PlanFixture.plan(PlanFixture.manifest([added, newChanged, missing, healing]), view)
        #expect(plan.fetches.map(\.reason) == [.added, .contentChanged, .missingBlob, .needsHeal])
        #expect(plan.fetches.map(\.identity) == [added.contentIdentity, newChanged.contentIdentity, missing.contentIdentity, healing.contentIdentity])
    }

    @Test("R-SYN-8: content already present as a blob is reused instead of fetched")
    func reusesLiveBlobs() {
        let original = PlanFixture.entry("old-name", content: 7)
        let applied = PlanFixture.manifest([original])
        let renamed = PlanFixture.entry("new-name", content: 7)
        let plan = PlanFixture.plan(PlanFixture.manifest([renamed]), PlanFixture.view(applied: applied, records: [PlanFixture.present(original)]))
        #expect(plan.fetches.isEmpty)
        #expect(plan.reconcile.reuses == ["new-name"])
        #expect(plan.reconcile.prunes == ["old-name"])
        #expect(plan.reconcile.adopts == PlanFixture.manifest([renamed]))
    }
}
