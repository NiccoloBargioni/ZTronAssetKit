import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The drain's visits after verdicts move one turn's ids together (Stage 3 close-out cycle 20, ruling S3-R25 item 1; the
/// cycle-19 correctness verifier's PROBE-C19C-DRAIN-BOUND): a drain batch replays every verdict that waited, and each
/// verdict after which an apply's ids move off its job ends in a visit (`followAfterVerdict`). Those visits share the
/// ids the turn has left, the follow's last turn included, and once they are spent the rest of the batch waits for the
/// next drain turn. The bound is set small (`EngineState.followIDsPerTurn`, S3-R23 item 3), so three verdicts of three
/// ids span turns. Each case runs in both orders (`LaneDropVisit`) with the visit-first answers expected in both;
/// sweep-first the follow's and the drain's turns run one at a time and each turn's moved ids are counted.
extension EngineFollowBarrierTests {
    /// The ids a turn moves in these tests: three verdicts of three ids each take three turns.
    static let drainBoundIDsPerTurn = 4

    /// What else the follow's last turn moves before its drain.
    enum DrainBoundShape: String, Sendable, CaseIterable {
        /// Nothing: the follow's turns pass the three jobs, whose verdicts wait, and its last turn's drain has every id.
        case verdicts
        /// v4 also gives a content of its own to each of the six members of B (zzzzz-b0…b5, sharing one content, queued
        /// behind the three jobs), whose visit in the follow's turns moves four and leaves two to the follow's last turn,
        /// so that turn's drain has the ids the rest left.
        case verdictsAfterARest
    }

    /// Which held turn ran (`runOneHeldTurn`).
    enum HeldTurn: String, Sendable {
        /// A follow turn (`followFollowUp`).
        case follow
        /// A drain turn (`drainFollowUp`).
        case drain
    }

    /// What `drainBound` reads: every member's answer in member order, the ids each sweep-first turn moved off the jobs
    /// the members held before v4, which kind of turn each was, and the jobs' starts.
    struct DrainBoundOutcome {
        /// The byte counts served, in member order (J's members, then B's); `-1` for an error.
        let answers: [Int64]
        /// The ids each sweep-first turn moved off the members' jobs, v4's apply's turn first (empty visited first).
        let turns: [Int]
        /// The kind of each sweep-first turn after v4's apply (empty visited first).
        let kinds: [HeldTurn]
        /// The starts of J0, J1 and J2.
        let jStarts: Int
    }

    /// Runs exactly one held follow or drain turn, and holds the next ones again.
    @available(macOS 15.0, iOS 18.0, *)
    static func runOneHeldTurn(_ engine: SyncEngine) async -> HeldTurn {
        await engine.awaitCondition { $0.state.followFollowUpWaiting || $0.state.drainFollowUpWaiting }
        return await engine.readForTests { e in
            if e.state.followFollowUpWaiting {
                e.releaseFollowFollowUps()
                e.holdFollowFollowUps()
                return .follow
            }
            e.releaseDrainFollowUps()
            e.holdDrainFollowUps()
            return .drain
        }
    }

    /// Three jobs J0, J1 and J2 (16 bytes each), each shared by three prefetch members (zz-j<k>-m<m>, a waiter each),
    /// download. v3 changes only the fillers, so behind the barrier its follow is owed when the three attempts time out
    /// (a retry below every cap: the interests stay), and the three verdicts wait. v4 gives every member a content of its
    /// own (20 bytes), so its follow passes the three jobs and the drain moves their members after each verdict. With
    /// `.verdictsAfterARest`, B (zzzzz-b0…b5, queued behind the three) shares one content until v4 gives each of its
    /// members its own. Visited first, each verdict was given at its arrival and v4's visits moved every member at the
    /// apply.
    @available(macOS 15.0, iOS 18.0, *)
    func drainBound(_ visit: LaneDropVisit, seed: UInt64, shape: DrainBoundShape) async throws -> DrainBoundOutcome {
        let jobsCount = 3
        let perJob = 3
        let (s, _) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = Self.drainBoundIDsPerTurn }
        let jBytes = (0..<jobsCount).map { EngineFixture.bytes(seed + 3 + UInt64($0), count: 16) }
        var onJ: [ManifestEntry] = []
        var own: [ManifestEntry] = []
        var ownBytes: [Data] = []
        for k in 0..<jobsCount {
            for m in 0..<perJob {
                let name = String(format: "zz-j%d-m%d", k, m)
                onJ.append(EngineHarness.onDemand(name, jBytes[k]))
                let bytes = EngineFixture.bytes(seed + 10_000 + UInt64(k * 100 + m), count: 20)
                ownBytes.append(bytes)
                own.append(EngineHarness.onDemand(name, bytes))
            }
        }
        let bBytes = EngineFixture.bytes(seed + 7, count: 16)
        let bNames = shape == .verdictsAfterARest ? (0..<6).map { "zzzzz-b\($0)" } : []
        let onB = bNames.map { EngineHarness.onDemand($0, bBytes) }
        let bOwnBytes = bNames.indices.map { EngineFixture.bytes(seed + 20_000 + UInt64($0), count: 20) }
        let bOwn = zip(bNames, bOwnBytes).map { EngineHarness.onDemand($0.0, $0.1) }
        let jTransfers = (0..<jobsCount).map { onJ[$0 * perJob].transferID }
        try #require(Set(jTransfers).count == jobsCount && Set((own + bOwn).map(\.transferID)).count == own.count + bOwn.count, "setup: distinct contents")
        let fillers = FollowBarrier.fillers(seed + 200)
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + onJ + Self.laterFillers(seed + 3_000) + onB, etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let timeout = TransferError.transient(.timedOut, retryAfter: nil)
        for k in 0..<jobsCount {
            await s.harness.source.script(jTransfers[k], [.hold, .fail(timeout), .stage(jBytes[k])])
        }
        if let b = onB.first {
            await s.harness.source.script(b.transferID, [.hold, .stage(bBytes)])
        }
        for (entry, bytes) in zip(own + bOwn, ownBytes + bOwnBytes) {
            await s.harness.source.script(entry.transferID, [.stage(bytes)])
        }
        var waiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for entry in onJ + onB {
            let id = entry.identifier
            waiters.append(Task { await engine.awaitAsset(id, lane: .prefetch) })
        }
        let bTransfer = onB.first?.transferID
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                e.state.conditions != nil && jTransfers.allSatisfy { e.state.jobs[$0]?.state == .downloading && e.state.jobs[$0]?.interests.count == perJob }
                    && bTransfer.map { e.state.jobs[$0]?.interests.count == 6 } ?? true
            }
        }
        try await Self.applyHeld([s.q] + fillers + onJ + Self.laterFillers(seed + 6_000) + onB, tag: "v3-drain-bound-\(shape.rawValue)-\(seed)", s, visit: visit)
        for transfer in jTransfers {
            await s.harness.source.release(transfer, with: .progress(received: 0, expected: nil))
        }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { e in jTransfers.allSatisfy { e.state.verdictsAfterFollow[$0] != nil } }
        } else {
            await engine.awaitCondition { e in jTransfers.allSatisfy { e.state.jobs[$0]?.state != .downloading } }
        }
        let ids = (onJ + onB).map(\.identifier)
        let holders = jTransfers + (bTransfer.map { [$0] } ?? [])
        let held: @Sendable (isolated SyncEngine) -> Int = { e in
            ids.filter { id in holders.contains { e.state.jobs[$0]?.assets.contains(id) == true } }.count
        }
        let atV4 = await engine.readForTests(held)
        try await Self.applyHeld([s.q] + fillers + own + Self.laterFillers(seed + 9_000) + bOwn, tag: "v4-drain-bound-\(shape.rawValue)-\(seed)", s, visit: visit)
        var before = await engine.readForTests(held)
        var turns: [Int] = []
        var kinds: [HeldTurn] = []
        if visit == .sweepFollowsFirst {
            // v4's apply's own turn, then the follow's and the drain's held turns one at a time.
            turns.append(atV4 - before)
            await engine.readForTests { $0.holdDrainFollowUps() }
            while await engine.readForTests({ $0.followBarrier }) {
                // The time limit's cancellation ends the wait for a held turn, not this loop.
                try #require(kinds.count < 40, "the follow and its drain end within 40 turns: \(turns) \(kinds)")
                kinds.append(await Self.runOneHeldTurn(engine))
                let now = await engine.readForTests(held)
                turns.append(before - now)
                before = now
            }
            await engine.readForTests { e in
                e.releaseFollowFollowUps()
                e.releaseDrainFollowUps()
            }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        var answers: [Int64] = []
        for waiter in waiters {
            let result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) }
            answers.append((try? result.get())?.byteSize ?? -1)
        }
        let jStarts = await s.harness.source.starts.filter { jTransfers.contains($0.id) }.count
        await Self.finishHeld(s)
        return DrainBoundOutcome(answers: answers, turns: turns, kinds: kinds, jStarts: jStarts)
    }

    /// The drain's visits after verdicts move at most one turn's ids together: their visits share what the turn has
    /// left (the follow's last turn's, after its own visits), and once those are spent the batch's rest waits for the
    /// next drain turn (`drainEventsAfterFollow`, `followAfterVerdict`). Every member gets its own content's bytes, as a
    /// visit-first engine's v4 visits moved them at the apply.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: the drain's visits after the verdicts that waited move at most followIDsPerTurn ids a turn together, with the visit-first answers (C2, F-28)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, DrainBoundShape.allCases)
    func barrierBoundsTheDrainsVisitsAfterVerdictsByOneTurnsIDs(_ visit: LaneDropVisit, _ shape: DrainBoundShape) async throws {
        let outcome = try await self.drainBound(visit, seed: 2_020_102, shape: shape)
        let members = shape == .verdictsAfterARest ? 15 : 9
        #expect(outcome.answers.count == members && outcome.answers.allSatisfy { $0 == 20 }, "every member is served its own content's 20 bytes (visit-first): \(outcome.answers)")
        #expect(outcome.jStarts == 3, "each of J0, J1 and J2 starts once: their members leave them after the verdicts (visit-first): \(outcome.jStarts)")
        guard visit == .sweepFollowsFirst else {
            return
        }
        let bound = Self.drainBoundIDsPerTurn
        #expect(outcome.turns.reduce(0, +) == members, "every member leaves its job over the turns: \(outcome.turns)")
        #expect(outcome.turns.allSatisfy { $0 <= bound }, "no follow or drain turn moves more than followIDsPerTurn = \(bound) ids: \(outcome.turns) \(outcome.kinds)")
        if shape == .verdictsAfterARest {
            // The follow's last turn moves the two members B's visit left and the first two of J0's, and the next follow
            // turn J0's last and J1's three; J2's verdict then waits for a drain turn of its own, with a fresh turn's ids,
            // instead of a visit that the spent turn could not move.
            #expect(outcome.turns.suffix(3) == [4, 4, 3] && outcome.kinds.suffix(2) == [.follow, .drain], "the drain's batch stops once the turn's ids are spent and its rest waits for the next drain turn: \(outcome.turns) \(outcome.kinds)")
        }
    }
}
