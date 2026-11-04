import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// What a follow's moves leave on their holder (Stage 3 close-out cycle 21, ruling S3-R26 items 3 and 7;
/// `integrate-c21.md` item B, tests B-T4 and B-T5, and `analyse-state-cost.md` Q1): a bounded move takes the moved ids
/// no interest holds off the holder at its first turn, as a move that fits the turn takes them (`move`'s subtraction),
/// and a rest that takes an id off its holder at the id's first item puts it back after the id's last item when an
/// interest joined the holder in that id meanwhile, as a visit-first engine's join re-inserted it. Each runs in both
/// orders (`LaneDropVisit`), with the visit-first outcome expected in both.
extension EngineFollowBarrierTests {
    // MARK: B-T4: a bounded move's unheld ids

    /// W (a prefetch waiter) wants zz-w, and G (a prefetch group) zz-o1 … zz-o6, all on H's 16 bytes: one job,
    /// downloading (held). G is released while H downloads: its interest leaves H, whose ids keep the six (`dropInterest`
    /// leaves `Job.assets` alone). v3 maps the six to O's content; H's visit moves six ids at four a turn
    /// (`followIDsPerTurn`), so it takes the bounded path (`startMove`), whose items are the interests in the moved ids:
    /// none. A move that fits takes every moved id off the holder; the bounded one must too, or H keeps, after its visit,
    /// ids the copy maps elsewhere (the invariant on visited jobs).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a bounded move takes the moved ids no interest holds off the holder, as a move that fits the turn does (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierTakesABoundedMovesUnheldIDsOffTheHolder(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_021_401
        let (s, _) = try await FollowBarrier.setUp(seed: seed)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = 4 }
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let oBytes = EngineFixture.bytes(seed + 3, count: 24)
        let w = EngineHarness.onDemand("zz-w", hBytes)
        let names = (1...6).map { "zz-o\($0)" }
        let onH = names.map { EngineHarness.onDemand($0, hBytes) }
        let onO = names.map { EngineHarness.onDemand($0, oBytes) }
        let holder = w.transferID
        try #require(onH.allSatisfy { $0.transferID == holder } && onO.allSatisfy { $0.transferID != holder }, "setup: the six share H's content, and v3 maps them elsewhere")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [w] + onH + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(holder, [.hold, .stage(hBytes)])
        let wWaiter = Task { await engine.awaitAsset(w.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[holder]?.state == .downloading }
        }
        let g = try await engine.registerGroup(onH.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[holder]?.interests[g]?.assets.count == names.count }
        await engine.releaseGroup(g)
        let before = await engine.readForTests { e in (assets: e.state.jobs[holder]?.assets.count, interests: e.state.jobs[holder]?.interests.count, state: e.state.jobs[holder]?.state) }
        try #require(before.assets == 7 && before.interests == 1 && before.state == .downloading, "setup: G's interest left H, which keeps its seven ids and downloads: \(before)")
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [w] + onO + Self.laterFillers(seed + 6_000), tag: "v3-unheld-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            var turns = 0
            while await engine.readForTests({ $0.followOwed }) {
                try #require(turns < 8, "the follow ends within 8 turns")
                await Self.runOneFollowTurn(engine)
                turns += 1
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let after = await engine.readForTests { e in e.state.jobs[holder]?.assets }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "H's visit left none of the moved ids on it: \(violations.prefix(3))")
        #expect(after == [w.identifier], "H holds zz-w alone once its visit moved the six ids, as a move that fits the turn leaves it: \(after?.sorted() ?? [])")
        await s.harness.source.release(holder, with: .progress(received: 0, expected: nil))
        let result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        #expect((try? result.get())?.byteSize == 16, "W gets H's bytes: \(result)")
        await Self.finishHeld(s)
    }

    // MARK: B-T5 and its probes: an id a rest owes while an interest joins it (`analyse-state-cost.md` Q1)

    /// What follows the rest's last item in the Q1 construction.
    enum RestRejoinShape: String, Sendable, CaseIterable {
        /// T1 is released, then the rest takes (A, T1), and H's publication commits (B-T5, Q1's stage 1).
        case committed
        /// T1 is released, the rest takes (A, T1), H's publication fails with an I/O error (retried), C_z maps A to
        /// Z's content, and H's retry gets a 404 (Q1's stage 2).
        case failedThenMoved
        /// T1 is not released: C_y maps A to Y's content while H publishes, before the rest takes (A, T1), and H's
        /// publication fails its integrity check (Q1's stage 3, variant Y).
        case movedWhilePublishing
    }

    /// What `restRejoin` reads and the answers it gets.
    struct RestRejoinOutcome {
        /// H's ids once the follow ended and its publication reached the store.
        let hAssets: Set<AssetID>?
        /// The interests H holds in A then.
        let hHoldsA: Int
        /// The answers of T' (A's prefetch waiter), T1 (A's other waiter, `movedWhilePublishing` only) and T_D.
        let tPrime: Result<AssetLocation, AssetError>
        let t1: Result<AssetLocation, AssetError>?
        let tD: Result<AssetLocation, AssetError>
        /// The starts of H's content.
        let hStarts: Int
        /// The invariants once the follow ended.
        let violations: [String]
        /// The rest's state in sweep-first: H's ids once only (A, T1) is owed.
        let restLeft: Set<AssetID>?
    }

    /// The Q1 construction (`analyse-state-cost.md`, followIDsPerTurn = 4; the B's sort before A = zz-z):
    /// 1. P (12 B) holds A for T', a prefetch waiter, and publishes (held at its first store unit); H (16 B) holds
    ///    zz-b1 … zz-b8 for T_B (a prefetch group) and zz-d for T_D (a prefetch waiter), downloading (held). C1 maps A
    ///    to H's content; its follow passes P, publishing, and ends.
    /// 2. T1, A's second interest (a prefetch group; for `movedWhilePublishing` a prefetch waiter, whose answer the
    ///    test reads), joins H.
    /// 3. P's publication fails with an I/O error, no follow owed: P fails, keeping T', its verdict given.
    /// 4. C_v maps A and the B's to X's content (20 B, held), D stays: P's visit supersedes P (T' to X), and H's visit
    ///    owes a rest R, which moves four B's in its first turn (sweep-first).
    /// 5. C_w maps A back to H's content: R's next turn moves the other four B's and still owes (A, T1). With seven B's
    ///    (`analyse-state-cost.md`'s count) R's second turn would end it, re-routing T1 onto H under C_w.
    /// 6. H's download completes: its attempt's end brings T' from X onto H at once (`bringInbound`), and its
    ///    binding waits for R; visited first, X's visit at C_w had moved T' and T1 onto H, and the publication binds at
    ///    once. The publication's first store unit waits (the bulk executor holds).
    /// 7. T1 is released (or, for `movedWhilePublishing`, C_y maps A to Y's content).
    /// 8. R's last turn takes (A, T1): A leaves H's ids at its first item; T1 is gone (or re-routed under the copy).
    /// Visited first, R ended inside C_v's follow, so the state never arises: H binds A and D.
    @available(macOS 15.0, iOS 18.0, *)
    func restRejoin(_ visit: LaneDropVisit, shape: RestRejoinShape) async throws -> RestRejoinOutcome {
        let seed: UInt64 = 2_021_501
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = 4 }
        let pBytes = EngineFixture.bytes(seed + 3, count: 12)
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let xBytes = EngineFixture.bytes(seed + 5, count: 20)
        let yBytes = EngineFixture.bytes(seed + 6, count: 22)
        let zBytes = EngineFixture.bytes(seed + 7, count: 26)
        var wrongH = hBytes
        wrongH[0] ^= 0xFF
        let bNames = (1...8).map { "zz-b\($0)" }
        let aOnP = EngineHarness.onDemand("zz-z", pBytes)
        let aOnH = EngineHarness.onDemand("zz-z", hBytes)
        let aOnX = EngineHarness.onDemand("zz-z", xBytes)
        let aOnY = EngineHarness.onDemand("zz-z", yBytes)
        let aOnZ = EngineHarness.onDemand("zz-z", zBytes)
        let bOnH = bNames.map { EngineHarness.onDemand($0, hBytes) }
        let bOnX = bNames.map { EngineHarness.onDemand($0, xBytes) }
        let d = EngineHarness.onDemand("zz-d", hBytes)
        let a = aOnP.identifier
        let p = aOnP.transferID
        let h = d.transferID
        let x = aOnX.transferID
        try #require(Set([p, h, x, aOnY.transferID, aOnZ.transferID]).count == 5 && bOnH.allSatisfy { $0.transferID == h } && aOnH.transferID == h && bOnX.allSatisfy { $0.transferID == x }, "setup: five contents")
        func copy(_ fillers: UInt64, _ later: UInt64, a: ManifestEntry, b: [ManifestEntry]) -> [ManifestEntry] {
            [s.q] + FollowBarrier.fillers(seed + fillers) + b + [d, a] + Self.laterFillers(seed + later)
        }
        await s.harness.serveManifest(copy(100, 3_000, a: aOnP, b: bOnH), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(p, [.hold, .stage(pBytes)])
        switch shape {
        case .committed:
            // A second attempt, should the commit re-route T' to a fresh job of H's content.
            await s.harness.source.script(h, [.hold, .stage(hBytes), .stage(hBytes)])
        case .failedThenMoved:
            await s.harness.source.script(h, [.hold, .stage(hBytes), .fail(.permanentMissing(httpStatus: 404))])
        case .movedWhilePublishing:
            await s.harness.source.script(h, [.hold, .stage(wrongH), .stage(wrongH)])
        }
        await s.harness.source.script(x, [.hold])
        await s.harness.source.script(aOnY.transferID, [.stage(yBytes)])
        await s.harness.source.script(aOnZ.transferID, [.stage(zBytes)])
        // 1. T' wants A: P downloads (held); T_B and T_D want the B's and D: H downloads (held).
        let tPrime = Task { await engine.awaitAsset(a, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[p]?.state == .downloading }
        }
        let tB = try await engine.registerGroup(bOnH.map(\.identifier), lane: .prefetch).get()
        let tD = Task { await engine.awaitAsset(d.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[h]?.state == .downloading && $0.state.jobs[h]?.assets.count == 9 && $0.state.jobs[h]?.interests.count == 2 }
        }
        let releaser = try await Self.holdPublication(of: p, s, bulk: bulk)
        try await Self.applyHeld(copy(200, 6_000, a: aOnH, b: bOnH), tag: "c1-rest-rejoin-\(seed)", s, visit: .followVisitedFirst)
        let passed = await engine.readForTests { e in (state: e.state.jobs[p]?.state, unfollowed: e.state.unfollowed.contains(p), interests: e.state.jobs[p]?.interests.count) }
        try #require(passed.state == .verifying && passed.unfollowed && passed.interests == 1, "setup: C1's follow passed P, publishing, with T' on it: \(passed)")
        // 2. T1 joins H in A.
        var t1Group: InterestToken?
        var t1Waiter: Task<Result<AssetLocation, AssetError>, Never>?
        if shape == .movedWhilePublishing {
            t1Waiter = Task { await engine.awaitAsset(a, lane: .prefetch) }
        } else {
            t1Group = try await engine.registerGroup([a], lane: .prefetch).get()
        }
        await engine.awaitCondition { $0.state.jobs[h]?.assets.contains(a) == true && $0.state.jobs[h]?.interests.count == 3 }
        // 3. P's publication fails with an I/O error (no follow owed): P is retried later, T' on it.
        releaser.cancel()
        await releaser.value
        s.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .io))
        await bulk.setHolding(false)
        await engine.awaitCondition { e in
            if case .failed = e.state.jobs[p]?.state { return true }
            return false
        }
        let failed = await engine.readForTests { e in (deferred: e.state.jobs[p]?.attemptEnd?.deferredAfter, holds: e.state.jobs[p]?.assets.contains(a), barrier: e.followBarrier) }
        try #require(failed.deferred == nil && failed.holds == true && !failed.barrier, "setup: P failed with its verdict given, holding A: \(failed)")
        // 4. C_v maps A and the B's to X's content.
        try await Self.applyHeld(copy(300, 9_000, a: aOnX, b: bOnX), tag: "cv-rest-rejoin-\(seed)", s, visit: visit)
        var restLeft: Set<AssetID>?
        if visit == .sweepFollowsFirst {
            var turns = 0
            while await engine.readForTests({ $0.state.followMoving?.holder != h }) {
                try #require(turns < 8, "setup: H's visit owes a rest within 8 follow turns")
                await Self.runOneFollowTurn(engine)
                turns += 1
            }
            let rest = await engine.readForTests { e in (h: e.state.jobs[h]?.assets, p: e.state.jobs[p] != nil, x: e.state.jobs[x]?.interests.values.filter { $0.assets.contains(a) }.count) }
            try #require(rest.h?.contains(a) == true && !rest.p && rest.x == 1, "setup: P's visit superseded P (T' on X), and H's rest still owes A: \(rest)")
        }
        // 5. C_w maps A back to H's content: R moves the B's and still owes (A, T1).
        try await Self.applyHeld(copy(400, 12_000, a: aOnH, b: bOnX), tag: "cw-rest-rejoin-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            var turns = 0
            while await engine.readForTests({ ($0.state.jobs[h]?.assets.count ?? 0) > 2 }) {
                try #require(turns < 8, "setup: R moves the B's within 8 follow turns")
                await Self.runOneFollowTurn(engine)
                turns += 1
            }
            let left = await engine.readForTests { e in (h: e.state.jobs[h]?.assets, rest: e.state.followMoving?.holder == h) }
            restLeft = left.h
            try #require(left.h == [a, d.identifier] && left.rest, "setup: R moved every B and still owes (A, T1): \(left)")
        }
        // 6. H's download completes. Visited first, its publication binds at once and waits at its first store unit;
        //    swept first, its binding waits for R (`inboundBlocks`), and its first store unit waits once it binds.
        await engine.awaitCondition { !$0.state.storeWorkInFlight }
        await bulk.setHolding(true)
        await s.harness.source.release(h, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[h]?.state == .verifying }
        var hUnit: Int?
        if visit == .followVisitedFirst {
            try await bulk.requireHeldUnits(atLeast: 1)
            hUnit = await bulk.heldUnits.first
        }
        // 7. T1 is released, or C_y maps A to Y's content while H publishes (every store unit but H's runs).
        if let t1Group {
            await engine.releaseGroup(t1Group)
        } else {
            let others = Task {
                while !Task.isCancelled {
                    await bulk.waitForHeldUnits(atLeast: hUnit == nil ? 1 : 2)
                    for unit in await bulk.heldUnits where unit != hUnit {
                        await bulk.release(unit)
                    }
                }
            }
            try await Self.applyHeld(copy(500, 15_000, a: aOnY, b: bOnX), tag: "cy-rest-rejoin-\(seed)", s, visit: visit)
            others.cancel()
            await others.value
        }
        // 8. R's last turn, then the rest of the follow.
        if visit == .sweepFollowsFirst {
            var turns = 0
            while await engine.readForTests({ $0.followOwed }) {
                try #require(turns < 16, "the follow ends within 16 turns")
                await Self.runOneFollowTurn(engine)
                turns += 1
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        try await bulk.requireHeldUnits(atLeast: 1)
        let held = await engine.readForTests { e in
            (assets: e.state.jobs[h]?.assets, holdsA: e.state.jobs[h]?.interests.values.filter { $0.assets.contains(a) }.count ?? 0)
        }
        let violations = await engine.invariantViolations()
        switch shape {
        case .committed, .movedWhilePublishing:
            break
        case .failedThenMoved:
            // H's publication fails with an I/O error (retried later); C_z maps A to Z's content; H's retry gets a 404.
            s.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .io))
        }
        await bulk.setHolding(false)
        if shape == .failedThenMoved {
            await engine.awaitCondition { e in
                if case .failed = e.state.jobs[h]?.state { return true }
                return false
            }
            try await Self.applyHeld(copy(600, 18_000, a: aOnZ, b: bOnX), tag: "cz-rest-rejoin-\(seed)", s, visit: .followVisitedFirst)
        }
        let tPrimeResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: tPrime) }
        let tDResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: tD) }
        var t1Result: Result<AssetLocation, AssetError>?
        if let t1Waiter {
            t1Result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: t1Waiter) }
        }
        let hStarts = await s.harness.source.starts.filter { $0.id == h }.count
        await engine.releaseGroup(tB)
        await Self.finishHeld(s)
        return RestRejoinOutcome(hAssets: held.assets, hHoldsA: held.holdsA, tPrime: tPrimeResult, t1: t1Result, tD: tDResult, hStarts: hStarts, violations: violations, restLeft: restLeft)
    }

    /// B-T5 (Q1's stage 1): after the rest's last item, H's ids keep A, which T' holds on H, so H's publication binds it
    /// and answers T' from its one download, as visited first.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: an id a rest takes off its holder stays in the holder's ids while an interest that joined meanwhile holds it (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierKeepsARestsIDWhileAJoinedInterestHoldsIt(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.restRejoin(visit, shape: .committed)
        let a = AssetID("zz-z")
        let d = AssetID("zz-d")
        #expect(outcome.hAssets?.isSuperset(of: [a, d]) == true, "H's ids keep A, which T' holds on it, and D (visit-first): \(outcome.hAssets?.sorted() ?? []), \(outcome.hHoldsA) interests in A")
        #expect((try? outcome.tPrime.get())?.byteSize == 16, "T' is served H's bytes: \(outcome.tPrime)")
        #expect((try? outcome.tD.get())?.byteSize == 16, "T_D is served H's bytes: \(outcome.tD)")
        #expect(outcome.hStarts == 1, "H's content is downloaded once (visit-first): \(outcome.hStarts) starts")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
    }

    /// Q1's stage 2, a probe (ruling S3-R26 item 7): H's publication fails and is retried; C_z maps A to Z's content, and
    /// H's retry gets a 404. Visited first, C_z's visit moved A off the failed H (its ids hold A), so T' is served Z's
    /// bytes; a hidden A would stay on H and get its 404.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: an interest whose id a rest put back is moved by a later apply's visit off its failed holder (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierMovesARejoinedIDOffItsFailedHolder(_ visit: LaneDropVisit) async throws {
        let outcome = try await self.restRejoin(visit, shape: .failedThenMoved)
        #expect((try? outcome.tPrime.get())?.byteSize == 26, "T' is served Z's bytes, the content C_z maps A to (visit-first): \(outcome.tPrime)")
        #expect(outcome.tD == .failure(.notFound), "T_D gets H's retry's 404 (visit-first): \(outcome.tD)")
        #expect(outcome.violations.isEmpty, "\(outcome.violations.prefix(3))")
    }
}
