import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The follow barrier's answers after Stage 3 close-out cycle 13 (the cycle-13 verifiers' probes, rulings S3-R16 to
/// S3-R18): a place behind a breaker never strands a job, a purge withdraws the joins that wait for the follow, a place
/// is gated on the live throttle, a 429 is decided on the lane a visit-first engine's job had, and a failure of a job the
/// follow passed while it published answers its moved ids as a visit-first engine did. Each test runs in both orders
/// (`LaneDropVisit`), with the visit-first outcome expected in both except where a live origin gate changed during the
/// barrier (S3-R17 item 2, S3-R18 item 1).
extension EngineFollowBarrierTests {
    /// The 2,100 changed on-demand entries that sort after the scenario's `zz-` ids: with `FollowBarrier.fillers` before
    /// them, the follow's second turn finds the scenario's job and formats `followFormatsPerTurn` in all, so the follow
    /// is still owed after that turn's visits.
    @available(macOS 15.0, iOS 18.0, *)
    static func laterFillers(_ seed: UInt64) -> [ManifestEntry] {
        (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "zzz%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
    }

    /// `FollowBarrier.setUp` with a stepped bulk executor, so a test can hold a publication at its first store unit, and
    /// `network` as the engine's network policy; `metadata` is the store's metadata executor, the harness's own when `nil`
    /// (a stepped one holds a claim or a free-space read).
    @available(macOS 15.0, iOS 18.0, *)
    static func setUpHeldPublications(seed: UInt64, tuning: SyncTuning = SyncTuning(), network: NetworkPolicy = NetworkPolicy(), metadata: (any BlockingExecutor)? = nil) async throws -> (setup: FollowBarrier.Setup, bulk: SteppedBlockingExecutor) {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(time: time, tuning: tuning, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), network: network, metadata: metadata, bulk: bulk, fileSystem: fileSystem)
        let qBytes = EngineFixture.bytes(seed, count: 300)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([q])
        await harness.scriptTransfers([(q, qBytes)])
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await harness.engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        return (FollowBarrier.Setup(time: time, fileSystem: fileSystem, harness: harness, q: q), bulk)
    }

    /// Runs exactly one held follow-up turn of the follow and holds the next ones again.
    @available(macOS 15.0, iOS 18.0, *)
    static func runOneFollowTurn(_ engine: SyncEngine) async {
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        await engine.readForTests { e in
            e.releaseFollowFollowUps()
            e.holdFollowFollowUps()
        }
    }

    /// Holds `transfer`'s publication at its first store unit: releases its held download, waits for it to verify, and
    /// returns a task that lets every later store unit run (an apply's, another publication's) until it is cancelled.
    @available(macOS 15.0, iOS 18.0, *)
    static func holdPublication(of transfer: TransferID, _ s: FollowBarrier.Setup, bulk: SteppedBlockingExecutor) async throws -> Task<Void, Never> {
        let engine = s.engine
        await engine.awaitCondition { !$0.state.storeWorkInFlight }
        await bulk.setHolding(true)
        await s.harness.source.release(transfer, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[transfer]?.state == .verifying }
        try await bulk.requireHeldUnits(atLeast: 1)
        let unit = try #require(await bulk.heldUnits.first)
        return Task {
            while !Task.isCancelled {
                await bulk.waitForHeldUnits(atLeast: 2)
                for other in await bulk.heldUnits where other != unit {
                    await bulk.release(other)
                }
            }
        }
    }

    // MARK: A place's stamp never strands a job (PROBE-C13R-STAMP-BREAKER, S3-R16 1(c))

