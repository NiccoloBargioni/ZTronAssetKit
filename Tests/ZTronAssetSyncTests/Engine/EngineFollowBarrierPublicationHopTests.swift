import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// An interest one apply moves onto a publishing job's content and the next moves on, both while a follow is owed
/// (Stage 3 close-out cycle 18; the cycle-17 verifiers' PROBE-C17R-RR14-PUBLICATION-HOP and
/// PROBE-C17C-RR14-PUBLICATION-HOP, the WP-F draft's RR-14). A visit-first engine's visit at the first apply joined the
/// interest to the publication, the second apply's visit passed the job publishing, and the publication's outcome
/// answered the interest. Behind the barrier the owed visit came after the second apply and compared with its copy, so
/// the interest skipped the publication. Each case runs in both orders (`LaneDropVisit`) with the visit-first outcome
/// expected in both.
extension EngineFollowBarrierTests {
    /// The sizes of `publicationHop`'s two contents (the two verifiers' probes).
    enum PublicationHopShape: Sendable, CaseIterable {
        /// The publisher is 16 bytes and the holder 100 kB (PROBE-C17R-RR14-PUBLICATION-HOP, seed 1_717_002).
        case smallPublisher
        /// The publisher is 100 kB and the holder 50 kB (PROBE-C17C-RR14-PUBLICATION-HOP, seed 1_717_302).
        case largePublisher

        /// The scenario's seed.
        var seed: UInt64 {
            switch self {
            case .smallPublisher:
                return 1_717_002
            case .largePublisher:
                return 1_717_302
            }
        }

        /// The publisher's and the holder's sizes.
        var sizes: (publisher: Int, holder: Int) {
            switch self {
            case .smallPublisher:
                return (16, 100_000)
            case .largePublisher:
                return (100_000, 50_000)
            }
        }
    }

    /// P (zz-p; a user waiter Q) publishes bytes that fail their checksum, held at its first store unit, and H (zz-x; a
    /// user waiter W) downloads. v3 moves zz-x onto P's content and v4 moves it on to Z (48 B), both while P's publication
    /// is held; then the publication fails its integrity check. Visited first, v3's visit superseded H and joined W to P's
    /// publication, v4's visit passed P (its publication began before the apply), and P's integrity failure answered Q and
    /// W; Z never started. Returns the answers of Q and W and Z's starts.
    @available(macOS 15.0, iOS 18.0, *)
    func publicationHop(_ visit: LaneDropVisit, _ shape: PublicationHopShape) async throws -> (q: Result<AssetLocation, AssetError>, w: Result<AssetLocation, AssetError>, zStarts: Int) {
        let seed = shape.seed
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let pBytes = EngineFixture.bytes(seed + 3, count: shape.sizes.publisher)
        let wrongBytes = EngineFixture.bytes(seed + 4, count: shape.sizes.publisher)
        let hBytes = EngineFixture.bytes(seed + 5, count: shape.sizes.holder)
        let zBytes = EngineFixture.bytes(seed + 7, count: 48)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        let x = EngineHarness.onDemand("zz-x", hBytes)
        let xToP = EngineHarness.onDemand("zz-x", pBytes)
        let xToZ = EngineHarness.onDemand("zz-x", zBytes)
        try #require(xToP.transferID == p.transferID && x.transferID != p.transferID && xToZ.transferID != p.transferID && xToZ.transferID != x.transferID && wrongBytes != pBytes, "setup: three contents, v3's zz-x on P's")
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [p, x] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(p.transferID, [.hold, .stage(wrongBytes)])
        await s.harness.source.script(x.transferID, [.hold, .stage(hBytes)])
        await s.harness.source.script(xToZ.transferID, [.stage(zBytes)])
        let qWaiter = Task { await engine.awaitAsset(p.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[p.transferID]?.state == .downloading }
        }
        let wWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[x.transferID]?.state == .downloading }
        }
        // P's (bad) bytes arrive and its publication begins, held at its first store unit, before either apply.
        let releaser = try await Self.holdPublication(of: p.transferID, s, bulk: bulk)
        // v3 moves zz-x onto P's content.
        try await Self.applyHeld([s.q] + fillers + [p, xToP] + later, tag: "v3-pubhop-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            let atV3 = await engine.readForTests { e in (owed: e.followOwed, h: e.state.jobs[x.transferID]?.state) }
            try #require(atV3.owed && atV3.h == .downloading, "setup: v3's follow still owes H's visit: \(atV3)")
        }
        // v4 moves zz-x on to Z while P's publication is still held.
        try await Self.applyHeld([s.q] + fillers + [p, xToZ] + later, tag: "v4-pubhop-\(seed)", s, visit: visit)
        // P's publication resumes and fails its integrity check.
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[p.transferID] != nil || $0.state.jobs[p.transferID] == nil }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        } else {
            await engine.awaitCondition { $0.state.jobs[p.transferID] == nil }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let qResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: qWaiter) }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        let zStarts = await s.harness.source.starts.filter { $0.id == xToZ.transferID }.count
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return (qResult, wResult, zStarts)
    }

    /// An interest an apply moves onto a publishing job's content gets that publication's outcome, though the next apply
    /// moves its id on before the follow visits its old job (`publicationHop`): visited first, W was on P's publication
    /// when it failed its integrity check.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: an interest an apply moves onto a publishing content gets the publication's outcome, though the next apply moves it on (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, PublicationHopShape.allCases)
    func barrierGivesAnInterestMovedOntoAPublicationItsOutcome(_ visit: LaneDropVisit, _ shape: PublicationHopShape) async throws {
        let outcome = try await self.publicationHop(visit, shape)
        #expect(outcome.q == .failure(.integrityFailure), "Q gets P's integrity failure (visit-first): \(outcome.q)")
        #expect(outcome.w == .failure(.integrityFailure), "v3's visit joined W to P's publication and v4's visit passed it, so P's integrity failure answers W (visit-first): \(outcome.w); Z started \(outcome.zStarts) times")
    }
}
