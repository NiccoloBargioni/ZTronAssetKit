import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The commit's own turn, made cheaper without a split (Stage 3 close-out cycle 21, ruling S3-R26 item 4; `integrate-c21.md`
/// item C, Phase 1): the terminal events walk the publication's sorted binding (step C3, T-ORDER), and `removeJob`
/// retires only the progress keys that have something to retire (step C4, T-PG4). Each runs in both orders
/// (`LaneDropVisit`) and expects the same answers in both.
extension EngineFollowBarrierTests {
    // MARK: T-ORDER: the terminal events of a commit stay ascending (step C3)

    /// Eight ids share X's content and each has a user waiter; X's publication is held at its first store unit while
    /// v4 maps zz-o5 to Y's content, so the store, which holds v4 when the publication ends, binds the other seven
    /// (`stillBound`), and zz-o5's waiter follows its new content. The commit announces exactly the seven ids it bound,
    /// in ascending order, read from a subscriber that reads nothing.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a commit announces exactly the ids the store bound, in ascending order (step C3)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitAnnouncesItsBoundIDsInAscendingOrder(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_022_101
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let xBytes = EngineFixture.bytes(seed + 3, count: 16)
        let yBytes = EngineFixture.bytes(seed + 4, count: 20)
        let onX = (1...8).map { EngineHarness.onDemand("zz-o\($0)", xBytes) }
        let moved = EngineHarness.onDemand("zz-o5", yBytes)
        let x = onX[0].transferID
        try #require(moved.transferID != x, "setup: v4 maps zz-o5 to other content")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + onX + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(x, [.hold, .stage(xBytes)])
        await s.harness.source.script(moved.transferID, [.hold, .stage(yBytes)])
        let subscription = try await engine.subscribe().get()
        let waiters = onX.map { entry in
            let id = entry.identifier
            return Task { await engine.awaitAsset(id, lane: .userInitiated) }
        }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[x]?.state == .downloading && $0.state.jobs[x]?.interests.count == 8 }
        }
        let releaser = try await Self.holdPublication(of: x, s, bulk: bulk)
        let v4 = [s.q] + FollowBarrier.fillers(seed + 200) + onX.map { $0.identifier == moved.identifier ? moved : $0 } + Self.laterFillers(seed + 6_000)
        try await Self.applyHeld(v4, tag: "v4-order-\(seed)", s, visit: visit)
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        await engine.awaitCondition { $0.state.jobs[x] == nil }
        let announced = await engine.readForTests { e -> [AssetID] in
            guard let key = e.state.subscribers.keys.max() else {
                return []
            }
            var ids: [AssetID] = []
            while let event = e.state.subscribers[key]?.take() {
                if case .assetAvailable(let id, _) = event, id.rawValue.hasPrefix("zz-o") {
                    ids.append(id)
                }
            }
            return ids
        }
        let bound = onX.map(\.identifier).filter { $0 != moved.identifier }
        #expect(announced == bound, "X's commit announces the seven ids the store bound, ascending: \(announced)")
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        await engine.awaitCondition { $0.state.jobs[moved.transferID]?.state == .downloading }
        await s.harness.source.release(moved.transferID, with: .progress(received: 0, expected: nil))
        for (entry, waiter) in zip(onX, waiters) {
            let result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) }
            let expected = entry.identifier == moved.identifier ? yBytes.count : xBytes.count
            #expect((try? result.get())?.byteSize == Int64(expected), "\(entry.identifier) gets its content's bytes: \(result)")
        }
        withExtendedLifetime(subscription) {}
        await Self.finishHeld(s)
    }

    // MARK: T-PG4: a commit leaves no progress key of its ids (step C4)

    /// X holds zz-p1, zz-p2 and zz-p3 for three user waiters, a subscriber reads nothing, and two progress elements
    /// arrive within one `progressInterval`: the first is published for the job's least id, the second waits as that
    /// key's trailing emission, with its flush in the heap. v3 is applied (its follow owed in `sweepFollowsFirst`), and
    /// X commits. The progress gate's clauses hold at every step, and after the commit no `.transfer` key of the three ids
    /// is left in `lastEmitted`, `trailing`, the heap or the subscriber's queue: `removeJob` retires the one key that has
    /// an entry, and skips the two that have none.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a commit retires every progress key of its ids, and nothing is left of them (step C4)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func commitRetiresEveryProgressKeyOfItsIDs(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_022_201
        let (s, _) = try await FollowBarrier.setUp(seed: seed)
        let engine = s.engine
        let xBytes = EngineFixture.bytes(seed + 3, count: 16)
        let shared = (1...3).map { EngineHarness.onDemand("zz-p\($0)", xBytes) }
        let ids = shared.map(\.identifier)
        let x = shared[0].transferID
        let slots = ids.map { EventSlot.transfer($0) }
        await s.harness.source.script(x, [.hold, .hold, .hold, .stage(xBytes)])
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + shared + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        let subscription = try await engine.subscribe().get()
        let waiters = ids.map { id in Task { await engine.awaitAsset(id, lane: .userInitiated) } }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[x]?.state == .downloading && $0.state.jobs[x]?.interests.count == 3 }
        }
        var violations: [String] = []
        await s.harness.source.release(x, with: .progress(received: 4, expected: 16))
        await engine.awaitCondition { $0.state.progress.lastEmitted[slots[0]] != nil }
        violations += await engine.invariantViolations()
        await s.harness.source.release(x, with: .progress(received: 8, expected: 16))
        await engine.awaitCondition { $0.state.progress.trailing[slots[0]] != nil }
        violations += await engine.invariantViolations()
        let before = await engine.readForTests { e in
            (
                emitted: slots.filter { e.state.progress.lastEmitted[$0] != nil },
                flush: e.state.heap.entries.contains { $0.reason == .progress(slots[0]) },
                live: e.state.subscribers.values.contains { $0.liveSlots.contains(slots[0]) }
            )
        }
        try #require(before.emitted == [slots[0]] && before.flush && before.live, "setup: zz-p1's key was published, has a trailing flush, and the subscriber holds it: \(before)")
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + shared + Self.laterFillers(seed + 6_000), tag: "v3-progress-\(seed)", s, visit: visit)
        violations += await engine.invariantViolations()
        await s.harness.source.release(x, with: .progress(received: 12, expected: 16))
        await engine.awaitCondition { $0.state.jobs[x] == nil }
        violations += await engine.invariantViolations()
        let after = await engine.readForTests { e in
            (
                emitted: slots.filter { e.state.progress.lastEmitted[$0] != nil },
                trailing: slots.filter { e.state.progress.trailing[$0] != nil },
                heap: e.state.heap.entries.filter { deadline in slots.contains { deadline.reason == .progress($0) } }.count,
                queued: e.state.subscribers.values.flatMap { queue in queue.liveSlots.filter { slots.contains($0) } }
            )
        }
        #expect(after.emitted.isEmpty && after.trailing.isEmpty && after.heap == 0 && after.queued.isEmpty, "no progress key of X's ids is left: \(after)")
        #expect(violations.isEmpty, "the progress gate held at every step: \(violations.prefix(3))")
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        for waiter in waiters {
            let result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) }
            #expect((try? result.get())?.byteSize == Int64(xBytes.count), "each waiter gets X's bytes: \(result)")
        }
        withExtendedLifetime(subscription) {}
        await Self.finishHeld(s)
    }
}