    /// The new content an owed follow's visit queues behind a half-open breaker starts once the breaker closes: X's 403
    /// opens the breaker (one distinct asset trips it); prefetch members M and K park; at the cooldown's end one of them
    /// probes and holds. v3 moves the parked member's id to N while the follow owes its visits; then the probe commits
    /// and closes the breaker. Three slots, so one is free at the apply (H and the probe hold two). Visited first, the
    /// pump tried N at the apply, the half-open breaker refused it, and the close re-admitted it. Refused on the breaker
    /// of its place's stamp after the close's re-admission had run in the drain, N parked `circuitOpen` behind a closed
    /// breaker that nothing re-admits (the cycle-13 requirements verifier).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: new content an owed follow queues behind a half-open breaker starts once the breaker closes (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierStartsAVisitsPlaceOnceTheBreakerCloses(_ visit: LaneDropVisit) async throws {
        let tuning = SyncTuning(maxConcurrentTransfers: 3, reservedInteractiveSlots: 0, breaker: CircuitBreakerPolicy(authDistinctAssets: 1))
        let (s, _) = try await FollowBarrier.setUp(seed: 1_314_002, tuning: tuning)
        let engine = s.engine
        let origin = s.harness.source.originID
        let xBytes = Data(repeating: 0xE4, count: 100_000)
        let mBytes = Data(repeating: 0xE5, count: 100_000)
        let kBytes = Data(repeating: 0xE6, count: 100_000)
        let hBytes = Data(repeating: 0xE7, count: 100_000)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let m = EngineHarness.onDemand("zz-m", mBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_314_100) + [h, k, m, x], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(x.transferID, [.fail(EngineRegressionCycle20Tests.forbidden)])
        await s.harness.source.script(m.transferID, [.hold, .stage(mBytes)])
        await s.harness.source.script(k.transferID, [.hold, .stage(kBytes)])
        await s.harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        let hGroup = try await engine.registerGroup([h.identifier], lane: .prefetch).get()
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[h.transferID]?.state == .downloading }
        }
        let xResult = await engine.awaitAsset(x.identifier, lane: .userInitiated)
        #expect((try? xResult.get()) == nil, "setup: X's 403 fails it: \(xResult)")
        let group = try await engine.registerGroup([m.identifier, k.identifier], lane: .prefetch).get()
        await engine.awaitCondition { e in
            e.state.jobs[m.transferID]?.state.isCircuitParked == true && e.state.jobs[k.transferID]?.state.isCircuitParked == true
        }
        let opened = await engine.readForTests { $0.state.breakers[origin]?.state }
        guard case .open(_, let cooldownEnd, _)? = opened else {
            Issue.record("setup: X's 403 opened the breaker: \(String(describing: opened))")
            await engine.shutdown()
            return
        }
        // The invariant check names the jobs the breaker parked that nothing re-admits while it is closed: the state a
        // place refused on its stamp's breaker, after the close's re-admission had run, left (no breaker deadline, no
        // owed re-queue, no waiting re-admission). Behind the open breaker and its deadline, it names none.
        let whileOpen = await engine.invariantViolations()
        #expect(whileOpen.isEmpty, "\(whileOpen.prefix(3))")
        let unwakeable = await engine.violations { state in
            state.heap.remove(.breaker(origin))
            state.breakers[origin] = nil
        }
        #expect(unwakeable.contains("nothing will re-admit the 2 jobs the breaker parked while it is closed"), "\(unwakeable)")
        EngineRegressionCycle21Tests.advance(s.time, to: cooldownEnd)
        await engine.awaitCondition { $0.state.jobs[m.transferID]?.state == .downloading || $0.state.jobs[k.transferID]?.state == .downloading }
        let mProbes = await engine.readForTests { $0.state.jobs[m.transferID]?.state == .downloading }
        let probe = mProbes ? m : k
        let nBytes = EngineFixture.bytes(1_314_004, count: 16)
        let nEntry = EngineHarness.onDemand(mProbes ? "zz-k" : "zz-m", nBytes)
        await s.harness.source.script(nEntry.transferID, [.hold, .stage(nBytes)])
        let v3: [ManifestEntry] = [h, mProbes ? nEntry : k, mProbes ? m : nEntry, x]
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(1_314_200) + v3, tag: "v3-stamp-breaker", s, visit: visit)
        await s.harness.source.release(probe.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { e in e.state.breakers[origin]?.state == .closed && e.state.jobs[probe.transferID] == nil }
        if visit == .sweepFollowsFirst {
            // Behind the barrier the close's re-admission waits for the follow (`.unblock(.circuitOpen)`): the jobs the
            // breaker parked are not named while it waits (the cycle-14 requirements verifier's non-blocking finding).
            let waiting = await engine.readForTests { e in
                (unblock: e.state.eventsAfterFollow.contains { event in
                    if case .unblock(.circuitOpen) = event {
                        return true
                    }
                    return false
                }, parked: e.state.circuitParked.count, violations: e.invariantViolations())
            }
            #expect(waiting.unblock && waiting.parked > 0, "setup: the close's re-admission waits for parked jobs: \(waiting.unblock), \(waiting.parked)")
            #expect(waiting.violations.isEmpty, "\(waiting.violations.prefix(3))")
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await engine.awaitCondition { e in
            let state = e.state.jobs[nEntry.transferID]?.state
            return state != nil && state != .queued
        }
        let atEnd = await engine.readForTests { e in (n: e.state.jobs[nEntry.transferID]?.state, violations: e.invariantViolations()) }
        #expect(atEnd.n == .downloading, "N starts once the breaker closed (visit-first): \(atEnd.n.map { "\($0)" } ?? "nil")")
        #expect(atEnd.violations.isEmpty, "\(atEnd.violations.prefix(3))")
        if atEnd.n == .downloading {
            await s.harness.source.release(nEntry.transferID, with: .progress(received: 0, expected: nil))
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[nEntry.transferID] == nil }
            }
            let served = await engine.readForTests { e in e.state.groups[group]?.pending[nEntry.identifier] == nil }
            let stored = await s.harness.store.location(for: nEntry.identifier, extensions: [], recordingAccess: false)
            #expect(served && stored != nil, "the group's member is served from N (visit-first)")
        }
        await s.harness.source.release(h.transferID, with: .progress(received: 0, expected: nil))
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[h.transferID] == nil }
        }
        await engine.releaseGroup(group)
        await engine.releaseGroup(hGroup)
        await Self.finishHeld(s)
    }

    // MARK: A purge withdraws the joins that wait (PROBE-C13-PURGE-JOIN, S3-R16 1(a))

    /// A purge during an owed follow withdraws a prefetch group's join of a purged id that waits for the follow, as it
    /// withdrew the member's interest of a visit-first engine: W downloads for a user waiter while v3's follow is owed; a
    /// prefetch group registers zz-m (no job), then `purge(.scope([zz-m]))` arrives. Visited first, the group's join
    /// created M, the purge dropped the group's member and its interest, and M was retired; zz-m is not stored. Applied
    /// at once (cycle 13's removal 7), the purge found no job holding the group's interest, and the drain's join created
    /// M again: zz-m was downloaded and stored after the purge returned (the cycle-13 correctness verifier).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: a purge during an owed follow withdraws a group's waiting join of a purged id (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierPurgeWithdrawsAWaitingGroupJoin(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_314_302)
        let engine = s.engine
        let mBytes = EngineFixture.bytes(1_314_304, count: 100_000)
        let wBytes = EngineFixture.bytes(1_314_305, count: 100_000)
        let m = EngineHarness.onDemand("zz-m", mBytes)
        let w = EngineHarness.onDemand("zz-w", wBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_314_400) + [m, w], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(m.transferID, [.hold, .stage(mBytes)])
        await s.harness.source.script(w.transferID, [.hold, .stage(wBytes)])
        let wWaiter = Task { await engine.awaitAsset(w.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[w.transferID]?.state == .downloading }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(1_314_500) + [m, w], tag: "v3-purge", s, visit: visit)
        let token = try await engine.registerGroup([m.identifier], lane: .prefetch).get()
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, m) }
        } else {
            await engine.awaitCondition { $0.state.jobs[m.transferID]?.interests[token] != nil && $0.state.jobs[m.transferID]?.state == .downloading }
        }
        let purged = await engine.purge(.scope(.identifiers([m.identifier])))
        #expect((try? purged.get()) != nil, "the purge completes: \(purged)")
        // The withdrawn join still waits in the queue, no longer registered (`JoinAfterFollow.withdrawn`).
        let whileWaiting = await engine.invariantViolations()
        #expect(whileWaiting.isEmpty, "\(whileWaiting.prefix(3))")
        let startsBefore = await s.harness.source.starts.filter { $0.id == m.transferID }.count
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let after = await engine.readForTests { e in
            (pending: e.state.groups[token]?.pending[m.identifier] != nil, job: e.state.jobs[m.transferID]?.state)
        }
        let startsAfter = await s.harness.source.starts.filter { $0.id == m.transferID }.count
        #expect(!after.pending && after.job == nil, "the purge withdrew the group's member (visit-first: no job, the group no longer waits for zz-m): \(after)")
        #expect(startsAfter == startsBefore, "no request for the purged zz-m after the purge (visit-first): \(startsBefore) -> \(startsAfter)")
        if after.job != nil {
            await engine.awaitCondition { $0.state.jobs[m.transferID]?.state == .downloading }
            await s.harness.source.release(m.transferID, with: .progress(received: 0, expected: nil))
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[m.transferID] == nil }
            }
        }
        let present = await s.harness.store.location(for: m.identifier, extensions: [], recordingAccess: false) != nil
        #expect(!present, "zz-m stays purged (visit-first)")
        await engine.releaseGroup(token)
        await s.harness.source.release(w.transferID, with: .progress(received: 0, expected: nil))
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        #expect((try? wResult.get())?.byteSize == Int64(wBytes.count), "W's waiter is served: \(wResult)")
        await Self.finishHeld(s)
    }

    /// A purge during an owed follow forgets a heal of a purged id whose join waits for the follow, as it forgot the heal
    /// of a visit-first engine: W downloads for a user waiter while v3's follow is owed; zz-h's quarantine ends (its heal
    /// joins a system interest), then `purge(.scope([zz-h]))` arrives. Visited first, the heal's join created H and the
    /// purge withdrew its system interest and forgot the heal (`EngineState.heals`). Behind the barrier the purge
    /// withdraws the waiting join and forgets the heal too (`withdrawPurgedJoins`).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-6: a purge during an owed follow forgets a heal whose join waits for the follow (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierPurgeForgetsAWaitingHeal(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_317_302)
        let engine = s.engine
        let hBytes = EngineFixture.bytes(1_317_304, count: 100_000)
        let wBytes = EngineFixture.bytes(1_317_305, count: 100_000)
        let h = EngineHarness.onDemand("zz-h", hBytes)
        let w = EngineHarness.onDemand("zz-w", wBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_317_400) + [h, w], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(h.transferID, [.hold, .stage(hBytes)])
        await s.harness.source.script(w.transferID, [.hold, .stage(wBytes)])
        let wWaiter = Task { await engine.awaitAsset(w.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[w.transferID]?.state == .downloading }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(1_317_500) + [h, w], tag: "v3-heal", s, visit: visit)
        await engine.readForTests { $0.scheduleHeal(h.identifier, at: $0.environment.time.monotonicNow()) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            if visit == .sweepFollowsFirst {
                await engine.awaitCondition { FollowBarrier.joinWaits($0, h) }
            } else {
                await engine.awaitCondition { $0.state.jobs[h.transferID]?.interests.values.contains { $0.kind == .system } == true }
            }
        }
        let purged = await engine.purge(.scope(.identifiers([h.identifier])))
        #expect((try? purged.get()) != nil, "the purge completes: \(purged)")
        let healAfterPurge = await engine.readForTests { $0.state.heals[h.identifier] }
        #expect(healAfterPurge == nil, "the purge forgot zz-h's heal (visit-first): \(String(describing: healAfterPurge))")
        let startsBefore = await s.harness.source.starts.filter { $0.id == h.transferID }.count
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let after = await engine.readForTests { e in (job: e.state.jobs[h.transferID]?.state, heal: e.state.heals[h.identifier]) }
        let startsAfter = await s.harness.source.starts.filter { $0.id == h.transferID }.count
        #expect(after.job == nil && after.heal == nil, "no job and no heal for the purged zz-h (visit-first): \(after)")
        #expect(startsAfter == startsBefore, "no request for the purged zz-h after the purge (visit-first): \(startsBefore) -> \(startsAfter)")
        await s.harness.source.release(w.transferID, with: .progress(received: 0, expected: nil))
        let wResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: wWaiter) }
        #expect((try? wResult.get())?.byteSize == Int64(wBytes.count), "W's waiter is served: \(wResult)")
        await Self.finishHeld(s)
    }

    // MARK: A place is gated on the live throttle (PROBE-C13-STAMP-NO-SLOT, S3-R16 1(a); S3-R18 item 1)

    /// A request that waits for the follow while no slot is free is gated on the live throttle when the slot frees, as
    /// a visit-first engine's pump gated it: one slot; C (1 MB, held) downloads for user waiter A. While the follow is
    /// owed, an unknown id's manifest fetch gets a 429 with Retry-After 3 s, so the origin is throttled while C runs;
    /// then a user asks for zz-k (16 bytes, listed). Visited first, K waited in the queue behind C's slot (the pump gates
    /// nothing while no slot is free); the throttle ended, C completed, and the pump started K: K's caller was served.
    /// Refused on its place's stamp (the throttle of the join's arrival) although no slot was free then, K's caller was
    /// answered `serverUnavailable` and K never started (the cycle-13 correctness verifier); the stamps are gone since
    /// Stage 3 close-out cycle 15 (ruling S3-R18 item 1).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a request waiting for a slot during an owed follow is gated on the live throttle when the slot frees (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierGatesAPlaceWithoutASlotOnTheLiveThrottle(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_314_602, tuning: SyncTuning(maxConcurrentTransfers: 1))
        let engine = s.engine
        let cBytes = Data(repeating: 0xE1, count: 1_000_000)
        let kBytes = EngineFixture.bytes(1_314_604, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_314_700) + [a, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(1_314_800) + [a, k], s, visit: visit)
        await s.harness.source.scriptManifest([.fail(.transient(.throttled, retryAfter: .seconds(3)))])
        _ = await engine.awaitAsset("zz-none", lane: .userInitiated)
        let throttled = await engine.readForTests { e in
            (left: e.state.remote.flatMap { e.state.throttles[$0.originID] }?.seconds(since: e.environment.time.monotonicNow()), c: e.state.jobs[a.transferID]?.state)
        }
        try #require(throttled.left != nil && throttled.c == .downloading, "setup: the origin is throttled while C holds the slot: \(throttled)")
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, k) }
        } else {
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .queued }
        }
        s.time.advance(by: 4)
        await engine.awaitCondition { e in e.state.remote.flatMap { e.state.throttles[$0.originID] }.map { $0 <= e.environment.time.monotonicNow() } ?? true }
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID] == nil }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let kResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let kStarts = await s.harness.source.starts.filter { $0.id == k.transferID }.count
        #expect((try? aResult.get())?.byteSize == Int64(cBytes.count), "A is served by C: \(aResult)")
        #expect((try? kResult.get())?.byteSize == 16, "K's caller is served: K waited behind C's slot and started on the live gates once the throttle ended (visit-first): \(kResult)")
        #expect(kStarts == 1, "K's one request (visit-first): \(kStarts)")
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A user request that waits for the follow while a reserved interactive slot is free is gated on the live throttle:
    /// two slots, one reserved for user work; C (1 MB, held) downloads for a prefetch group and takes the only slot other
    /// work may use. While the follow is owed, an unknown id's manifest fetch gets a 429 with Retry-After 3 s; then a user
    /// asks for zz-k (16 bytes, listed). Visited first, the pump tried K at once in the reserved slot, the throttle refused
    /// it, and K's caller was answered `serverUnavailable`. Behind the barrier K's join waits; the throttle ends before
    /// the barrier does, and the barrier-end pump admits K on the live gates: K's caller is served, the answer a live
    /// origin gate that changed during the barrier gives (ruling S3-R18 item 1, S3-R17 item 2; recorded as a residual
    /// risk). Cycle 14 refused K on its place's stamp, the throttle at its arrival (`FreeSlots`, mutant `slotLaneBlind`);
    /// the stamps are gone since Stage 3 close-out cycle 15 (PROBE-C14C-STAMP-AHEAD). No request goes to the throttled
    /// origin in either order (R-SYN-5).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a user request during an owed follow with a reserved slot free is gated on the live throttle, its arrival's when visited first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierRefusesAUserPlaceInAReservedSlotOnItsThrottle(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_316_702, tuning: SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 1))
        let engine = s.engine
        let cBytes = Data(repeating: 0xE9, count: 1_000_000)
        let kBytes = EngineFixture.bytes(1_316_704, count: 16)
        let c = EngineHarness.onDemand("zz-c", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_316_800) + [c, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(c.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(k.transferID, [.stage(kBytes)])
        let group = try await engine.registerGroup([c.identifier], lane: .prefetch).get()
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[c.transferID]?.state == .downloading }
        }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(1_316_900) + [c, k], s, visit: visit)
        await s.harness.source.scriptManifest([.fail(.transient(.throttled, retryAfter: .seconds(3)))])
        _ = await engine.awaitAsset("zz-none", lane: .userInitiated)
        let throttled = await engine.readForTests { e in
            (left: e.state.remote.flatMap { e.state.throttles[$0.originID] }?.seconds(since: e.environment.time.monotonicNow()), c: e.state.jobs[c.transferID]?.state)
        }
        try #require(throttled.left != nil && throttled.c == .downloading, "setup: the origin is throttled while C holds the non-user slot: \(throttled)")
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, k) }
        } else {
            // Visited first, the pump answers the request at its arrival (the throttled park's fail-fast): no clock moves.
            _ = await EngineHarness.value(of: kWaiter)
        }
        s.time.advance(by: 4)
        await engine.awaitCondition { e in e.state.remote.flatMap { e.state.throttles[$0.originID] }.map { $0 <= e.environment.time.monotonicNow() } ?? true }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let kResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        if visit == .followVisitedFirst {
            if case .failure(.serverUnavailable) = kResult {
            } else {
                Issue.record("K's caller is answered serverUnavailable: the pump tried K in the reserved slot under the throttle (visit-first): \(kResult)")
            }
        } else {
            // S3-R18 item 1 (an exception like S3-R17 item 3): K's place is admitted on the live gates, and the throttle
            // ended during the barrier.
            #expect((try? kResult.get())?.byteSize == 16, "K's caller is served, K admitted once the live throttle had ended: \(kResult)")
        }
        await s.harness.source.release(c.transferID, with: .progress(received: 0, expected: nil))
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[c.transferID] == nil }
        }
        let served = await engine.readForTests { e in e.state.groups[group]?.pending[c.identifier] == nil }
        #expect(served, "the group's member is served by C")
        await engine.releaseGroup(group)
        await FollowBarrier.finish(s, sync: sync)
    }

    // MARK: A 429 decided on the lane a visit-first engine's job had (S3-R16 1(a); PROBE-C13-EXHAUST-LANE)

    /// The retry policy whose `maxRetryAfter` (30 s) lies below the background policy's (3,600 s): a 429 with
    /// Retry-After 60 s defers user work to the next run and throttles the origin for background work.
    static let shortInteractiveRetry = RetryPolicy(baseDelay: 0.25, maxDelay: 2, maxAttemptsPerRun: 2, maxRetryAfter: 30, interactiveMaxWait: 2)

    /// A 429 during an owed follow is decided on the lane the visits leave the job, counting an interest another job's
    /// visit moves onto it: C (1 MB, zz-b) runs for P, a prefetch waiter; Y (zz-u) runs for U, a user waiter; v3 moves
    /// zz-u onto C's content; C gets a 429 with Retry-After 60 s (above the user lane's 30 s cap). Visited first, Y's
    /// visit moved U onto C, so C was user work at the 429: `Backoff.delay` deferred to the next run, the origin was not
    /// throttled, and C failed: P and U were answered `serverUnavailable(60)`. Read without U's interest, the background
    /// policy throttled the origin for 60 s on arrival and C's retry served P (the cycle-13 correctness verifier).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 during an owed follow is decided on the lane a moved interest gives its job (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierDecidesA429OnTheLaneAMovedInterestGives(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_314_902, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = Data(repeating: 0xE8, count: 1_000_000)
        let yBytes = Data(repeating: 0xE9, count: 1_000_000)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let u = EngineHarness.onDemand("zz-u", yBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_315_000) + [b, u], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(b.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(cBytes)])
        await s.harness.source.script(u.transferID, [.hold, .stage(yBytes)])
        let pWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let uWaiter = Task { await engine.awaitAsset(u.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[u.transferID]?.state == .downloading }
        }
        let uMoved = EngineHarness.onDemand("zz-u", cBytes)
        try #require(uMoved.transferID == b.transferID, "setup: v3's zz-u is C's content")
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(1_315_100) + [b, uMoved], s, visit: visit)
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        let throttleAtArrival = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        #expect(throttleAtArrival == nil, "the 429 beyond the user lane's cap throttles nothing (visit-first `.exhausted`): \(String(describing: throttleAtArrival))")
        if case .failure(.serverUnavailable) = pResult {
        } else {
            Issue.record("P is answered serverUnavailable with C's deferral to the next run (visit-first): \(pResult)")
        }
        if case .failure(.serverUnavailable) = uResult {
        } else {
            Issue.record("U is answered serverUnavailable (visit-first): \(uResult)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A 429 during an owed follow is decided on the lane a request's waiting join gives its job: C (1 MB, zz-b) runs for
    /// P, a prefetch waiter; while v3's follow is owed, U requests zz-b; then C gets a 429 with Retry-After 60 s (above
    /// the user lane's 30 s cap). Visited first, U's request joined C at once, so C was user work at the 429: nothing was
    /// throttled, C failed, and P and U were answered `serverUnavailable(60)`. Read without the waiting join, the
    /// background policy throttled the origin on arrival and C's retry served P.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 during an owed follow is decided on the lane a waiting request's join gives its job (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierDecidesA429OnTheLaneAWaitingJoinGives(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_315_202, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = Data(repeating: 0xEA, count: 1_000_000)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_315_300) + [b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(b.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(cBytes)])
        let pWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(1_315_400) + [b], s, visit: visit)
        let uWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, b) }
        } else {
            await engine.awaitCondition { $0.state.jobs[b.transferID]?.interests.count == 2 }
        }
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        let throttleAtArrival = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let uResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        #expect(throttleAtArrival == nil, "the 429 beyond the user lane's cap throttles nothing (visit-first `.exhausted`): \(String(describing: throttleAtArrival))")
        if case .failure(.serverUnavailable) = pResult {
        } else {
            Issue.record("P is answered serverUnavailable with C's deferral to the next run (visit-first): \(pResult)")
        }
        if case .failure(.serverUnavailable) = uResult {
        } else {
            Issue.record("U is answered serverUnavailable (visit-first): \(uResult)")
        }
        await FollowBarrier.finish(s, sync: sync)
    }

    /// A 429 during an owed follow is decided on the lane a waiting withdrawal leaves its job: C (1 MB, zz-b) runs for P,
    /// a prefetch waiter, and U, a user waiter; while v3's follow is owed, U withdraws; then C gets a 429 with
    /// Retry-After 60 s (above the user lane's 30 s cap, below the background lane's). Visited first, the withdrawal
    /// removed U's interest at once, so C was prefetch work at the 429: the origin was throttled for 60 s and C's retry
    /// served P. Read with U's interest, whose removal waits for the follow, C was user work: nothing was throttled and P
    /// was answered `serverUnavailable(60)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a 429 during an owed follow is decided on the lane a waiting withdrawal leaves its job (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierDecidesA429OnTheLaneAWaitingWithdrawalLeaves(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_315_502, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let cBytes = Data(repeating: 0xEB, count: 1_000_000)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_315_600) + [b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(b.transferID, [.hold, .fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(cBytes)])
        let pWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[b.transferID]?.state == .downloading }
        }
        let uWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.interests.count == 2 }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(1_315_700) + [b], s, visit: visit)
        uWaiter.cancel()
        let uResult = await uWaiter.value
        #expect(uResult == .failure(.cancelled), "U's caller is answered at once (R-SYN-4): \(uResult)")
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { e in
                e.state.eventsAfterFollow.contains { event in
                    if case .removal = event { return true }
                    return false
                }
            }
        } else {
            await engine.awaitCondition { $0.state.jobs[b.transferID]?.interests.count == 1 }
        }
        await s.harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[b.transferID]?.state != .downloading }
        let throttleAtArrival = await engine.readForTests { e in e.state.remote.flatMap { e.state.throttles[$0.originID] } }
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        let pResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        #expect(throttleAtArrival != nil, "the 429 throttles the origin for prefetch work (visit-first): \(String(describing: throttleAtArrival))")
        #expect((try? pResult.get())?.byteSize == Int64(cBytes.count), "P is served by C's retry once the throttle ends (visit-first): \(pResult)")
        await FollowBarrier.finish(s, sync: sync)
    }

    // MARK: A failure of a job the follow passed while it published (S3-R16 1(a), S3-R18 item 2)

    /// The shared scenario of the three tests below: C (100 kB, the content of zz-a and zz-b, a user waiter each)
    /// publishes bytes that fail their checksum; v3 moves zz-b to N (16 bytes). The fillers before and after the `zz-`
    /// ids make the follow's first turn stop before C and its second turn find C and stay owed. `publishingAtApply`:
    /// C's publication is held before v3's apply, else after it. `failBehindBarrier`: C's bytes fail while the follow is
    /// still owed, else after its drain. `failBeforeVisit` (with both): C's bytes fail before the follow's turn that finds
    /// C, so the visit meets C failed, its verdict waiting.
    @available(macOS 15.0, iOS 18.0, *)
    func passedPublication(_ visit: LaneDropVisit, seed: UInt64, publishingAtApply: Bool, failBehindBarrier: Bool, failBeforeVisit: Bool = false) async throws -> (a: Result<AssetLocation, AssetError>, b: Result<AssetLocation, AssetError>) {
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong)])
        await s.harness.source.script(bMoved.transferID, [.stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        var releaser: Task<Void, Never>?
        if publishingAtApply {
            releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [a, bMoved] + Self.laterFillers(seed + 6_000), tag: "v3-passed-\(seed)", s, visit: visit)
        if !publishingAtApply {
            if visit == .followVisitedFirst {
                // Visited first, C's visit moved B onto N at the apply; N is served before C's bytes arrive.
                await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                    await engine.awaitCondition { $0.state.jobs[bMoved.transferID] == nil }
                }
            }
            releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        }
        if visit == .sweepFollowsFirst, !failBeforeVisit {
            await Self.runOneFollowTurn(engine)
            let passed = await engine.readForTests { e in
                (
                    owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, visited: !e.state.followOrder[e.state.followNext...].contains(a.transferID),
                    holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, unfollowed: e.state.unfollowed.contains(a.transferID)
                )
            }
            // Begun after the apply, C's publication had its moved id re-routed by the visit (S3-R18 item 2); begun before
            // it, C was passed with zz-b (cycle 14's `passed`: in `unfollowed`, visited).
            let rerouted = publishingAtApply ? passed.holdsB && passed.unfollowed : !passed.holdsB && !passed.unfollowed
            #expect(passed.owed && passed.c == .verifying && passed.visited && rerouted, "setup: the follow's second turn visited C while it verified and stays owed: \(passed)")
            if !failBehindBarrier {
                await engine.readForTests { $0.releaseFollowFollowUps() }
                await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
            }
        }
        releaser?.cancel()
        await releaser?.value
        await bulk.setHolding(false)
        if visit == .sweepFollowsFirst, failBehindBarrier {
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
            if failBeforeVisit {
                let unvisited = await engine.readForTests { e in
                    e.followOwed && !e.state.followOrder.contains(a.transferID) && e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true
                }
                #expect(unvisited, "setup: C's bytes failed before the follow's turn that finds C")
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return (aResult, bResult)
    }

    /// A job the follow passed while it verified, whose publication began after the apply, answers its moved id's user
    /// with the id's new content when its bytes fail behind the barrier: visited first, C's visit at the apply moved B
    /// onto N while C downloaded, so B was served N and A answered `integrityFailure`. Behind the barrier the follow's
    /// visit came after C's publication began and passed C, re-routing B onto N at once (`Job.rerouteOnPass`; ruling
    /// S3-R18 item 2, which replaced the cycle-14 drain visit `followedForVerdict`), so the failure's waiting verdict
    /// answers A alone.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: an integrity failure of a job an owed follow passed after its apply answers a moved id with its new content (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAPassedJobsFailureAfterItsVisit(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult) = try await self.passedPublication(visit, seed: 1_315_802, publishingAtApply: false, failBehindBarrier: true)
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect((try? bResult.get())?.byteSize == 16, "B is served N, the content v3 maps zz-b to (visit-first): \(bResult)")
    }

    /// As above, with C's bytes failing after the barrier's drain: the follow's visit came after C's publication began
    /// and passed C, and nothing waits any more when the failure arrives. Visited first, B was served N at the apply.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: an integrity failure after an owed follow passed its job after the apply answers a moved id with its new content (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAPassedJobsLaterFailureAsVisitedFirst(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult) = try await self.passedPublication(visit, seed: 1_316_102, publishingAtApply: false, failBehindBarrier: false)
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect((try? bResult.get())?.byteSize == 16, "B is served N, the content v3 maps zz-b to (visit-first): \(bResult)")
    }

    /// A job whose publication began before the apply was passed by a visit-first engine's follow too: C verifies when v3
    /// moves zz-b; its bytes then fail. Visited first, the follow passed C and the failure answered both users
    /// `integrityFailure`. Behind the barrier the failure's verdict waits for the follow; the drain must not visit C, which
    /// a visit-first engine never moved.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: an integrity failure of a job that published before an owed follow's apply answers as visited first (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAJobPublishingAtTheApplyAsVisitedFirst(_ visit: LaneDropVisit) async throws {
        let (aResult, bResult) = try await self.passedPublication(visit, seed: 1_316_402, publishingAtApply: true, failBehindBarrier: true)
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "B gets C's integrity failure: the follow passed C, publishing, in both orders (visit-first): \(bResult)")
    }

    /// A retried publication of a job the follow passed after its apply serves the moved id its new content, and a later
    /// apply's follow that passes the job's next publication answers as a visit-first engine's: C (100 kB, the content of
    /// zz-a, zz-b and zz-c, a user waiter each) publishes after v3's apply, which moves zz-b to N (16 bytes); behind the
    /// barrier the follow passes C while it verifies. C's verification read then fails (EIO), a transient error the
    /// interactive policy retries. Visited first, B was moved onto N at the apply and served N; C's retry downloaded
    /// bytes that fail their checksum, and v4, applied while that second publication verified, moved zz-c to N2 (24
    /// bytes): its follow passed C, publishing, so A and zz-c's user were answered `integrityFailure`. Behind the barrier,
    /// left to C's retry, B rode it and was answered C's failure; and a re-route kept from the first publication would
    /// move zz-c onto N2 at the second failure, which a visit-first engine never did (`Job.rerouteOnPass` and
    /// `Job.attemptEnd` are reset at the retry's start).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-INT-3: a retried publication of a job an owed follow passed after its apply serves a moved id its new content (F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func barrierAnswersAPassedJobsRetryAsVisitedFirst(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_317_002
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let n2Bytes = EngineFixture.bytes(seed + 6, count: 24)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let c = EngineHarness.onDemand("zz-c", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        let cMoved = EngineHarness.onDemand("zz-c", n2Bytes)
        try #require(a.transferID == b.transferID && a.transferID == c.transferID, "setup: zz-a, zz-b and zz-c share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b, c] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(bMoved.transferID, [.stage(nBytes)])
        await s.harness.source.script(cMoved.transferID, [.stage(n2Bytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        let cWaiter = Task { await engine.awaitAsset(c.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 3 }
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        try await Self.applyHeld([s.q] + fillers + [a, bMoved, c] + later, tag: "v3-retry-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            // Visited first, C's visit moved B onto N at the apply; N is served before C's bytes arrive.
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[bMoved.transferID] == nil }
            }
        }
        var releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        if visit == .sweepFollowsFirst {
            await Self.runOneFollowTurn(engine)
            let passed = await engine.readForTests { e in
                (
                    owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, visited: !e.state.followOrder[e.state.followNext...].contains(a.transferID),
                    holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, unfollowed: e.state.unfollowed.contains(a.transferID)
                )
            }
            // C's publication began after the apply: the visit re-routed its moved id at once (S3-R18 item 2).
            #expect(passed.owed && passed.c == .verifying && passed.visited && !passed.holdsB && !passed.unfollowed, "setup: the follow's second turn visited C while it verified and stays owed: \(passed)")
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
            // N, admitted once the barrier is down, publishes before the fault below exists: its own verification read
            // must not be the one that fails (the cycle-15 verifier's PROBE-C15C-RETRY-FAULT-RACE).
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[bMoved.transferID] == nil }
            }
        }
        releaser.cancel()
        await releaser.value
        // The held unit is the first chunk of C's hash: its read of the claimed staging file fails, and C is retried.
        s.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .io))
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong)])
        await bulk.setHolding(false)
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        #expect((try? bResult.get())?.byteSize == 16, "B is served N, the content v3 maps zz-b to (visit-first): \(bResult)")
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading && $0.state.jobs[a.transferID]?.attempts == 1 }
        }
        // C's retry publishes; v4 moves zz-c while that publication, begun before v4's apply, verifies.
        releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        try await Self.applyHeld([s.q] + fillers + [a, bMoved, cMoved] + later, tag: "v4-retry-\(seed)", s, visit: .followVisitedFirst)
        let passedAgain = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, holdsC: e.state.jobs[a.transferID]?.assets.contains(c.identifier) == true, unfollowed: e.state.unfollowed.contains(a.transferID))
        }
        #expect(passedAgain.c == .verifying && passedAgain.holdsC && passedAgain.unfollowed, "setup: v4's follow passed C's second publication, begun before its apply: \(passedAgain)")
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let cResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: cWaiter) }
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(cResult == .failure(.integrityFailure), "zz-c's user gets C's integrity failure: v4's follow passed C publishing, in both orders (visit-first): \(cResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
    }
}
