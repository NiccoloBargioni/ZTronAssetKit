import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// e1-PS (Stage 3 close-out cycle 22, ruling S3-R27 item 12.2; e1's supersede row): `pinEnd`'s shape with X's own
/// publication superseded before the replay, then a later apply. K1 maps zz-a1…zz-a3 to W's content and zz-x off X's
/// content, to X2's (26 bytes), while X publishes, so the store's records no longer want X's bytes for zz-x and the store
/// refuses X's publication (`.superseded`). A visit-first engine re-routes at a supersede under the copy then, as at a
/// commit: O's commit had re-routed W1…W3 onto X publishing, K1's visit passed X (RR-14), and X's supersede re-routed
/// them under K1's copy to W's job, and V's zz-x to X2's. Each test runs in both orders and expects the visit-first
/// answers in both.
extension EngineFollowBarrierTests {
    /// The later applies of `pinSuperseded`: K2 maps zz-a1…zz-a3 to Z's content while W publishes (`whilePublishing`),
    /// or drops them while W still downloads, and K3 lists them again on Z's content (`droppedThenListed`).
    enum PinSupersededLater: Sendable {
        case whilePublishing
        case droppedThenListed
    }

    /// zz-x (V's) is X's content and zz-w (U's) W's; both download. X publishes, held at its first store unit, while O
    /// does; K0 maps zz-a1…zz-a3 to X's content, O's commit owes their re-routes, and K1 (above) supersedes X's
    /// publication before the replay. With `whilePublishing`, W's bytes fail their check: visited first, K2's visit
    /// passed W publishing (RR-14), so W's failure answered U and W1…W3. With `droppedThenListed`, W's bytes are good:
    /// visited first, K2's visit moved W1…W3 off W downloading under K2's copy, which does not list them (T21), so each
    /// got `.notFound`, and K3 found no interest to move.
    @available(macOS 15.0, iOS 18.0, *)
    func pinSuperseded(_ visit: LaneDropVisit, seed: UInt64, later: PinSupersededLater) async throws -> PinEndOutcome {
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let wBytes = EngineFixture.bytes(seed + 6, count: 20)
        let zBytes = EngineFixture.bytes(seed + 7, count: 24)
        let x2Bytes = EngineFixture.bytes(seed + 9, count: 26)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let x2 = EngineHarness.onDemand("zz-x", x2Bytes)
        let wEntry = EngineHarness.onDemand("zz-w", wBytes)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: [x, wEntry])
        let engine = c.engine
        let xT = x.transferID
        let wT = wEntry.transferID
        let onX = Self.movedOnto(xBytes, c)
        let onW = Self.movedOnto(wBytes, c)
        let onZ = Self.movedOnto(zBytes, c)
        let z = onZ[0].transferID
        try #require(Set([xT, x2.transferID, wT, z]).count == 4, "setup: X, X2, W and Z are four contents")
        var staged = wBytes
        if later == .whilePublishing {
            staged[0] ^= 0xFF
        }
        await c.s.harness.source.script(xT, [.hold, .stage(xBytes)])
        await c.s.harness.source.script(wT, [.hold, .stage(staged)])
        await c.s.harness.source.script(z, [.stage(zBytes)])
        await c.s.harness.source.script(x2.transferID, [.stage(x2Bytes)])
        let v = await Self.downloadingWaiter(x, c)
        let u = await Self.downloadingWaiter(wEntry, c)
        var held = try await Self.oweThroughK0(c, k0: [x, wEntry] + onX, publishing: [xT], visit: visit)
        try await Self.applyBehindBatch(c.manifest([x2, wEntry] + onW, round: 2), tag: "k1-pin-superseded-\(seed)", c)
        #expect(await Self.pins(xT, c) == [true], "setup: K1's layer pins X, which publishes")
        await held.release(held.kept[0])
        await engine.awaitCondition { $0.state.jobs[xT] == nil }
        let bound = await engine.readForTests { $0.state.boundContent.values.contains(xT) }
        try #require(!bound, "setup: the store refused X's publication, which bound nothing")
        switch later {
        case .whilePublishing:
            await c.s.harness.source.release(wT, with: .progress(received: 0, expected: nil))
            await engine.awaitCondition { $0.state.jobs[wT]?.state == .verifying && $0.state.inboundWaits[wT] != nil }
            try await Self.applyBehindBatch(c.manifest([x2, wEntry] + onZ, round: 3), tag: "k2-pin-superseded-\(seed)", c)
            #expect(await Self.pins(wT, c) == [false, true], "setup: K2's layer pins W, which publishes")
        case .droppedThenListed:
            try await Self.applyBehindBatch(c.manifest([x2, wEntry], round: 3), tag: "k2-pin-superseded-\(seed)", c)
            try await Self.applyBehindBatch(c.manifest([x2, wEntry] + onZ, round: 4), tag: "k3-pin-superseded-\(seed)", c)
            #expect(await Self.pins(wT, c) == [false, false, false], "setup: no layer pins W, which downloads")
        }
        let layer = await Self.finishOwed(c, held: held, others: [u, v], releasing: later == .droppedThenListed ? [wT] : [])
        let zStarts = await Self.starts(z, c)
        await Self.finishHeld(c.s)
        return PinEndOutcome(layer: layer, u: layer.others[0], v: layer.others[1], zStarts: zStarts)
    }

    /// e1-PS (i): K2 maps zz-a1…zz-a3 to Z's content while W publishes, and W's bytes fail their check. Visited first,
    /// X's supersede re-routed W1…W3 to W's job under K1's copy, and K2's visit passed W publishing, so W's failure
    /// answered them.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed re-route pinned to a job whose publication was superseded follows the copy at the supersede onto a job that publishes and fails (F-28, RR-14, T22, e1-PS)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedReroutePinnedToASupersededJobFollowsTheCopyAtTheSupersede(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.pinSuperseded(visit, seed: 2_027_561, later: .whilePublishing)
        #expect(outcome.u == .failure(.integrityFailure) && outcome.w.allSatisfy { $0 == .failure(.integrityFailure) }, "U and W1…W3 get W's integrity failure (visit-first): \(outcome)")
        #expect(Self.sizes([outcome.layer.k, outcome.v]) == [16, 26] && outcome.zStarts == 0, "K gets O's bytes, V X2's, and Z is never requested: \(outcome)")
        #expect(outcome.layer.violations.isEmpty, "\(outcome.layer.violations.prefix(3))")
    }

    /// e1-PS (ii): K2 drops zz-a1…zz-a3 while W downloads, and K3 lists them again on Z's content. Visited first, X's
    /// supersede re-routed W1…W3 to W's job under K1's copy, K2's visit ended their interests (T21), and K3 found none
    /// to move.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed re-route pinned to a job whose publication was superseded ends at a later apply's drop though a later one lists it again (F-28, T21, T22, e1-PS)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedReroutePinnedToASupersededJobEndsAtALaterDrop(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.pinSuperseded(visit, seed: 2_027_571, later: .droppedThenListed)
        #expect(outcome.w.allSatisfy { $0 == .failure(.notFound) }, "W1…W3 get .notFound (visit-first): \(outcome)")
        #expect(Self.sizes([outcome.layer.k, outcome.v] + (outcome.u.map { [$0] } ?? [])) == [16, 26, 20] && outcome.zStarts == 0, "K gets O's bytes, V X2's, U W's, and Z is never requested: \(outcome)")
        #expect(outcome.layer.violations.isEmpty, "\(outcome.layer.violations.prefix(3))")
    }
}
