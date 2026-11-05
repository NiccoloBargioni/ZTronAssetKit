import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The owners of owed re-routes (Stage 3 close-out cycle 21, ruling S3-R26 item 1; `integrate-rr21.md`'s
/// tests_and_mutants): a 429 is decided on a lane that counts an owed re-route whose owner still waits and whose replay
/// brings its id to the job (rr21-T12), a purge withdraws the owed non-user re-routes of purged ids (rr21-T13), a
/// cancelled waiter and a released group are passed at the replay (rr21-T15), and shutdown ends a batch midway
/// (rr21-T16). Each test runs in both orders (`LaneDropVisit`), on `stageOwedCommit`'s engine, and expects the
/// visit-first answers in both.
extension EngineFollowBarrierTests {
    // MARK: rr21-T12: a 429 while re-routes are owed

    /// What Y's 429 meets in `throttleWhileOwed`.
    enum OwedThrottle: String, Sendable, CaseIterable {
        /// W1…W3's re-routes bring zz-a1…zz-a3 to Y (rr21-T12 (a)).
        case userTarget
        /// K1 maps the ids to Z's content before the 429 (rr21-T12 (a), an apply between).
        case movedOn
        /// W1…W3 were cancelled behind the barrier: their records wait, without continuations, for their removals
        /// (rr21-T12 (b)).
        case cancelled
        /// K0 dropped the ids and K1 lists them on Y's content (rr21-T12 (c), T21).
        case dropped
        /// K0 maps the ids onto Y's content, whose blob the store holds as zz-d's: the replay answers them present
        /// (rr21-T12 (d)).
        case present
        /// A user-lane group of zz-o and the ids, released behind the barrier (rr21-T12's group variant).
        case released
    }

    /// `throttleWhileOwed`'s outcome: whether the 429 throttled the origin when it arrived, P's answer, and the rest.
    struct OwedThrottleOutcome {
        let throttled: Bool
        let p: Result<AssetLocation, AssetError>
        let layer: LayerOutcome
    }

    /// rr21-T12 at site 1: zz-y (P's, a prefetch waiter) is Y's content (24 bytes), which downloads; K0 maps zz-a1…zz-a3
    /// to it (unless `shape` says otherwise), O's commit owes their re-routes, and Y then gets a 429 with Retry-After
    /// 60 s, above the user lane's 30 s cap (`shortInteractiveRetry`) and below the background lane's. Visited first,
    /// the commit re-routed the interests at once: with a user interest on it, Y was user work at the 429, nothing was
    /// throttled, Y failed and its users were answered `serverUnavailable`; with none, the origin was throttled for 60 s,
    /// Y's retry served P, and a user waiter K1 moved to Z's content, of that origin too, was answered at once.
    @available(macOS 15.0, iOS 18.0, *)
    func throttleWhileOwed(_ visit: LaneDropVisit, seed: UInt64, shape: OwedThrottle) async throws -> OwedThrottleOutcome {
        let yBytes = EngineFixture.bytes(seed + 5, count: 24)
        let zBytes = EngineFixture.bytes(seed + 6, count: 20)
        // `.present`: zz-y is a JPEG of the bytes zz-d holds as a PNG, so the store has no blob of its key and Y downloads
        // it (`AssetStore.adoptKnownBlob` adopts by `BlobKey`, the hash and the extension), while the moved ids, PNGs,
        // are bound to that content at K0 (`ApplyReport.reused`).
        let y = shape == .present ? EngineFixture.entry("zz-y", yBytes, policy: .onDemand, ext: "jpg") : EngineHarness.onDemand("zz-y", yBytes)
        let d = EngineHarness.onDemand("zz-d", yBytes)
        let extra = shape == .present ? [y, d] : [y]
        let tuning = SyncTuning(interactiveRetry: Self.shortInteractiveRetry)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, extra: extra, wanters: shape == .released ? .group : .waiters, groupLane: .userInitiated, tuning: tuning)
        let engine = c.engine
        let yT = y.transferID
        if shape == .present {
            await c.s.harness.source.script(yT, [.stage(yBytes)])
            let dID = d.identifier
            let present = await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) { await engine.awaitAsset(dID, lane: .userInitiated) }
            try #require((try? present.get())?.byteSize == 24, "setup: zz-d is present: \(present)")
        }
        await c.s.harness.source.script(yT, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(yBytes)])
        let p = await Self.downloadingWaiter(y, c, lane: .prefetch)
        let onY = Self.movedOnto(yBytes, c)
        let onZ = Self.movedOnto(zBytes, c)
        await c.s.harness.source.script(onZ[0].transferID, [.stage(zBytes)])
        let k0 = shape == .dropped ? extra : extra + onY
        let held = try await Self.oweThroughK0(c, k0: k0, visit: visit)
        switch shape {
        case .userTarget, .present:
            break
        case .movedOn:
            try await Self.applyBehindBatch(c.manifest(extra + onZ, round: 2), tag: "k1-moved-on-\(seed)", c)
        case .dropped:
            try await Self.applyBehindBatch(c.manifest(extra + onY, round: 2), tag: "k1-relisted-\(seed)", c)
        case .cancelled:
            for waiter in c.w {
                waiter.cancel()
                let answer = await waiter.value
                #expect(answer == .failure(.cancelled), "a cancelled waiter is answered at once (R-SYN-4): \(answer)")
            }
            let removals = await engine.readForTests { e in
                e.state.eventsAfterFollow.filter { event in
                    if case .removal = event {
                        return true
                    }
                    return false
                }.count
            }
            try #require(removals == 3, "setup: the three removals wait behind the batch: \(removals)")
        case .released:
            let group = try #require(c.group)
            await engine.releaseGroup(group)
        }
        await c.s.harness.source.release(yT, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[yT]?.state != .downloading }
        let throttled = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } != nil }
        let layer = await Self.finishOwed(c, held: held, others: [p])
        await Self.finishHeld(c.s)
        return OwedThrottleOutcome(throttled: throttled, p: layer.others[0], layer: layer)
    }

    /// rr21-T12 at site 1, each shape in both orders: an owed re-route counts toward the lane Y's 429 is decided on only
    /// while its owner waits for it and its replay joins it to Y (`followedLane`'s `reaches`).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 while re-routes are owed is decided on the lane their replay gives the job (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, OwedThrottle.allCases)
    func owedReroutesDecideA429sLane(_ visit: LaneDropVisit, _ shape: OwedThrottle) async throws {
        let seeds: [OwedThrottle: UInt64] = [.userTarget: 2_027_601, .movedOn: 2_027_611, .cancelled: 2_027_621, .dropped: 2_027_631, .present: 2_027_641, .released: 2_027_651]
        let outcome = try await self.throttleWhileOwed(visit, seed: seeds[shape] ?? 2_027_601, shape: shape)
        let w = outcome.layer.w
        #expect(Self.sizes([outcome.layer.k]) == [16], "K gets O's bytes: \(outcome.layer.k)")
        #expect(outcome.layer.violations.isEmpty, "\(outcome.layer.violations.prefix(3))")
        switch shape {
        case .userTarget:
            #expect(!outcome.throttled, "W1…W3's re-routes make Y user work: the 429 beyond the user lane's cap throttles nothing (visit-first)")
            for answer in [outcome.p] + w {
                if case .failure(.serverUnavailable) = answer {
                } else {
                    Issue.record("P and W1…W3 are answered serverUnavailable (visit-first): \(answer)")
                }
            }
        case .movedOn:
            #expect(outcome.throttled, "K1 moved the ids to Z's content: Y is prefetch work (visit-first)")
            #expect(Self.sizes([outcome.p]) == [24], "Y's retry serves P: \(outcome.p)")
            for answer in w {
                if case .failure(.serverUnavailable) = answer {
                } else {
                    Issue.record("W1…W3, on Z behind the throttled origin, are answered serverUnavailable at once (visit-first): \(answer)")
                }
            }
        case .cancelled:
            #expect(outcome.throttled, "a cancelled waiter's re-route counts for nothing: Y is prefetch work (visit-first)")
            #expect(Self.sizes([outcome.p]) == [24] && w.allSatisfy { $0 == .failure(.cancelled) }, "Y's retry serves P: \(outcome.p), W \(w)")
        case .dropped:
            #expect(outcome.throttled, "the owing instant's copy dropped the ids: their re-routes end (T21) and Y is prefetch work (visit-first)")
            #expect(Self.sizes([outcome.p]) == [24] && w.allSatisfy { $0 == .failure(.notFound) }, "Y's retry serves P, and W1…W3 get .notFound: P \(outcome.p), W \(w)")
        case .present:
            #expect(outcome.throttled, "the ids are present at Y's content: their replay answers them from the store and Y is prefetch work (visit-first)")
            #expect(Self.sizes([outcome.p]) == [24] && Self.sizes(w) == [24, 24, 24], "Y's retry serves P, and the store W1…W3: P \(outcome.p), W \(w)")
        case .released:
            #expect(outcome.throttled, "a released group's re-routes count for nothing: Y is prefetch work (visit-first)")
            #expect(Self.sizes([outcome.p]) == [24], "Y's retry serves P: \(outcome.p)")
        }
    }

    // MARK: rr21-T13: a purge while re-routes are owed

    /// rr21-T13 and T13-nonpurged at site 1 (`withdrawPurgedJoins`' `.reroutes` arm): zz-a1…zz-a3 have a user waiter
    /// each and are members of a prefetch group, and zz-a1 heals; K0 maps them to X's content, O's commit owes their
    /// seven re-routes, and a purge of zz-a1 and zz-a2 arrives before the replay. Visited first, the commit re-routed the
    /// seven interests to X at once, and the purge withdrew the non-user ones of the purged ids from X: the group stopped
    /// waiting for zz-a1 and zz-a2, the heal was forgotten, and the user waiters kept theirs. The purge withdraws the
    /// owed ones alike, at the purge: the batch keeps W1…W3's and the group's zz-a3, which the replay re-routes to X.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: a purge while re-routes are owed withdraws the owed non-user re-routes of purged ids (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func purgeWithdrawsOwedNonUserReroutesOfPurgedIDs(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_701
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, wanters: .waitersAndGroup)
        let engine = c.engine
        let o = c.transfer
        let ids = c.ids
        let group = try #require(c.group)
        await engine.readForTests { $0.scheduleHeal(ids[0], at: $0.environment.time.monotonicNow()) }
        await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[o]?.interests.values.contains { $0.kind == .system } == true }
        }
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let onX = Self.movedOnto(xBytes, c)
        let x = onX[0].transferID
        await c.s.harness.source.script(x, [.hold, .stage(xBytes)])
        let held = try await Self.oweThroughK0(c, k0: onX, items: 7, visit: visit)
        let purged = await engine.purge(.scope(.identifiers([ids[0], ids[1]])))
        #expect((try? purged.get()) != nil, "setup: the purge completes: \(purged)")
        let atPurge = await engine.readForTests { e in
            (
                items: Self.owedBatches(e).flatMap { $0.items.elements.map { "\($0.asset.rawValue) \($0.kind)" } }.sorted(),
                pending: e.state.groups[group]?.pending.keys.map(\.rawValue).sorted() ?? [],
                heal: e.state.heals[ids[0]] == nil
            )
        }
        #expect(atPurge.items == ["zz-a1 waiter", "zz-a2 waiter", "zz-a3 prefetch", "zz-a3 waiter"], "the purge withdraws the group's and the heal's owed re-routes of zz-a1 and zz-a2 (visit-first): \(atPurge.items)")
        #expect(atPurge.pending == ["zz-a3"], "the group stops waiting for zz-a1 and zz-a2 (visit-first): \(atPurge.pending)")
        #expect(atPurge.heal, "the heal of zz-a1 is forgotten (visit-first)")
        let turns = await Self.releaseOwedTurns(c)
        let onXJob = await engine.readForTests { e in
            e.state.jobs[x].map { job in job.interests.values.map { "\($0.kind) \($0.assets.map(\.rawValue).sorted())" }.sorted() } ?? []
        }
        #expect(onXJob == ["prefetch [\"zz-a3\"]", "waiter [\"zz-a1\"]", "waiter [\"zz-a2\"]", "waiter [\"zz-a3\"]"], "the replay brings W1…W3 and the group's zz-a3 to X, and no interest of a purged id but the waiters' (visit-first): \(onXJob)")
        await c.s.harness.source.release(x, with: .progress(received: 0, expected: nil))
        await held.stop()
        let answers = await Self.owedAnswers(c)
        #expect(Self.sizes([answers.k]) == [16] && Self.sizes(answers.w) == [18, 18, 18], "K gets O's bytes, and W1…W3 X's (visit-first): \(answers)")
        let after = await engine.readForTests { e in (pending: e.state.groups[group]?.pending.keys.map(\.rawValue).sorted() ?? [], heal: e.state.heals[ids[0]] == nil) }
        #expect(after.pending.isEmpty && after.heal, "X served the group's zz-a3, and no heal came back: \(after.pending)")
        #expect(turns.violations.isEmpty, "\(turns.violations.prefix(3))")
        await Self.finishHeld(c.s)
    }

    // MARK: rr21-T15: a cancel and a release while re-routes are owed

    /// rr21-T15 at site 1: zz-a1…zz-a3 have a user waiter each and are members of a prefetch group; K0 maps them to X's
    /// content (held), O's commit owes their six re-routes, then W1 is cancelled and the group released before the
    /// replay. Visited first, the commit re-routed the six to X at once; W1's cancel removed its interest from X and the
    /// release the group's. The cancel answers W1 at once; its removal waits behind the batch and removes the interest
    /// the replay re-joined; the replay passes the released group (`reroute`'s guard), so X holds W2 and W3 alone.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a cancel and a release while re-routes are owed leave nothing of theirs on the replay's job (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func cancelAndReleaseWhileReroutesAreOwed(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_711
        let c = try await Self.stageOwedCommit(seed: seed, moved: 3, wanters: .waitersAndGroup)
        let engine = c.engine
        let group = try #require(c.group)
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let onX = Self.movedOnto(xBytes, c)
        let x = onX[0].transferID
        await c.s.harness.source.script(x, [.hold, .stage(xBytes)])
        let held = try await Self.oweThroughK0(c, k0: onX, items: 6, visit: visit)
        c.w[0].cancel()
        let w1 = await c.w[0].value
        #expect(w1 == .failure(.cancelled), "W1's caller is answered at once (R-SYN-4): \(w1)")
        await engine.releaseGroup(group)
        let turns = await Self.releaseOwedTurns(c)
        let onXJob = await engine.readForTests { e in
            e.state.jobs[x].map { job in job.interests.values.map { "\($0.kind) \($0.assets.map(\.rawValue).sorted())" }.sorted() } ?? []
        }
        #expect(onXJob == ["waiter [\"zz-a2\"]", "waiter [\"zz-a3\"]"], "X holds W2 and W3 alone (visit-first): \(onXJob)")
        await c.s.harness.source.release(x, with: .progress(received: 0, expected: nil))
        await held.stop()
        let answers = await Self.owedAnswers(c)
        #expect(Self.sizes([answers.k]) == [16] && Self.sizes(Array(answers.w.dropFirst())) == [18, 18], "K gets O's bytes, and W2 and W3 X's: \(answers)")
        #expect(answers.w.first == .failure(.cancelled), "W1 keeps its cancellation: \(answers.w)")
        #expect(turns.violations.isEmpty, "\(turns.violations.prefix(3))")
        await Self.finishHeld(c.s)
    }

    // MARK: rr21-T16: shutdown midway through a batch

    /// rr21-T16 at site 1 (`drainEverything`'s zeroing of `reroutesWaiting`): zz-a1…zz-a8 have a user waiter each; K0
    /// maps them to X's content, X downloads for V (held), and O's commit owes their eight re-routes; X's download ends,
    /// so its publication waits for them (`inboundBlocks`); the first turn that replays the batch re-routes some of the
    /// ids, and shutdown begins with the rest owed. Every waiter is answered `.shutDown`, X's publication is resumed, and nothing of
    /// the barrier is left.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: shutdown while re-routes are owed ends their batch and answers every waiter (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func shutdownMidwayThroughAnOwedBatch(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_721
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 8, extra: [x])
        let engine = c.engine
        let xT = x.transferID
        await c.s.harness.source.script(xT, [.hold, .stage(xBytes)])
        let v = await Self.downloadingWaiter(x, c)
        let held = try await Self.oweThroughK0(c, k0: [x] + Self.movedOnto(xBytes, c), visit: visit)
        await c.s.harness.source.release(xT, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[xT]?.state == .verifying && $0.state.inboundWaits[xT] != nil }
        var left = 8
        while left == 8 {
            _ = await Self.runOneHeldTurn(engine)
            left = await engine.readForTests { e in Self.owedBatches(e).first?.items.count ?? 0 }
        }
        try #require(left > 0, "setup: a turn re-routed some of the eight ids and the rest stay owed: \(left) owed")
        let shutdown = Task { await engine.shutdown() }
        let answers = await Self.owedAnswers(c)
        let others = await Self.answers(of: [v], c)
        await shutdown.value
        await held.stop()
        let after = await engine.readForTests { e in (events: e.state.eventsAfterFollow.count, waiting: e.state.reroutesWaiting, waits: e.state.inboundWaits.count) }
        #expect(Self.sizes([answers.k]) == [16], "K got O's bytes at its commit: \(answers.k)")
        #expect((answers.w + others).allSatisfy { $0 == .failure(.shutDown) }, "every waiter is answered .shutDown: \(answers.w), V \(others)")
        #expect(after.events == 0 && after.waiting == 0 && after.waits == 0, "no event, counted batch or publication wait is left: \(after)")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
    }
}