extension EngineFollowBarrierTests {
    // MARK: The bookkeeping written in place (steps C10 and C11), reached through T21 in both orders

    /// An `ensureAvailable` group waits for zz-e1 (committed) and zz-e2 (E2, held downloading); v3 drops zz-e2 from the
    /// manifest (T21). The follow's visit of E2 drops the member from the group (`reroute`, `dropGroupMember`), which
    /// settles the group and resumes the ensure, with the same answer in both orders. The group is read once the follow
    /// and its drain are over, so a member left pending fails at once; a caller left suspended keeps its group, and the
    /// wait for its release ends at the time limit.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-7: an ensureAvailable member that leaves the manifest while it downloads is dropped, and the ensure answers (T21, step C10)", .timeLimit(.minutes(1)), arguments: LaneDropVisit.allCases)
    func barrierDropsAnEnsureMemberThatLeftTheManifest(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_022_401
        let (s, _) = try await FollowBarrier.setUp(seed: seed)
        let engine = s.engine
        let e1Bytes = EngineFixture.bytes(seed + 3, count: 16)
        let e2Bytes = EngineFixture.bytes(seed + 4, count: 20)
        let e1 = EngineHarness.onDemand("zz-e1", e1Bytes)
        let e2 = EngineHarness.onDemand("zz-e2", e2Bytes)
        await s.harness.source.script(e1.transferID, [.stage(e1Bytes)])
        await s.harness.source.script(e2.transferID, [.hold, .stage(e2Bytes)])
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [e1, e2] + Self.laterFillers(seed + 3_000), etag: "v2")
        let ensure = Task { await engine.ensureAvailable(scope: .identifiers([e1.identifier, e2.identifier])) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                e.state.jobs[e2.transferID]?.state == .downloading && e.state.jobs[e1.transferID] == nil
                    && e.state.groups.values.contains { $0.kind == .ensure && $0.pending == [e2.identifier: e2.transferID] }
            }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [e1] + Self.laterFillers(seed + 6_000), tag: "v3-ensure-t21-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let groups = await engine.readForTests { e in
            e.state.groups.values.filter { $0.kind == .ensure }.map { (pending: $0.pending.count, suspended: $0.continuation != nil) }
        }
        #expect(groups.allSatisfy { $0.pending == 0 && !$0.suspended }, "the visit dropped zz-e2 and resumed the ensure: \(groups)")
        // Bounded: the resumed ensure releases its group; a caller never resumed leaves it, and the wait ends at the time
        // limit without waiting for that caller.
        await engine.awaitCondition { e in !e.state.groups.values.contains { $0.kind == .ensure } }
        let released = await engine.readForTests { e in !e.state.groups.values.contains { $0.kind == .ensure } }
        try #require(released, "the resumed ensure released its group")
        let answer = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: ensure) }
        let report = try? answer.get()
        #expect(report?.total == 1 && report?.present == 1 && report?.missing == 0 && report?.failed == 0, "the ensure answers zz-e1 present, zz-e2 out of scope: \(answer)")
        await Self.finishHeld(s)
    }

    /// A forced sync's run fetches zz-r (R, held downloading); v3 drops zz-r from the manifest (T21). The follow's visit of
    /// R releases the run's claim (`reroute`, `releaseRunClaim`), so the run settles at once with the same report in
    /// both orders; a claim left on R would wait for a job that no longer reports to the run (step C11).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: a run's claim on an asset that leaves the manifest while it downloads is released, and the run settles (T21, step C11)", .timeLimit(.minutes(1)), arguments: LaneDropVisit.allCases)
    func barrierReleasesARunClaimThatLeftTheManifest(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_022_501
        let (s, _) = try await FollowBarrier.setUp(seed: seed)
        let engine = s.engine
        let rBytes = EngineFixture.bytes(seed + 3, count: 16)
        let r = EngineFixture.entry("zz-r", rBytes)
        await s.harness.source.script(r.transferID, [.hold, .stage(rBytes)])
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [r] + Self.laterFillers(seed + 3_000), etag: "v2")
        let sync = Task { await engine.sync(.force) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in e.state.jobs[r.transferID]?.state == .downloading && e.state.run?.outstanding[r.transferID] == [r.identifier] }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + Self.laterFillers(seed + 6_000), tag: "v3-run-t21-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let outcome = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport?.fetched == 0 && outcome.completeReport?.failures.isEmpty == true, "the run settles with nothing fetched and no failure: \(outcome)")
        await Self.finishHeld(s)
    }
}

