import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A run's claims that a commit owes re-routes (Stage 3 close-out cycle 21, ruling S3-R26 item 1; `integrate-rr21.md`'s
/// tests_and_mutants rr21-T18, T18-partial and RR21-RUN-MIDDRAIN): owing a run's item releases its claim on the job it
/// left (`oweReroutes`), the run settles only once every owed batch is made (`checkRunSettled`'s counter term), and the
/// replay claims the new jobs. Each test runs in both orders (`LaneDropVisit`) and expects the visit-first answers in
/// both.
extension EngineFollowBarrierTests {
    /// A forced sync's run whose claims a commit of O owes re-routes (`stageOwedRun`).
    @available(macOS 15.0, iOS 18.0, *)
    struct OwedRun {
        let s: FollowBarrier.Setup
        let bulk: SteppedBlockingExecutor
        let seed: UInt64
        /// zz-o on O's content (16 bytes), and its user waiter K.
        let o: ManifestEntry
        let k: Task<Result<AssetLocation, AssetError>, Never>
        /// zz-a1…zz-a3 on O's content, the run's claims the test's apply moves away.
        let moved: [ManifestEntry]
        /// The run's sync.
        let sync: Task<SyncOutcome, Never>

        var engine: SyncEngine {
            self.s.engine
        }

        /// O's transfer.
        var transfer: TransferID {
            self.o.transferID
        }

        /// The manifest the test applies: `q`, fillers that change with `round`, zz-o, `entries` and later fillers.
        func manifest(_ entries: [ManifestEntry], round: UInt64) -> [ManifestEntry] {
            [self.s.q] + FollowBarrier.fillers(self.seed + 100 + 100 * round) + [self.o] + entries + EngineFollowBarrierTests.laterFillers(self.seed + 3_000 * (round + 1))
        }
    }

