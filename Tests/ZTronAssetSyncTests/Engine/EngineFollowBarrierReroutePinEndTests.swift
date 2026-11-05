import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// `PROBE-RR21-PIN-END` (Stage 3 close-out cycle 21, ruling S3-R26 item 12's answer 6.3): an owed re-route pinned to a
/// job that left its attempt's end before the replay, with another apply between that end and the replay. Each runs in
/// both orders (`LaneDropVisit`) and expects the visit-first answers in both.
extension EngineFollowBarrierTests {
    /// What `pinEnd` read once the follow and the drain were over.
    struct PinEndOutcome: CustomStringConvertible {
        let layer: LayerOutcome
        /// U's answer (zz-w, W's own id), `nil` in a shape without W, and V's (zz-x, X's).
        let u: Result<AssetLocation, AssetError>?
        let v: Result<AssetLocation, AssetError>
        /// Z's starts.
        let zStarts: Int

        var description: String {
            "\(self.layer); U \(self.u.map { "\($0)" } ?? "none"), V \(self.v), Z's starts \(self.zStarts)"
        }
    }

    /// When `pinEnd` applies K2, which maps zz-a1…zz-a3 to Z's content: never, while W publishes, or while W still
    /// downloads (its download released once the drain is over).
    enum PinEndLater {
        case none
        case whilePublishing
        case whileDownloading
    }

