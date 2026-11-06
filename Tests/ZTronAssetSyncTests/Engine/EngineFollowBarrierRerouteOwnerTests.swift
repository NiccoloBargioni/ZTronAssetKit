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

    /// Who wants the moved ids in rr21-T13 (`purgeWithdrawsOwedNonUserReroutesOfPurgedIDs`).
    enum OwedPurgeWanters: String, Sendable, CaseIterable {
        /// rr21-T13 as cycle 21 built it: a user waiter each, a prefetch group of zz-o and the ids, and a heal of zz-a1.
        case waitersAndGroup
        /// A user-lane group of zz-o and the ids, and no waiter (b23-no-lane's state; d4 §3.3): a purge keeps a user-lane
        /// interest, as the job arm does.
        case userGroup
        /// A prefetch-lane waiter each, and no group (b23-no-kind's state; d4 §3.3): a purge keeps a waiter on any lane.
        case prefetchWaiters
    }

    /// rr21-T13 and T13-nonpurged at site 1 (`withdrawPurgedJoins`' `.reroutes` arm): zz-a1…zz-a3 are wanted as `wanters`
    /// says; K0 maps them to X's content, O's commit owes their re-routes, and a purge of zz-a1 and zz-a2 arrives before
    /// the replay. Visited first, the commit re-routed the interests to X at once, and the purge withdrew the non-user
    /// ones of the purged ids from X (`interest.lane < .userInitiated && interest.kind != .waiter`): the prefetch group
    /// stopped waiting for zz-a1 and zz-a2 and the heal was forgotten, while the user waiters, the user-lane group and
    /// the prefetch-lane waiters kept theirs. The purge withdraws the owed ones alike, at the purge, and the replay
    /// re-routes the rest to X. `.userGroup`: the group's ids are stored at X's content, so a later request for each is
    /// answered from the store (X's later attempts would get a 404 each). `.prefetchWaiters`: the batch's items are required,
    /// so that b23-no-kind, which leaves W1 and W2 on no job and in no batch, ends the test instead of hanging it; their
    /// tasks are leaked then, by design.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: a purge while re-routes are owed withdraws the owed non-user re-routes of purged ids (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, OwedPurgeWanters.allCases)
    func purgeWithdrawsOwedNonUserReroutesOfPurgedIDs(_ visit: LaneDropVisit, _ wanters: OwedPurgeWanters) async throws {
        let seed: UInt64 = 2_027_701
        let c: OwedCommit
        switch wanters {
        case .waitersAndGroup:
            c = try await Self.stageOwedCommit(seed: seed, moved: 3, wanters: .waitersAndGroup)
        case .userGroup:
            c = try await Self.stageOwedCommit(seed: seed, moved: 3, wanters: .group, groupLane: .userInitiated)
        case .prefetchWaiters:
            c = try await Self.stageOwedCommit(seed: seed, moved: 3, wanters: .waiters, lane: .prefetch)
        }
        let engine = c.engine
        let o = c.transfer
        let ids = c.ids
        if wanters != .prefetchWaiters {
            _ = try #require(c.group, "setup: the group is registered")
        }
        if wanters == .waitersAndGroup {
            await engine.readForTests { $0.scheduleHeal(ids[0], at: $0.environment.time.monotonicNow()) }
            await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[o]?.interests.values.contains { $0.kind == .system } == true }
            }
        }
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let onX = Self.movedOnto(xBytes, c)
        let x = onX[0].transferID
        // `.userGroup`: a later request that finds its id not stored starts X's content again, and gets a 404 (one for each
        // of the three ids), so that it is answered, not left on an attempt the script does not give.
        let missing = Array(repeating: FakeTransferStep.fail(.permanentMissing(httpStatus: 404)), count: 3)
        await c.s.harness.source.script(x, wanters == .userGroup ? [.hold, .stage(xBytes)] + missing : [.hold, .stage(xBytes)])
        let held = try await Self.oweThroughK0(c, k0: onX, items: wanters == .waitersAndGroup ? 7 : 3, visit: visit)
        let purged = await engine.purge(.scope(.identifiers([ids[0], ids[1]])))
        #expect((try? purged.get()) != nil, "setup: the purge completes: \(purged)")
        let atPurge = await engine.readForTests { e in
            (
                items: Self.owedBatches(e).flatMap { $0.items.elements.map { "\($0.asset.rawValue) \($0.kind)" } }.sorted(),
                pending: c.group.flatMap { e.state.groups[$0]?.pending.keys.map(\.rawValue).sorted() } ?? [],
                heal: e.state.heals[ids[0]] == nil
            )
        }
        switch wanters {
        case .waitersAndGroup:
            #expect(atPurge.items == ["zz-a1 waiter", "zz-a2 waiter", "zz-a3 prefetch", "zz-a3 waiter"], "the purge withdraws the group's and the heal's owed re-routes of zz-a1 and zz-a2 (visit-first): \(atPurge.items)")
            #expect(atPurge.pending == ["zz-a3"], "the group stops waiting for zz-a1 and zz-a2 (visit-first): \(atPurge.pending)")
            #expect(atPurge.heal, "the heal of zz-a1 is forgotten (visit-first)")
        case .userGroup:
            #expect(atPurge.items == ["zz-a1 prefetch", "zz-a2 prefetch", "zz-a3 prefetch"], "the purge keeps the user-lane group's owed re-routes (visit-first): \(atPurge.items)")
            #expect(atPurge.pending == ["zz-a1", "zz-a2", "zz-a3"], "the user-lane group still waits for every moved id (visit-first): \(atPurge.pending)")
        case .prefetchWaiters:
            try #require(atPurge.items == ["zz-a1 waiter", "zz-a2 waiter", "zz-a3 waiter"], "the purge keeps the prefetch-lane waiters' owed re-routes (visit-first): \(atPurge.items)")
        }
        let turns = await Self.releaseOwedTurns(c)
        let replayed = await engine.readForTests { e in
            (
                onX: e.state.jobs[x].map { job in job.interests.values.map { "\($0.kind) \($0.assets.map(\.rawValue).sorted())" }.sorted() } ?? [],
                jobs: e.state.jobs.keys.map { $0 == x ? "X" : "\($0)" }.sorted()
            )
        }
        switch wanters {
        case .waitersAndGroup:
            #expect(replayed.onX == ["prefetch [\"zz-a3\"]", "waiter [\"zz-a1\"]", "waiter [\"zz-a2\"]", "waiter [\"zz-a3\"]"], "the replay brings W1…W3 and the group's zz-a3 to X, and no interest of a purged id but the waiters' (visit-first): \(replayed.onX)")
        case .userGroup:
            #expect(replayed.onX == ["prefetch [\"zz-a1\", \"zz-a2\", \"zz-a3\"]"], "the replay brings the user-lane group's three ids to X (visit-first): \(replayed.onX)")
        case .prefetchWaiters:
            #expect(replayed.onX == ["waiter [\"zz-a1\"]", "waiter [\"zz-a2\"]", "waiter [\"zz-a3\"]"] && replayed.jobs == ["X"], "the replay brings W1…W3 to X, the only job (visit-first): \(replayed)")
        }
        await c.s.harness.source.release(x, with: .progress(received: 0, expected: nil))
        await held.stop()
        let answers = await Self.owedAnswers(c)
        if wanters == .userGroup {
            // No waiter is answered at X's commit in this shape: the reads below wait for it, as the waiters' answers do.
            await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[x] == nil }
            }
        }
        #expect(Self.sizes([answers.k]) == [16] && Self.sizes(answers.w) == Array(repeating: 18, count: c.w.count), "K gets O's bytes, and W1…W3 X's (visit-first): \(answers)")
        let after = await engine.readForTests { e in (pending: c.group.flatMap { e.state.groups[$0]?.pending.keys.map(\.rawValue).sorted() } ?? [], heal: e.state.heals[ids[0]] == nil) }
        #expect(after.pending.isEmpty && after.heal, "X served the group's ids, and no heal came back: \(after.pending)")
        if wanters == .userGroup {
            // The ids X stored for the group are present: a later request is answered from the store, not by X's later
            // attempt (a 404).
            var later: [Result<AssetLocation, AssetError>] = []
            for id in ids {
                later.append(await EngineRegressionCycle6Tests.driving([c.s.time], fence: engine) { await engine.awaitAsset(id, lane: .userInitiated) })
            }
            let xStarts = await c.s.harness.source.starts.filter { $0.id == x }.count
            #expect(Self.sizes(later) == [18, 18, 18] && xStarts == 1, "the store holds zz-a1…zz-a3 at X's content (visit-first): \(later); X started \(xStarts) times")
        }
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

