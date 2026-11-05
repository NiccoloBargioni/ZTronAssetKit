import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The shared setup of the owed re-route tests (Stage 3 close-out cycle 21, ruling S3-R26 item 1; `integrate-rr21.md`'s
/// tests_and_mutants): O's content (16 bytes) holds zz-o, which O keeps, with a user waiter K, and zz-a1…zz-a<n>, which
/// the test's apply moves away, each wanted as `OwedWanters` says. O downloads; the test holds its publication at its
/// first store unit, applies its manifests, and releases the unit with the drain's turns held: the commit's answer and
/// re-routes (1 + n) pass `inboundIDsNow` (2 at `followIDsPerTurn = 4`), so it owes them as one batch. The test acts
/// between the owing instant and the replay, then releases the follow's and the drain's turns one at a time, reading
/// the invariants after each.
extension EngineFollowBarrierTests {
    /// The follow's ids a turn in the owed re-route tests: `inboundIDsNow` 2, a drain turn's ids 4.
    static let owedIDsPerTurn = 4

    /// Who wants `stageOwedCommit`'s moved ids.
    enum OwedWanters: Sendable {
        /// A user waiter per id (W1…W<n>).
        case waiters
        /// One prefetch group of zz-o and every moved id.
        case group
        /// Both.
        case waitersAndGroup
    }

    /// An owed commit's engine, entries and callers (`stageOwedCommit`).
    @available(macOS 15.0, iOS 18.0, *)
    struct OwedCommit {
        let s: FollowBarrier.Setup
        let bulk: SteppedBlockingExecutor
        let seed: UInt64
        /// zz-o on O's content, and its user waiter K.
        let o: ManifestEntry
        let k: Task<Result<AssetLocation, AssetError>, Never>
        /// zz-a1…zz-a<n> on O's content: the ids the test's apply moves away.
        let moved: [ManifestEntry]
        /// Their user waiters W1…W<n> (`.waiters`, `.waitersAndGroup`).
        let w: [Task<Result<AssetLocation, AssetError>, Never>]
        /// The prefetch group of zz-o and the moved ids (`.group`, `.waitersAndGroup`): its interest holds an id O binds
        /// and the ids it does not.
        let group: InterestToken?

        var engine: SyncEngine {
            self.s.engine
        }

        /// O's transfer.
        var transfer: TransferID {
            self.o.transferID
        }

        /// The moved ids.
        var ids: [AssetID] {
            self.moved.map(\.identifier)
        }

        /// The manifest the test applies: `q`, fillers that change with `tag`, zz-o, `entries` and later fillers.
        func manifest(_ entries: [ManifestEntry], round: UInt64) -> [ManifestEntry] {
            [self.s.q] + FollowBarrier.fillers(self.seed + 100 + 100 * round) + [self.o] + entries + EngineFollowBarrierTests.laterFillers(self.seed + 3_000 * (round + 1))
        }
    }

    /// O's 16 bytes for `seed`.
    static func owedOBytes(_ seed: UInt64) -> Data {
        EngineFixture.bytes(seed + 3, count: 16)
    }

    /// The engine of an owed commit, before the test holds O's publication: v2 lists zz-o, zz-a1…zz-a<count> (on O's
    /// content) and `extra`; O downloads (held), with K and the moved ids' wanters on its job (the waiters on `lane`, the
    /// group on `groupLane`), under `network`.
    @available(macOS 15.0, iOS 18.0, *)
    static func stageOwedCommit(seed: UInt64, moved count: Int = 3, extra: [ManifestEntry] = [], wanters: OwedWanters = .waiters, lane: AssetPriority = .userInitiated, groupLane: AssetPriority = .prefetch, tuning: SyncTuning = SyncTuning(), network: NetworkPolicy = NetworkPolicy()) async throws -> OwedCommit {
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed, tuning: tuning, network: network)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = Self.owedIDsPerTurn }
        let oBytes = Self.owedOBytes(seed)
        let o = EngineHarness.onDemand("zz-o", oBytes)
        let moved = (0..<count).map { EngineHarness.onDemand("zz-a\($0 + 1)", oBytes) }
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [o] + moved + extra + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(o.transferID, [.hold, .stage(oBytes)])
        let oID = o.identifier
        let k = Task { await engine.awaitAsset(oID, lane: .userInitiated) }
        var w: [Task<Result<AssetLocation, AssetError>, Never>] = []
        if wanters != .group {
            for entry in moved {
                let id = entry.identifier
                w.append(Task { await engine.awaitAsset(id, lane: lane) })
            }
        }
        var group: InterestToken?
        if wanters != .waiters {
            group = try await engine.registerGroup(([o] + moved).map(\.identifier), lane: groupLane).get()
        }
        let interests = 1 + w.count + (group == nil ? 0 : 1)
        let transfer = o.transferID
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[transfer]?.state == .downloading && $0.state.jobs[transfer]?.interests.count == interests }
        }
        return OwedCommit(s: s, bulk: bulk, seed: seed, o: o, k: k, moved: moved, w: w, group: group)
    }

    /// The store units a test keeps held (`holdPublications`), and the task that releases every other one: a release of a
    /// kept unit stops that task first and starts another without the unit, since the task waits for one held unit more
    /// than it keeps (a kept unit released under it left that count one too high, and a later apply's unit waited).
    @available(macOS 15.0, iOS 18.0, *)
    struct HeldUnits {
        let bulk: SteppedBlockingExecutor
        /// The kept units still held, in the order they were held.
        private(set) var kept: [Int]
        private var releaser: Task<Void, Never>

        init(bulk: SteppedBlockingExecutor, kept: [Int], releaser: Task<Void, Never>) {
            self.bulk = bulk
            self.kept = kept
            self.releaser = releaser
        }

        /// Releases kept `unit`.
        mutating func release(_ unit: Int) async {
            self.releaser.cancel()
            await self.releaser.value
            await self.bulk.release(unit)
            self.kept.removeAll { $0 == unit }
            self.releaser = EngineFollowBarrierTests.releasing(except: self.kept, self.bulk)
        }

        /// Stops holding: every later store unit runs.
        func stop() async {
            self.releaser.cancel()
            await self.releaser.value
            await self.bulk.setHolding(false)
        }
    }

    /// Releases every held store unit but `kept`, which stay held, until cancelled.
    @available(macOS 15.0, iOS 18.0, *)
    static func releasing(except kept: [Int], _ bulk: SteppedBlockingExecutor) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                await bulk.waitForHeldUnits(atLeast: kept.count + 1)
                for other in await bulk.heldUnits where !kept.contains(other) {
                    await bulk.release(other)
                }
            }
        }
    }

    /// The batches of owed re-routes that wait, in queue order.
    static func owedBatches(_ e: isolated SyncEngine) -> [RerouteBatch] {
        e.state.eventsAfterFollow.compactMap { event in
            if case .reroutes(let batch) = event {
                return batch
            }
            return nil
        }
    }

    /// Releases O's held store unit with the drain's turns held, so that O's publication commits, and returns the
    /// batches that wait once O's job is gone.
    @available(macOS 15.0, iOS 18.0, *)
    static func commitOwing(_ c: OwedCommit, unit: Int) async -> [RerouteBatch] {
        let engine = c.engine
        let transfer = c.transfer
        await engine.readForTests { $0.holdDrainFollowUps() }
        await c.bulk.release(unit)
        await engine.awaitCondition { $0.state.jobs[transfer] == nil }
        return await engine.readForTests { e in Self.owedBatches(e) }
    }

    /// Applies `entries` while a batch waits, the follow's turns held in both orders, and returns whether a batch still
    /// waits: the apply records a layer on it first (`layerOwedReroutes`, in `adoptApplied`). A follow with a job to visit
    /// past its first turn stays owed, so the batch waits for the released turns and records a layer at each later apply
    /// too; a follow that ends in the apply's turn, with no job left to visit, replays the batch at its end, as visited
    /// first with nothing in flight. `waits` is the answer the test's shape gives.
    @available(macOS 15.0, iOS 18.0, *)
    @discardableResult
    static func applyBehindBatch(_ entries: [ManifestEntry], tag: String, _ c: OwedCommit, waits: Bool = true) async throws -> Bool {
        let engine = c.engine
        let manifest = try ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data(tag.utf8)))
        await engine.readForTests { $0.holdFollowFollowUps() }
        let applied = await engine.applyAndFollow(manifest, etag: nil, eviction: nil)
        #expect((try? applied.get()) != nil, "setup: \(tag) is applied: \(applied)")
        let waiting = await engine.readForTests { !Self.owedBatches($0).isEmpty }
        #expect(waiting == waits, "setup: after \(tag), a batch \(waits ? "still waits" : "has replayed at the follow's end")")
        return waiting
    }

    /// The layers of the first waiting batch: for each, whether its ends pin `transfer`.
    @available(macOS 15.0, iOS 18.0, *)
    static func pins(_ transfer: TransferID, _ c: OwedCommit) async -> [Bool] {
        await c.engine.readForTests { e in Self.owedBatches(e).first?.layers.map { $0.ends[transfer] != nil } ?? [] }
    }

    /// Releases the follow's and the drain's held turns one at a time until no follow is owed and no event waits, then
    /// lets later turns run; returns each turn's kind and the invariant violations read after each.
    @available(macOS 15.0, iOS 18.0, *)
    static func releaseOwedTurns(_ c: OwedCommit) async -> (turns: [HeldTurn], violations: [String]) {
        let engine = c.engine
        var turns: [HeldTurn] = []
        var violations: [String] = []
        while await engine.readForTests({ $0.followOwed || !$0.state.eventsAfterFollow.isEmpty }) {
            turns.append(await Self.runOneHeldTurn(engine))
            violations += await engine.invariantViolations()
        }
        await engine.readForTests { e in
            e.releaseDrainFollowUps()
            e.releaseFollowFollowUps()
        }
        return (turns, violations)
    }

    /// The answers of K and of the moved ids' waiters, driving the clock.
    @available(macOS 15.0, iOS 18.0, *)
    static func owedAnswers(_ c: OwedCommit) async -> (k: Result<AssetLocation, AssetError>, w: [Result<AssetLocation, AssetError>]) {
        let engine = c.engine
        let k = await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) { await EngineHarness.value(of: c.k) }
        var w: [Result<AssetLocation, AssetError>] = []
        for waiter in c.w {
            w.append(await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        return (k, w)
    }

    /// The byte counts of `results`, -1 for a failure.
    static func sizes(_ results: [Result<AssetLocation, AssetError>]) -> [Int64] {
        results.map { (try? $0.get())?.byteSize ?? -1 }
    }

    /// The transport starts of `transfer` so far.
    @available(macOS 15.0, iOS 18.0, *)
    static func starts(_ transfer: TransferID, _ c: OwedCommit) async -> Int {
        await c.s.harness.source.starts.filter { $0.id == transfer }.count
    }
}
