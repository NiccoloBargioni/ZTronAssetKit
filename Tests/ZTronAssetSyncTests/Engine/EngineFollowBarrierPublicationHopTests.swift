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
/// the interest skipped the publication. The second apply may also arrive through the store's catch-up
/// (`followStoreView`), whose walk is the apply's, or map the id back to its own content, whose publication then waits
/// for the move off its job (`inboundBlocks`). Each case runs in both orders (`LaneDropVisit`) with the visit-first
/// outcome expected in both.
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

    /// Where `publicationHop`'s v4 maps zz-x, and how the engine takes v4.
    enum PublicationHopNext: Sendable {
        /// On to Z, applied by the engine (`applyHeld`).
        case onward
        /// On to Z, applied by the store and followed by the engine's catch-up (`followStoreView`, the path after an
        /// `apply` that threw past its writes): its walk, under v3's copy, finds the move onto P's publication as an
        /// apply's does.
        case onwardCaughtUp
        /// Back to H's own content, applied by the engine; then H's bytes arrive while the move off H is owed. v3 also
        /// maps the ids of `publicationHopAhead` holders, created before H, onto P's content (v4 keeps them there), so
        /// the walk at v4 owes their moves before H's, and H's attempt's end, which makes the first `inboundMovesNow`,
        /// leaves the move off H owed.
        case back
        /// As `back`, with zz-h on H's content too (a user waiter V) in every manifest, so H keeps an id: its
        /// publication, waiting for the move off its job, binds zz-h once the follow's turn made that move, and serves V
        /// (Stage 3 close-out cycle 19; the cycle-18 requirements verifier's RE-S48 liveness finding: a holder's wait that
        /// the move's end did not resume stayed until shutdown).
        case backKeeping
    }

    /// The holders `publicationHop`'s `.back` creates ahead of H: more than an attempt's end makes at once.
    static let publicationHopAhead = SyncEngine.inboundMovesNow + 8

    /// Applies `entries` through the store and has the engine follow the store's view as its catch-up does
    /// (`followStoreView`), with the follow's follow-up turns held, and in `.followVisitedFirst` lets the follow end
    /// (`applyHeld`'s counterpart for the catch-up's path).
    @available(macOS 15.0, iOS 18.0, *)
    static func followStoreHeld(_ entries: [ManifestEntry], tag: String, _ s: FollowBarrier.Setup, visit: LaneDropVisit) async throws {
        let engine = s.engine
        let manifest = try ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data(tag.utf8)))
        await engine.readForTests { $0.holdFollowFollowUps() }
        _ = try await s.harness.store.apply(manifest, etag: nil, eviction: nil)
        let view = try await s.harness.view()
        let followed = await engine.readForTests { e in
            (followed: e.followStoreView(view, readAt: e.state.copySerial), digest: e.state.applied.digest)
        }
        try #require(followed.followed && followed.digest == manifest.digest, "setup: the engine follows the store's \(tag): \(followed)")
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        } else {
            let owed = await engine.readForTests { $0.followOwed }
            #expect(owed, "setup: the follow owes its visits")
        }
    }

    /// P (zz-p; a user waiter Q) publishes bytes that fail their checksum, held at its first store unit, and H (zz-x; a
    /// user waiter W) downloads. v3 moves zz-x onto P's content and v4 moves it on to Z (48 B), both while P's publication
    /// is held; then the publication fails its integrity check. Visited first, v3's visit superseded H and joined W to P's
    /// publication, v4's visit passed P (its publication began before the apply), and P's integrity failure answered Q and
    /// W; Z never started. With `next` `.back`, v4 maps zz-x back to H's content and H's bytes arrive before P's
    /// publication resumes: visited first, v3's visits had moved W and the holders ahead (zz-g0000…, 16 bytes each, a
    /// prefetch waiter each) onto P and superseded H. Five transfer slots, two reserved for user work, so H downloads
    /// beside P and three of the holders. Returns the answers of Q, W and the holders ahead, Z's starts, and V's answer
    /// with `next` `.backKeeping`.
    @available(macOS 15.0, iOS 18.0, *)
    func publicationHop(_ visit: LaneDropVisit, _ shape: PublicationHopShape, next: PublicationHopNext = .onward) async throws -> (q: Result<AssetLocation, AssetError>, w: Result<AssetLocation, AssetError>, ahead: [Result<AssetLocation, AssetError>], zStarts: Int, v: Result<AssetLocation, AssetError>?) {
        let seed = shape.seed
        let back = next == .back || next == .backKeeping
        let keeps = next == .backKeeping
        let tuning = back ? SyncTuning(maxConcurrentTransfers: 5, reservedInteractiveSlots: 2) : SyncTuning()
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed, tuning: tuning)
        let engine = s.engine
        let pBytes = EngineFixture.bytes(seed + 3, count: shape.sizes.publisher)
        let wrongBytes = EngineFixture.bytes(seed + 4, count: shape.sizes.publisher)
        let hBytes = EngineFixture.bytes(seed + 5, count: shape.sizes.holder)
        let zBytes = EngineFixture.bytes(seed + 7, count: 48)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        let x = EngineHarness.onDemand("zz-x", hBytes)
        let kept = keeps ? [EngineHarness.onDemand("zz-h", hBytes)] : []
        let xToP = EngineHarness.onDemand("zz-x", pBytes)
        let xToZ = EngineHarness.onDemand("zz-x", zBytes)
        try #require(xToP.transferID == p.transferID && x.transferID != p.transferID && xToZ.transferID != p.transferID && xToZ.transferID != x.transferID && wrongBytes != pBytes, "setup: three contents, v3's zz-x on P's")
        let aheadNames = (0..<(back ? Self.publicationHopAhead : 0)).map { String(format: "zz-g%04d", $0) }
        let aheadOwn = aheadNames.enumerated().map { EngineHarness.onDemand($0.element, EngineFixture.bytes(seed + 10_000 + UInt64($0.offset), count: 16)) }
        let aheadOnP = aheadNames.map { EngineHarness.onDemand($0, pBytes) }
        let aheadTransfers = aheadOwn.map(\.transferID)
        try #require(Set(aheadTransfers).count == aheadNames.count && !aheadTransfers.contains(p.transferID) && !aheadTransfers.contains(x.transferID), "setup: the holders ahead have contents of their own")
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [p, x] + kept + aheadOwn + Self.laterFillers(seed + 3_000), etag: "v2")
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
        // The holders ahead are created before H, so their moves come first (`findInbound` takes holders by `Job.epoch`).
        var aheadWaiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for holder in aheadOwn {
            let id = holder.identifier
            aheadWaiters.append(Task { await engine.awaitAsset(id, lane: .prefetch) })
        }
        await engine.awaitCondition { e in aheadTransfers.allSatisfy { e.state.jobs[$0]?.interests.isEmpty == false } }
        let wWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[x.transferID]?.state == .downloading }
        }
        var vWaiter: Task<Result<AssetLocation, AssetError>, Never>?
        if let h = kept.first {
            let id = h.identifier
            vWaiter = Task { await engine.awaitAsset(id, lane: .userInitiated) }
            await engine.awaitCondition { $0.state.jobs[x.transferID]?.interests.count == 2 }
        }
        // P's (bad) bytes arrive and its publication begins, held at its first store unit, before either apply.
        let releaser = try await Self.holdPublication(of: p.transferID, s, bulk: bulk)
        // v3 moves zz-x onto P's content.
        try await Self.applyHeld([s.q] + fillers + [p, xToP] + kept + aheadOnP + later, tag: "v3-pubhop-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            let atV3 = await engine.readForTests { e in (owed: e.followOwed, h: e.state.jobs[x.transferID]?.state) }
            try #require(atV3.owed && atV3.h == .downloading, "setup: v3's follow still owes H's visit: \(atV3)")
        }
        // v4 moves zz-x on to Z (or back to H's content) while P's publication is still held.
        switch next {
        case .onward:
            try await Self.applyHeld([s.q] + fillers + [p, xToZ] + later, tag: "v4-pubhop-\(seed)", s, visit: visit)
        case .onwardCaughtUp:
            try await Self.followStoreHeld([s.q] + fillers + [p, xToZ] + later, tag: "v4-pubhop-store-\(seed)", s, visit: visit)
        case .back, .backKeeping:
            try await Self.applyHeld([s.q] + fillers + [p, x] + kept + aheadOnP + later, tag: "v4-pubhop-back-\(seed)", s, visit: visit)
            if visit == .sweepFollowsFirst {
                let owedOff = await engine.readForTests { e in
                    e.state.inboundMoves[e.state.inboundNext...].firstIndex { $0.holder == x.transferID && $0.target == p.transferID }.map { $0 - e.state.inboundNext }
                }
                try #require(owedOff.map { $0 >= SyncEngine.inboundMovesNow } == true, "setup: v4's apply found the move of zz-x off H onto P's publication, owed behind \(SyncEngine.inboundMovesNow) others at least: \(String(describing: owedOff))")
            }
            // H's bytes arrive. Its attempt's end makes the first moves; behind the barrier its publication then waits for
            // the move off its job, still owed (under v4's copy it binds zz-x). Visited first, H was superseded at v3's
            // visit.
            await s.harness.source.release(x.transferID, with: .progress(received: 0, expected: nil))
            await engine.awaitCondition { $0.state.inboundWaits[x.transferID] != nil || $0.state.jobs[x.transferID] == nil }
        }
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
        if back {
            // Every move off H was made, so no publication still waits for one (`inboundMade`).
            let waits = await engine.readForTests { $0.state.inboundWaits.count }
            try #require(waits == 0, "no publication still waits once the follow ended: \(waits)")
        }
        let qResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: qWaiter) }
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        var aheadResults: [Result<AssetLocation, AssetError>] = []
        for waiter in aheadWaiters {
            aheadResults.append(await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        var vResult: Result<AssetLocation, AssetError>?
        if let vWaiter {
            vResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: vWaiter) }
        }
        let zStarts = await s.harness.source.starts.filter { $0.id == xToZ.transferID }.count
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return (qResult, wResult, aheadResults, zStarts, vResult)
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

    /// The same, v4 reaching the engine through the store's catch-up (`publicationHop(_:_:next: .onwardCaughtUp)`): the
    /// catch-up's follow walks the publications in flight under the outgoing copy as the apply's does
    /// (`followStoreView`).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: an interest moved onto a publishing content gets the publication's outcome, though a catch-up follows the next manifest (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, PublicationHopShape.allCases)
    func barrierGivesAnInterestMovedOntoAPublicationItsOutcomeThroughACatchUp(_ visit: LaneDropVisit, _ shape: PublicationHopShape) async throws {
        let outcome = try await self.publicationHop(visit, shape, next: .onwardCaughtUp)
        #expect(outcome.q == .failure(.integrityFailure), "Q gets P's integrity failure (visit-first): \(outcome.q)")
        #expect(outcome.w == .failure(.integrityFailure), "v3's visit joined W to P's publication and v4's visit passed it, so P's integrity failure answers W (visit-first): \(outcome.w); Z started \(outcome.zStarts) times")
    }

    /// An interest an apply moves onto a publishing job's content gets that publication's outcome, though the next apply
    /// maps its id back to its own content and its own job's bytes arrive first (`publicationHop(_:_:next: .back)`):
    /// visited first, v3's visits had moved W and the holders ahead onto P's publication and superseded H. Behind the
    /// barrier, H's publication waits for the move off its job (`inboundBlocks`), which its attempt's end left owed;
    /// binding at once, it served W H's bytes.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: an interest moved onto a publishing content and mapped back gets the publication's outcome, not its old job's bytes (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, PublicationHopShape.allCases)
    func barrierGivesAnInterestMappedBackOffAPublicationItsOutcome(_ visit: LaneDropVisit, _ shape: PublicationHopShape) async throws {
        let outcome = try await self.publicationHop(visit, shape, next: .back)
        #expect(outcome.q == .failure(.integrityFailure), "Q gets P's integrity failure (visit-first): \(outcome.q)")
        #expect(outcome.w == .failure(.integrityFailure), "v3's visit moved W onto P's publication and superseded H, so P's integrity failure answers W, not H's bytes (visit-first): \(outcome.w)")
        let wrong = outcome.ahead.enumerated().filter { $0.element != .failure(.integrityFailure) }
        #expect(outcome.ahead.count == Self.publicationHopAhead && wrong.isEmpty, "P's integrity failure answers every holder ahead (visit-first); \(wrong.count) do not, the first \(wrong.prefix(3).map { "zz-g\($0.offset): \($0.element)" })")
    }

    /// The same with zz-h on H's content too (`publicationHop(_:_:next: .backKeeping)`): H's publication waits for the
    /// move off its job and binds zz-h once the follow's turn made it, serving V, as a visit-first engine's H, which v3's
    /// visit left holding zz-h, published it; W and the holders ahead get P's integrity failure.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: a publication that waits for a move off its job binds the id it keeps once the move is made (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, PublicationHopShape.allCases)
    func barrierBindsTheIDAPublicationKeepsOnceTheMoveOffItsJobIsMade(_ visit: LaneDropVisit, _ shape: PublicationHopShape) async throws {
        let outcome = try await self.publicationHop(visit, shape, next: .backKeeping)
        #expect(outcome.q == .failure(.integrityFailure), "Q gets P's integrity failure (visit-first): \(outcome.q)")
        #expect(outcome.w == .failure(.integrityFailure), "v3's visit moved W onto P's publication, so P's integrity failure answers W (visit-first): \(outcome.w)")
        #expect(outcome.v.flatMap { try? $0.get() }?.byteSize == Int64(shape.sizes.holder), "H's publication binds zz-h and serves V (visit-first): \(String(describing: outcome.v))")
        let wrong = outcome.ahead.enumerated().filter { $0.element != .failure(.integrityFailure) }
        #expect(outcome.ahead.count == Self.publicationHopAhead && wrong.isEmpty, "P's integrity failure answers every holder ahead (visit-first); \(wrong.count) do not")
    }
}