    /// The engine of a run's owed commit, before the test holds O's publication: v2 lists zz-o (an on-demand entry, or,
    /// `partial`, one the run fetches too), zz-a1…zz-a3 (on O's content, the run's) and `extra`, whose transfers follow
    /// `scripts`; a forced sync's run claims them on O, which downloads (held), with K, a user waiter for zz-o, on its job,
    /// and `claimsElsewhere` on the jobs it names, downloading. O's commit then binds no claim of the run's (`partial`:
    /// zz-o's).
    @available(macOS 15.0, iOS 18.0, *)
    static func stageOwedRun(seed: UInt64, partial: Bool, extra: [ManifestEntry] = [], scripts: [TransferID: [FakeTransferStep]] = [:], claimsElsewhere: [TransferID: Set<AssetID>] = [:]) async throws -> OwedRun {
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = Self.owedIDsPerTurn }
        let oBytes = Self.owedOBytes(seed)
        let o = partial ? EngineFixture.entry("zz-o", oBytes) : EngineHarness.onDemand("zz-o", oBytes)
        let moved = (1...3).map { EngineFixture.entry("zz-a\($0)", oBytes) }
        let transfer = o.transferID
        await s.harness.source.script(transfer, [.hold, .stage(oBytes)])
        for (other, steps) in scripts {
            await s.harness.source.script(other, steps)
        }
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [o] + moved + extra + Self.laterFillers(seed + 3_000), etag: "v2")
        let sync = Task { await engine.sync(.force) }
        let claims = Set(((partial ? [o] : []) + moved).map(\.identifier))
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                e.state.jobs[transfer]?.state == .downloading && e.state.run?.outstanding[transfer] == claims
                    && claimsElsewhere.allSatisfy { e.state.jobs[$0.key]?.state == .downloading && e.state.run?.outstanding[$0.key] == $0.value }
            }
        }
        let oID = o.identifier
        let k = Task { await engine.awaitAsset(oID, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[transfer]?.interests.count == 2 }
        return OwedRun(s: s, bulk: bulk, seed: seed, o: o, k: k, moved: moved, sync: sync)
    }

    /// The report of a run's outcome.
    static func report(of outcome: SyncOutcome) -> SyncReport? {
        switch outcome {
        case .completeWithFailures(let report), .complete(let report):
            report
        default:
            nil
        }
    }

    // MARK: rr21-T18 and T18-partial: a run's owed claims

    /// rr21-T18 (rr21-B29's bulk release and its nil-when-empty write) and T18-partial at site 1: the run's claims on
    /// zz-a1…zz-a3 (and, `partial`, zz-o) converge on O, which publishes, held at its first store unit; K0 maps the three
    /// to X's content (held), and O's commit owes their re-routes. Visited first, the commit re-routed the run's claims
    /// to X at once, and the run settled once X was fetched. Owed, the claims leave O's at the owing (nothing names O,
    /// whose job is gone); the run does not settle while the batch waits, and the replay claims X.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a run's claims whose re-routes a commit owes leave the job and settle the run only once the replay claims the new one (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, [false, true])
    func owedRunClaimsSettleTheRunAfterTheReplay(_ visit: LaneDropVisit, _ partial: Bool) async throws {
        let seed: UInt64 = partial ? 2_027_811 : 2_027_801
        let r = try await Self.stageOwedRun(seed: seed, partial: partial)
        let engine = r.engine
        let o = r.transfer
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let onX = r.moved.map { EngineFixture.entry($0.identifier.rawValue, xBytes) }
        let x = onX[0].transferID
        await r.s.harness.source.script(x, [.hold, .stage(xBytes)])
        let (units, releaser) = try await Self.holdPublications(of: [o], r.s, bulk: r.bulk)
        var held = HeldUnits(bulk: r.bulk, kept: units, releaser: releaser)
        try await Self.applyHeld(r.manifest(onX, round: 1), tag: "k0-run-\(seed)", r.s, visit: visit)
        await engine.readForTests { $0.holdDrainFollowUps() }
        await held.release(units[0])
        await engine.awaitCondition { $0.state.jobs[o] == nil }
        let owed = await engine.readForTests { e in (batches: Self.owedBatches(e).map { $0.items.elements.map(\.kind) }, onO: e.state.run?.outstanding[o]) }
        try #require(owed.batches == [[.run, .run, .run]], "setup: O's commit owes the run's three re-routes as one batch: \(owed.batches)")
        #expect(owed.onO == nil, "the owing releases the run's claims on O, and no empty claim names it: \(String(describing: owed.onO))")
        let a1 = r.moved[0].identifier
        let inject = await engine.violations { $0.run?.outstanding[o, default: []].insert(a1) }
        #expect(inject.sorted() == ["the run claims \(a1) on \(o), which a re-route owes", "the run claims \(o), whose job does not hold its interest"].sorted(), "the run clause reports a claim a re-route owes: \(inject)")
        let turns = try await Self.releaseRunTurns(engine)
        let claimsOnX = await engine.readForTests { $0.state.run?.outstanding[x].map { $0.map(\.rawValue).sorted() } }
        #expect(claimsOnX == ["zz-a1", "zz-a2", "zz-a3"], "the replay claims X for the run (visit-first): \(String(describing: claimsOnX))")
        #expect(!turns.settledEarly, "the run does not settle while its re-routes are owed")
        await r.s.harness.source.release(x, with: .progress(received: 0, expected: nil))
        await held.stop()
        let outcome = await EngineRegressionCycle6Tests.driving([r.s.time], fence: engine) { await EngineHarness.value(of: r.sync) }
        let k = await EngineRegressionCycle6Tests.driving([r.s.time], fence: engine) { await EngineHarness.value(of: r.k) }
        let report = Self.report(of: outcome)
        #expect(report?.fetched == (partial ? 4 : 3) && report?.failures.isEmpty == true, "the run fetches its claims, zz-a1…zz-a3 with X's content (visit-first): \(outcome)")
        #expect(Self.sizes([k]) == [16], "K gets O's bytes: \(k)")
        #expect(turns.violations.isEmpty, "\(turns.violations.prefix(3))")
        await Self.finishHeld(r.s)
    }

    // MARK: RR21-RUN-MIDDRAIN: the run's other verdict in the owed batch's drain batch

    /// RR21-RUN-MIDDRAIN (`checkRunSettled`'s `reroutesWaiting == 0`): the run also claims zz-y on Y's content, which
    /// downloads; K0 maps zz-a1…zz-a3 to X's content (held), Y's attempt gets a 404, and O's commit then owes the run's
    /// re-routes. Swept first, the queue holds only Y's verdict (V) and the batch (B), which one drain turn takes off
    /// it, so the barrier reads down mid-drain: V's verdict answers the run for Y, and the run is checked with B's claims
    /// on no job. Visited first, Y's 404 was given at once and the commit re-routed the claims to X: the run settled once
    /// X was fetched, zz-y failed. The state, V and B alone in the queue, arises only swept first (ruling S3-R26 item
    /// 12's answer 1: the `#require` on the queue).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a run whose other job's verdict replays in the owed batch's drain turn settles only after the batch (F-28, RR21-RUN-MIDDRAIN)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func runSettlesOnlyAfterTheOwedBatchItsVerdictDrainsWith(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_821
        let yBytes = EngineFixture.bytes(seed + 6, count: 22)
        let y = EngineFixture.entry("zz-y", yBytes)
        let yT = y.transferID
        let r = try await Self.stageOwedRun(seed: seed, partial: false, extra: [y], scripts: [yT: [.hold, .fail(.permanentMissing(httpStatus: 404))]], claimsElsewhere: [yT: [y.identifier]])
        let engine = r.engine
        let o = r.transfer
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let onX = r.moved.map { EngineFixture.entry($0.identifier.rawValue, xBytes) }
        let x = onX[0].transferID
        await r.s.harness.source.script(x, [.hold, .stage(xBytes)])
        let (units, releaser) = try await Self.holdPublications(of: [o], r.s, bulk: r.bulk)
        var held = HeldUnits(bulk: r.bulk, kept: units, releaser: releaser)
        try await Self.applyHeld(r.manifest(onX + [y], round: 1), tag: "k0-run-middrain-\(seed)", r.s, visit: visit)
        await r.s.harness.source.release(yT, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[yT] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[yT] == nil }
        }
        await engine.readForTests { $0.holdDrainFollowUps() }
        await held.release(units[0])
        await engine.awaitCondition { $0.state.jobs[o] == nil }
        let queue = await engine.readForTests { e in
            e.state.eventsAfterFollow.map { event -> String in
                switch event {
                case .attemptFailed(let transfer, _, _):
                    return transfer == yT ? "V" : "another verdict"
                case .reroutes(let batch):
                    return batch.from == o ? "B" : "another batch"
                default:
                    return "another event"
                }
            }
        }
        try #require(queue == (visit == .sweepFollowsFirst ? ["V", "B"] : ["B"]), "setup: swept first the queue holds V and B alone; visited first Y's verdict was given: \(queue)")
        let turns = try await Self.releaseRunTurns(engine)
        let claimsOnX = await engine.readForTests { $0.state.run?.outstanding[x].map { $0.map(\.rawValue).sorted() } }
        #expect(claimsOnX == ["zz-a1", "zz-a2", "zz-a3"], "the replay claims X for the run (visit-first): \(String(describing: claimsOnX))")
        #expect(!turns.settledEarly, "the run does not settle while its re-routes are owed")
        await r.s.harness.source.release(x, with: .progress(received: 0, expected: nil))
        await held.stop()
        let outcome = await EngineRegressionCycle6Tests.driving([r.s.time], fence: engine) { await EngineHarness.value(of: r.sync) }
        let report = Self.report(of: outcome)
        #expect(report?.fetched == 3, "the run fetches zz-a1…zz-a3 with X's content (visit-first): \(outcome)")
        #expect(report?.failures.map(\.id) == [y.identifier] && report?.failures.first?.error == .notFound, "the run fails zz-y with Y's 404: \(outcome)")
        #expect(turns.violations.isEmpty, "\(turns.violations.prefix(3))")
        await Self.finishHeld(r.s)
    }

    /// Releases the follow's and the drain's held turns one at a time until no follow is owed and no event waits, then
    /// lets later turns run; returns the invariant violations read after each turn, and whether the run of the owing
    /// instant settled, or ended, while a re-route it owes still waited (`reroutesWaiting`).
    @available(macOS 15.0, iOS 18.0, *)
    static func releaseRunTurns(_ engine: SyncEngine) async throws -> (violations: [String], settledEarly: Bool) {
        let run = try #require(await engine.readForTests { $0.state.run?.token }, "setup: the run is in progress at the owing")
        var violations: [String] = []
        var settledEarly = false
        while await engine.readForTests({ $0.followOwed || !$0.state.eventsAfterFollow.isEmpty }) {
            _ = await Self.runOneHeldTurn(engine)
            violations += await engine.invariantViolations()
            if await engine.readForTests({ $0.state.reroutesWaiting > 0 && ($0.state.run?.token != run || $0.state.run?.settlement != nil) }) {
                settledEarly = true
            }
        }
        await engine.readForTests { e in
            e.releaseDrainFollowUps()
            e.releaseFollowFollowUps()
        }
        return (violations, settledEarly)
    }
}