    /// zz-x (V's) is X's content and zz-w (U's) W's; both download. X publishes, held at its first store unit, while O
    /// does; K0 maps zz-a1…zz-a3 to X's content, O's commit owes their re-routes, K1 maps them to W's content while X
    /// still publishes, and X commits, before the replay. W's publication then begins (and waits: a re-route is owed),
    /// unless K2 comes while W downloads (`later`). W's bytes fail their check. Visited first, the commit re-routed
    /// W1…W3 onto X publishing, K1's visit passed X, and X's commit re-routed them under K1's copy to W's job; K2's
    /// visit passed W publishing (RR-14), so W's failure answered them, or moved them off W downloading to Z's job.
    @available(macOS 15.0, iOS 18.0, *)
    func pinEnd(_ visit: LaneDropVisit, seed: UInt64, later: PinEndLater) async throws -> PinEndOutcome {
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let wBytes = EngineFixture.bytes(seed + 6, count: 20)
        let zBytes = EngineFixture.bytes(seed + 7, count: 24)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let wEntry = EngineHarness.onDemand("zz-w", wBytes)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [x, wEntry])
        let engine = c.engine
        let xT = x.transferID
        let wT = wEntry.transferID
        let onX = Self.movedOnto(xBytes, c)
        let onW = Self.movedOnto(wBytes, c)
        let onZ = Self.movedOnto(zBytes, c)
        let z = onZ[0].transferID
        var corrupt = wBytes
        corrupt[0] ^= 0xFF
        await c.s.harness.source.script(xT, [.hold, .stage(xBytes)])
        await c.s.harness.source.script(wT, [.hold, .stage(corrupt)])
        await c.s.harness.source.script(z, [.stage(zBytes)])
        let v = await Self.downloadingWaiter(x, c)
        let u = await Self.downloadingWaiter(wEntry, c)
        var held = try await Self.oweThroughK0(c, k0: [x, wEntry] + onX, publishing: [xT], visit: visit)
        try await Self.applyBehindBatch(c.manifest([x, wEntry] + onW, round: 2), tag: "k1-pin-end-\(seed)", c)
        #expect(await Self.pins(xT, c) == [true], "setup: K1's layer pins X, which publishes")
        await held.release(held.kept[0])
        await engine.awaitCondition { $0.state.jobs[xT] == nil }
        if later != .whileDownloading {
            await c.s.harness.source.release(wT, with: .progress(received: 0, expected: nil))
            await engine.awaitCondition { $0.state.jobs[wT]?.state == .verifying && $0.state.inboundWaits[wT] != nil }
        }
        if later != .none {
            try await Self.applyBehindBatch(c.manifest([x, wEntry] + onZ, round: 3), tag: "k2-pin-end-\(seed)", c)
            #expect(await Self.pins(wT, c) == [false, later == .whilePublishing], "setup: K2's layer pins W only while W publishes")
        }
        let layer = await Self.finishOwed(c, held: held, others: [u, v], releasing: later == .whileDownloading ? [wT] : [])
        let zStarts = await Self.starts(z, c)
        await Self.finishHeld(c.s)
        return PinEndOutcome(layer: layer, u: layer.others[0], v: layer.others[1], zStarts: zStarts)
    }

    /// zz-x (V's) is X's content, which downloads, then publishes, held at its first store unit, while O does; K0 maps
    /// zz-a1…zz-a3 to X's content, O's commit owes their re-routes, K1 drops them while X still publishes, X commits, and
    /// K2 lists them again on Z's content, all before the replay. Visited first, the commit re-routed W1…W3 onto X
    /// publishing, K1's visit passed X, and X's commit re-routed them under K1's copy, which does not list them (T21):
    /// each waiter got `.notFound`, and K2 found no interest to move.
    @available(macOS 15.0, iOS 18.0, *)
    func pinEndDropped(_ visit: LaneDropVisit, seed: UInt64) async throws -> PinEndOutcome {
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let zBytes = EngineFixture.bytes(seed + 7, count: 24)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [x])
        let engine = c.engine
        let xT = x.transferID
        let onX = Self.movedOnto(xBytes, c)
        let onZ = Self.movedOnto(zBytes, c)
        let z = onZ[0].transferID
        await c.s.harness.source.script(xT, [.hold, .stage(xBytes)])
        await c.s.harness.source.script(z, [.stage(zBytes)])
        let v = await Self.downloadingWaiter(x, c)
        var held = try await Self.oweThroughK0(c, k0: [x] + onX, publishing: [xT], visit: visit)
        try await Self.applyBehindBatch(c.manifest([x], round: 2), tag: "k1-pin-end-dropped-\(seed)", c)
        #expect(await Self.pins(xT, c) == [true], "setup: K1's layer pins X, which publishes")
        await held.release(held.kept[0])
        await engine.awaitCondition { $0.state.jobs[xT] == nil }
        try await Self.applyBehindBatch(c.manifest([x] + onZ, round: 3), tag: "k2-pin-end-dropped-\(seed)", c)
        let layer = await Self.finishOwed(c, held: held, others: [v])
        let zStarts = await Self.starts(z, c)
        await Self.finishHeld(c.s)
        return PinEndOutcome(layer: layer, u: nil, v: layer.others[0], zStarts: zStarts)
    }

    /// PROBE-RR21-PIN-END without a later apply (rr21-T8's class): X's commit is the last event before the replay, which
    /// follows the copy then (K1's) onto W's job, still publishing; W's failure answers W1…W3, as visited first.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed re-route whose pinned job committed follows the copy then onto a job that publishes and fails (F-28, RR-14)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedRerouteWhosePinCommittedJoinsTheNextPublishingJob(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.pinEnd(visit, seed: 2_027_481, later: .none)
        #expect(outcome.u == .failure(.integrityFailure) && outcome.w.allSatisfy { $0 == .failure(.integrityFailure) }, "U and W1…W3 get W's integrity failure (visit-first): \(outcome)")
        #expect(Self.sizes([outcome.layer.k, outcome.v]) == [16, 18] && outcome.zStarts == 0, "K gets O's bytes, V X's, and Z is never requested: \(outcome)")
        #expect(outcome.layer.violations.isEmpty, "\(outcome.layer.violations.prefix(3))")
    }

    /// PROBE-RR21-PIN-END with K2 between X's commit and the replay: visited first, X's commit had re-routed W1…W3 to
    /// W's job under K1's copy, and K2's visit passed W publishing, so W's failure answered them.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed re-route whose pinned job committed before a later apply follows the copy at that commit (F-28, RR-14, PROBE-RR21-PIN-END)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedRerouteWhosePinCommittedFollowsTheCopyAtThatCommit(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.pinEnd(visit, seed: 2_027_491, later: .whilePublishing)
        #expect(outcome.u == .failure(.integrityFailure) && outcome.w.allSatisfy { $0 == .failure(.integrityFailure) }, "U and W1…W3 get W's integrity failure (visit-first): \(outcome)")
        #expect(Self.sizes([outcome.layer.k, outcome.v]) == [16, 18] && outcome.zStarts == 0, "K gets O's bytes, V X's, and Z is never requested: \(outcome)")
        #expect(outcome.layer.violations.isEmpty, "\(outcome.layer.violations.prefix(3))")
    }

    /// PROBE-RR21-PIN-END with K2 while W still downloads: visited first, X's commit had re-routed W1…W3 to W's job
    /// under K1's copy, and K2's visit moved them to Z's job, which W1…W3's re-routes follow from the copy at that commit.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed re-route whose pinned job committed follows the applies after that commit from the copy then (F-28, PROBE-RR21-PIN-END)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedRerouteWhosePinCommittedFollowsTheAppliesAfterThatCommit(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.pinEnd(visit, seed: 2_027_521, later: .whileDownloading)
        #expect(outcome.u == .failure(.integrityFailure) && Self.sizes(outcome.w) == [24, 24, 24], "U gets W's integrity failure, W1…W3 Z's bytes (visit-first): \(outcome)")
        #expect(Self.sizes([outcome.layer.k, outcome.v]) == [16, 18] && outcome.zStarts == 1, "K gets O's bytes, V X's, and Z is requested once: \(outcome)")
        #expect(outcome.layer.violations.isEmpty, "\(outcome.layer.violations.prefix(3))")
    }

    /// PROBE-RR21-PIN-END's T21 shape: the copy at X's commit (K1's) does not list zz-a1…zz-a3, so, visited first, X's
    /// commit ended W1…W3's interests before K2 listed the ids again on Z's content.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed re-route whose pinned job committed under a copy that dropped its id ends its interest though a later apply lists it again (F-28, T21, PROBE-RR21-PIN-END)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedRerouteWhosePinCommittedEndsUnderTheCopyAtThatCommit(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.pinEndDropped(visit, seed: 2_027_501)
        #expect(outcome.w.allSatisfy { $0 == .failure(.notFound) }, "W1…W3 get .notFound (visit-first): \(outcome)")
        #expect(Self.sizes([outcome.layer.k, outcome.v]) == [16, 18] && outcome.zStarts == 0, "K gets O's bytes, V X's, and Z is never requested: \(outcome)")
        #expect(outcome.layer.violations.isEmpty, "\(outcome.layer.violations.prefix(3))")
    }

    /// `pinEndDropped`'s shape with a second batch: P's content (22 bytes) holds zz-p, with a user waiter R, and zz-b1 and
    /// zz-b2, with user waiters B1 and B2; P publishes, held, beside X. K0 maps zz-a1…zz-a3, zz-b1 and zz-b2 to X's
    /// content, so O's commit and then P's owe a batch each; K1 drops the five ids while X publishes, X commits, and K2
    /// lists them again on Z's content, all before the replay. Visited first, both commits re-routed their ids onto X
    /// publishing, K1's visit passed X, and X's commit ended the five interests under K1's copy (T21). The drain replays
    /// O's batch whole first: P's still follows X's commit.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a second owed batch whose pinned job committed follows the copy at that commit once the first is replayed whole (F-28, T21, PROBE-RR21-PIN-END)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func secondOwedBatchFollowsTheCommitOfItsPinAfterTheFirstBatch(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_541
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let pBytes = EngineFixture.bytes(seed + 6, count: 22)
        let zBytes = EngineFixture.bytes(seed + 7, count: 24)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        let bIDs = ["zz-b1", "zz-b2"]
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [x, p] + bIDs.map { EngineHarness.onDemand($0, pBytes) })
        let engine = c.engine
        let xT = x.transferID
        let pT = p.transferID
        let onZ = Self.movedOnto(zBytes, c) + bIDs.map { EngineHarness.onDemand($0, zBytes) }
        let z = onZ[0].transferID
        await c.s.harness.source.script(xT, [.hold, .stage(xBytes)])
        await c.s.harness.source.script(pT, [.hold, .stage(pBytes)])
        await c.s.harness.source.script(z, [.stage(zBytes)])
        let v = await Self.downloadingWaiter(x, c)
        var pWaiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for id in [p.identifier] + bIDs.map({ AssetID(rawValue: $0) }) {
            pWaiters.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
        }
        await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[pT]?.state == .downloading && $0.state.jobs[pT]?.interests.count == 3 }
        }
        let k0 = [x, p] + Self.movedOnto(xBytes, c) + bIDs.map { EngineHarness.onDemand($0, xBytes) }
        var held = try await Self.oweThroughK0(c, k0: k0, publishing: [xT, pT], visit: visit)
        await held.release(held.kept[1])
        await engine.awaitCondition { $0.state.jobs[pT] == nil }
        let owed = await engine.readForTests { e in Self.owedBatches(e).map(\.items.count) }
        try #require(owed == [3, 2], "setup: O's commit and then P's owe a batch each: \(owed)")
        try await Self.applyBehindBatch(c.manifest([x, p], round: 2), tag: "k1-two-batches-\(seed)", c)
        let pinned = await engine.readForTests { e in Self.owedBatches(e).map { batch in batch.layers.map { $0.ends[xT] != nil } } }
        #expect(pinned == [[true], [true]], "setup: K1's layer pins X, which publishes, on both batches: \(pinned)")
        await held.release(held.kept[0])
        await engine.awaitCondition { $0.state.jobs[xT] == nil }
        try await Self.applyBehindBatch(c.manifest([x, p] + onZ, round: 3), tag: "k2-two-batches-\(seed)", c)
        let layer = await Self.finishOwed(c, held: held, others: [v] + pWaiters)
        let zStarts = await Self.starts(z, c)
        await Self.finishHeld(c.s)
        #expect((layer.w + layer.others.suffix(2)).allSatisfy { $0 == .failure(.notFound) }, "W1…W3, B1 and B2 get .notFound (visit-first): \(layer)")
        #expect(Self.sizes([layer.k] + layer.others.prefix(2)) == [16, 18, 22] && zStarts == 0, "K, V and R get their contents' bytes, and Z is never requested: \(layer), Z's starts \(zStarts)")
        #expect(layer.violations.isEmpty, "\(layer.violations.prefix(3))")
    }

    /// What `stageKeptCommit` staged: the owed commit, the units still held (X's), V's waiter and X's attempt.
    @available(macOS 15.0, iOS 18.0, *)
    struct KeptCommit {
        let c: OwedCommit
        let held: HeldUnits
        let v: Task<Result<AssetLocation, AssetError>, Never>
        let key: VerdictKey
    }

    /// `pinEndDropped`'s shape visited first, up to K1's apply, whose layer pins X publishing: X's commit, once its unit
    /// is released, is kept for the batch (`EngineState.reroutePinCommits`).
    @available(macOS 15.0, iOS 18.0, *)
    func stageKeptCommit(seed: UInt64) async throws -> KeptCommit {
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [x])
        let xT = x.transferID
        await c.s.harness.source.script(xT, [.hold, .stage(xBytes)])
        let v = await Self.downloadingWaiter(x, c)
        let held = try await Self.oweThroughK0(c, k0: [x] + Self.movedOnto(xBytes, c), publishing: [xT], visit: .followVisitedFirst)
        try await Self.applyBehindBatch(c.manifest([x], round: 2), tag: "k1-pin-commits-\(seed)", c)
        let epoch = try #require(await c.engine.readForTests { $0.state.jobs[xT]?.epoch })
        return KeptCommit(c: c, held: held, v: v, key: VerdictKey(transfer: xT, epoch: epoch))
    }

    /// The commits an owed re-route's pin follows (`EngineState.reroutePinCommits`): X's commit, while K1's layer pins
    /// X, is kept with the copy's serial then until the drain replays the batch whole. Each clause, broken alone through
    /// the test seam (`violations(after:)`), reports its exact message.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: the invariants report a commit kept for owed re-routes at an attempt still at its end, ahead of the copy or with no batch waiting (F-28, PROBE-RR21-PIN-END)", .timeLimit(.minutes(3)))
    func invariantsReportCommitsKeptForOwedReroutes() async throws {
        let staged = try await self.stageKeptCommit(seed: 2_027_511)
        let c = staged.c
        let engine = c.engine
        let key = staged.key
        var held = staged.held
        let publishing = await engine.violations { $0.reroutePinCommits[key] = $0.copySerial }
        #expect(publishing == ["1 commits kept for owed re-routes name an attempt still at its end"], "a commit kept for X while X publishes: \(publishing)")
        await held.release(held.kept[0])
        await engine.awaitCondition { $0.state.jobs[key.transfer] == nil }
        let kept = await engine.readForTests { e in e.state.reroutePinCommits == [key: e.state.copySerial] }
        #expect(kept, "X's commit is kept with the copy's serial then")
        let clean = await engine.invariantViolations()
        #expect(clean.isEmpty, "\(clean.prefix(3))")
        let ahead = await engine.violations { $0.reroutePinCommits[key] = $0.copySerial &+ 1 }
        #expect(ahead == ["1 commits kept for owed re-routes name a copy not yet adopted"], "a commit kept at a copy no apply adopted: \(ahead)")
        let layer = await Self.finishOwed(c, held: held, others: [staged.v])
        #expect(layer.w.allSatisfy { $0 == .failure(.notFound) } && layer.violations.isEmpty, "W1…W3 follow K1's copy at X's commit: \(layer)")
        let forgotten = await engine.readForTests { $0.state.reroutesWaiting == 0 && $0.state.reroutePinCommits.isEmpty }
        #expect(forgotten, "the batch's last item forgets the commits")
        let idle = await engine.violations { $0.reroutePinCommits[key] = 0 }
        #expect(idle == ["1 commits are kept for owed re-routes, none waiting"], "a commit kept with no batch waiting: \(idle)")
        await Self.finishHeld(c.s)
    }

    /// A shutdown while the batch waits forgets X's kept commit with the batch (`shutdown`): the waiters are answered
    /// `.shutDown`, and no batch, publication wait or kept commit is left.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a shutdown while owed re-routes wait forgets the commits kept for them (F-28, PROBE-RR21-PIN-END)", .timeLimit(.minutes(3)))
    func shutdownForgetsTheCommitsKeptForOwedReroutes() async throws {
        let staged = try await self.stageKeptCommit(seed: 2_027_531)
        let c = staged.c
        let engine = c.engine
        let key = staged.key
        var held = staged.held
        await held.release(held.kept[0])
        await engine.awaitCondition { $0.state.jobs[key.transfer] == nil }
        let kept = await engine.readForTests { $0.state.reroutePinCommits.keys.contains(key) }
        try #require(kept, "setup: X's commit is kept for the batch")
        let shutdown = Task { await engine.shutdown() }
        let answers = await Self.owedAnswers(c)
        let others = await Self.answers(of: [staged.v], c)
        await shutdown.value
        await held.stop()
        let after = await engine.readForTests { e in (waiting: e.state.reroutesWaiting, waits: e.state.inboundWaits.count, kept: e.state.reroutePinCommits.count) }
        #expect(Self.sizes([answers.k] + others) == [16, 18] && answers.w.allSatisfy { $0 == .failure(.shutDown) }, "K and V got their bytes at their commits, W1…W3 .shutDown: \(answers), V \(others)")
        #expect(after.waiting == 0 && after.waits == 0 && after.kept == 0, "no counted batch, publication wait or kept commit is left: \(after)")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
    }
}

extension EngineFollowBarrierTests.PinEndOutcome {
    /// W1…W3's answers.
    var w: [Result<AssetLocation, AssetError>] {
        self.layer.w
    }
}