// MARK: d4 §3.6: a waiter whose removal replayed ahead of its owed re-route (b22-no-waiter-owner)

/// d4 §3.6, with its review's M3 (Stage 3 close-out cycle 23, ruling S3-R28 item 4; S3-R27 item 5): `followedLane`'s
/// owner check of an owed waiter item (`reaches(_:_:)`'s `.waiter` arm) decides only for an item whose waiter left
/// through a removal the drain has already replayed: a removal still waiting puts its token in `withdrawn`, which is
/// read first (rr21-T12's `.cancelled`). Swept first, a waiter cancelled behind the barrier before the commit keeps its
/// interest on the job until its removal replays, so the commit owes its item, behind the removal.
extension EngineFollowBarrierTests {
    /// zz-y (P's, a prefetch waiter) is Y's content (24 bytes), which downloads; K0 maps zz-a1…zz-a4 and zz-a6 to Z's
    /// content and only zz-a5 to Y's, and W5 is cancelled behind the barrier before O's commit (visited first the barrier
    /// is down, so its interest goes at once and the commit owes no item of it: S3-R26 answer 1's citation, the state is
    /// swept first only). One drain turn replays W5's removal, which spends no drain id, and zz-a1…zz-a4's items; zz-a5's
    /// (swept first) and zz-a6's wait. Y then gets a 429 with Retry-After 60 s, above the user lane's 30 s cap. W5's item
    /// counts for nothing, since its waiter left, so Y is prefetch work, as on a visit-first engine, where W5's interest
    /// had left before the commit: the origin is throttled at the arrival, Y's retry serves P, and W1…W4 and W6, whose job
    /// on Z is admitted only at the drain's end, behind the throttle, are answered `serverUnavailable` at once. Counted,
    /// W5's item would make Y user work: `.exhausted`, no throttle, P `serverUnavailable`, and Z's bytes for the rest.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: an owed re-route whose waiter's removal replayed ahead of it counts for nothing toward a 429's lane (F-28, d4 §3.6)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedRerouteOfAWaiterRemovedAheadCountsForNothing(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_028_301
        let yBytes = EngineFixture.bytes(seed + 5, count: 24)
        let zBytes = EngineFixture.bytes(seed + 6, count: 20)
        let y = EngineHarness.onDemand("zz-y", yBytes)
        let c = try await Self.stageOwedCommit(seed: seed, moved: 6, extra: [y], tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = c.engine
        let transfer = c.transfer
        let yT = y.transferID
        await c.s.harness.source.script(yT, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(yBytes)])
        let p = await Self.downloadingWaiter(y, c, lane: .prefetch)
        let onZ = Self.movedOnto(zBytes, c)
        let a5 = c.ids[4]
        let k0 = [y] + onZ.filter { $0.identifier != a5 } + [EngineHarness.onDemand(a5.rawValue, yBytes)]
        let zT = onZ[0].transferID
        try #require(zT != yT && zT != transfer, "setup: K0 maps the ids to a content of their own")
        await c.s.harness.source.script(zT, [.stage(zBytes), .stage(zBytes)])
        // `oweThroughK0`'s steps, with W5 cancelled between K0's apply and O's commit.
        let (units, releaser) = try await Self.holdPublications(of: [transfer], c.s, bulk: c.bulk)
        var held = HeldUnits(bulk: c.bulk, kept: units, releaser: releaser)
        try await Self.applyHeld(c.manifest(k0, round: 1), tag: "k0-removed-ahead-\(seed)", c.s, visit: visit)
        c.w[4].cancel()
        let w5 = await c.w[4].value
        #expect(w5 == .failure(.cancelled), "W5 is answered at once (R-SYN-4): \(w5)")
        let removed = await engine.readForTests { e in
            (removals: e.state.eventsAfterFollow.filter { event in
                if case .removal = event {
                    return true
                }
                return false
            }.count, interests: e.state.jobs[transfer]?.interests.count ?? -1)
        }
        if visit == .sweepFollowsFirst {
            try #require(removed == (1, 7), "setup: W5's removal waits, and its interest stays on O's job (K and W1…W6): \(removed)")
        } else {
            try #require(removed == (0, 6), "setup: the barrier is down, so W5's interest left O's job at once and no removal waits: \(removed)")
        }
        await engine.readForTests { $0.holdDrainFollowUps() }
        await held.release(units[0])
        await engine.awaitCondition { $0.state.jobs[transfer] == nil }
        let owed = await engine.readForTests { e in Self.owedBatches(e).map(\.items.count) }
        try #require(owed == [visit == .sweepFollowsFirst ? 6 : 5], "setup: O's commit owes its re-routes as one batch, W5's swept first only: \(owed)")
        // The held turns run one at a time until the drain's first turn has made items: swept first that turn runs at the
        // follow's end, inside its last turn; visited first it is the first held turn.
        var turns: [HeldTurn] = []
        while await engine.readForTests({ e in Self.owedBatches(e).map(\.items.count) == owed }) {
            turns.append(await Self.runOneHeldTurn(engine))
        }
        let left = await engine.readForTests { e in
            (items: Self.owedBatches(e).flatMap { $0.items.elements.map(\.asset) }.sorted(), waiter: e.state.waiters.values.contains { $0.asset == a5 }, owed: e.followOwed)
        }
        let expected = visit == .sweepFollowsFirst ? [a5, c.ids[5]] : [c.ids[5]]
        try #require(left.items == expected && !left.waiter && !left.owed, "setup: the drain's first turn replayed W5's removal and made zz-a1…zz-a4; zz-a5's item (swept first) and zz-a6's wait: \(left), turns \(turns)")
        await c.s.harness.source.release(yT, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[yT]?.state != .downloading }
        let throttled = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } != nil }
        let layer = await Self.finishOwed(c, held: held, others: [p])
        await Self.finishHeld(c.s)
        #expect(throttled, "W5's item counts for nothing: Y is prefetch work, and its 429 throttles the origin at the arrival (visit-first): \(layer)")
        #expect(Self.sizes([layer.others[0]]) == [24], "Y's retry serves P (visit-first): \(layer)")
        for (index, answer) in layer.w.enumerated() where index != 4 {
            if case .failure(.serverUnavailable) = answer {
            } else {
                Issue.record("W\(index + 1), on Z behind the throttled origin, is answered serverUnavailable at once (visit-first): \(answer); \(layer)")
            }
        }
        #expect(layer.w[4] == .failure(.cancelled) && Self.sizes([layer.k]) == [16], "W5 keeps its cancellation and K gets O's bytes: \(layer)")
        #expect(layer.violations.isEmpty, "\(layer.violations.prefix(3))")
    }
}