/// The progress gate's clauses P1-P3 (Stage 3 close-out cycle 21, step C9; `integrate-c21.md` item C, tests T-PG1 to
/// T-PG3): each test breaks one clause in an idle engine and expects exactly that clause's message.
@Suite("Engine progress gate clauses (close-out cycle 21)")
struct EngineProgressGateTests {
    /// An idle engine after one sync, whose invariants hold.
    @available(macOS 15.0, iOS 18.0, *)
    static func idleEngine(seed: UInt64) async throws -> EngineHarness {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(seed, count: 64)
        let q = EngineFixture.entry("q", bytes)
        await harness.serveManifest([q])
        await harness.scriptTransfers([(q, bytes)])
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        let violations = await harness.engine.invariantViolations()
        try #require(violations.isEmpty, "setup: \(violations.prefix(3))")
        return harness
    }

    /// T-PG1: a trailing emission whose key has no `lastEmitted` entry (clause P1).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: the invariants report a trailing progress emission without a lastEmitted entry (step C9, P1)", .timeLimit(.minutes(1)))
    func reportsATrailingEmissionWithoutLastEmitted() async throws {
        let harness = try await Self.idleEngine(seed: 2_022_301)
        let slot = EventSlot.transfer("zz-p")
        let violations = await harness.engine.readForTests { e in
            e.state.progress.trailing[slot] = .transferProgress("zz-p", TransferProgress(received: 1, expected: nil))
            defer { e.state.progress.trailing[slot] = nil }
            return e.invariantViolations()
        }
        #expect(violations == ["progress trailing \(slot) without lastEmitted"], "\(violations)")
        await harness.engine.shutdown()
    }

    /// T-PG2: a trailing flush in the heap whose key has no `lastEmitted` entry (clause P2); the alarm is re-armed, so
    /// the deadline is covered and no other clause fires.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: the invariants report a progress flush in the heap without a lastEmitted entry (step C9, P2)", .timeLimit(.minutes(1)))
    func reportsAProgressFlushWithoutLastEmitted() async throws {
        let harness = try await Self.idleEngine(seed: 2_022_311)
        let slot = EventSlot.transfer("zz-p")
        let violations = await harness.engine.readForTests { e in
            e.state.heap.schedule(.progress(slot), at: e.environment.time.monotonicNow().adding(seconds: 3_600))
            e.rearm()
            defer {
                e.state.heap.remove(.progress(slot))
                e.rearm()
            }
            return e.invariantViolations()
        }
        #expect(violations == ["progress deadline \(slot) without lastEmitted"], "\(violations)")
        await harness.engine.shutdown()
    }

    /// T-PG3: a subscriber's live `.transfer` slot whose key has no `lastEmitted` entry (clause P3), made by publishing a
    /// transfer's progress straight into the queue of a subscriber that reads nothing.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: the invariants report a subscriber's live transfer slot without a lastEmitted entry (step C9, P3)", .timeLimit(.minutes(1)))
    func reportsALiveTransferSlotWithoutLastEmitted() async throws {
        let harness = try await Self.idleEngine(seed: 2_022_321)
        let subscription = try await harness.engine.subscribe().get()
        let slot = EventSlot.transfer("zz-p")
        let (key, violations) = await harness.engine.readForTests { e -> (UInt64, [String]) in
            guard let key = e.state.subscribers.keys.max() else {
                return (0, ["no subscriber"])
            }
            e.state.lastEventSequence += 1
            let sequence = e.state.lastEventSequence
            _ = e.state.subscribers[key]?.publish(.transferProgress("zz-p", TransferProgress(received: 1, expected: nil)), sequence: sequence)
            defer { e.state.subscribers[key]?.retire(slot) }
            return (key, e.invariantViolations())
        }
        #expect(violations == ["subscriber \(key) holds \(slot) without lastEmitted"], "\(violations)")
        withExtendedLifetime(subscription) {}
        await harness.engine.shutdown()
    }
}
