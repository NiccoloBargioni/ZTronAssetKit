import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 19, correctness lens). Never committed.
///
/// PROBE-C19C-DRAIN-BOUND: the drain's visits after verdicts (`followAfterVerdict`) each get a whole turn's id budget
/// (`followIDsPerTurn`), and a drain batch replays many verdicts in one turn, so one turn moves more ids than
/// `followIDsPerTurn` (the bound cycle 19 states for every follow turn).
@Suite("VerifyC19Correct", .serialized)
struct VerifyC19Correct {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier
    typealias T = EngineFollowBarrierTests

    /// Three jobs J0..J2 (16 B each), each shared by three prefetch members, download. v3 changes only fillers (the
    /// follow is owed, held). The three attempts time out (a retry below every cap: the interests stay). v4 gives each
    /// member a content of its own. Sweep-first, the three verdicts wait, v4's visits leave the jobs to them, and the drain
    /// gives them and then moves each job's ids (`followAfterVerdict`). `followIDsPerTurn` is set to 4.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C19C-DRAIN-BOUND", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases, [false, true])
    func drainBound(_ visit: LaneDropVisit, _ defaultTuning: Bool) async throws {
        let seed: UInt64 = 1_919_902
        let jobsCount = 3
        let perJob = 3
        let bound = 4
        // `defaultTuning`: the engine's default slots (4, one reserved for user work: three prefetch downloads at once).
        let tuning = defaultTuning ? SyncTuning() : SyncTuning(maxConcurrentTransfers: 12, reservedInteractiveSlots: 4)
        let (s, _) = try await T.setUpHeldPublications(seed: seed, tuning: tuning)
        let engine = s.engine
        await engine.readForTests { $0.state.followIDsPerTurn = bound }
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
        let jTransfers = (0..<jobsCount).map { onJ[$0 * perJob].transferID }
        try #require(Set(jTransfers).count == jobsCount && Set(own.map(\.transferID)).count == own.count, "setup: distinct contents")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + onJ + T.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let timeout = TransferError.transient(.timedOut, retryAfter: nil)
        for k in 0..<jobsCount {
            await s.harness.source.script(jTransfers[k], [.hold, .fail(timeout), .stage(jBytes[k])])
        }
        for (entry, bytes) in zip(own, ownBytes) {
            await s.harness.source.script(entry.transferID, [.stage(bytes)])
        }
        var waiters: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for entry in onJ {
            let id = entry.identifier
            waiters.append(Task { await engine.awaitAsset(id, lane: .prefetch) })
        }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                e.state.conditions != nil && jTransfers.allSatisfy { e.state.jobs[$0]?.state == .downloading && e.state.jobs[$0]?.interests.count == perJob }
            }
        }
        try await T.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + onJ + T.laterFillers(seed + 6_000), tag: "v3-drainbound-\(seed)", s, visit: visit)
        for transfer in jTransfers {
            await s.harness.source.release(transfer, with: .progress(received: 0, expected: nil))
        }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { e in jTransfers.allSatisfy { e.state.verdictsAfterFollow[$0] != nil } }
        } else {
            await engine.awaitCondition { e in jTransfers.allSatisfy { e.state.jobs[$0]?.state != .downloading } }
        }
        let ids = onJ.map(\.identifier)
        let leftOn: @Sendable (isolated SyncEngine) -> Int = { e in
            ids.filter { id in jTransfers.contains { e.state.jobs[$0]?.assets.contains(id) == true } }.count
        }
        let atV4 = await engine.readForTests(leftOn)
        try await T.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + own + T.laterFillers(seed + 9_000), tag: "v4-drainbound-\(seed)", s, visit: visit)
        var before = await engine.readForTests(leftOn)
        var turns: [Int] = [atV4 - before]
        var drainTurn: Int?
        if visit == .sweepFollowsFirst {
            while await engine.readForTests({ $0.followOwed }) {
                try #require(turns.count < 40, "the follow ends within 40 turns: \(turns)")
                let waiting = await engine.readForTests { e in jTransfers.filter { e.state.verdictsAfterFollow[$0] != nil }.count }
                await T.runOneFollowTurn(engine)
                let now = await engine.readForTests(leftOn)
                turns.append(before - now)
                let after = await engine.readForTests { e in (e.followOwed, jTransfers.filter { e.state.verdictsAfterFollow[$0] != nil }.count) }
                if waiting > 0, after.1 == 0 {
                    drainTurn = before - now
                }
                before = now
            }
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        var answers: [Int64] = []
        for waiter in waiters {
            let result = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: waiter) }
            answers.append((try? result.get())?.byteSize ?? -1)
        }
        let jStarts = await s.harness.source.starts.filter { jTransfers.contains($0.id) }.count
        print("PROBE-C19C-DRAIN-BOUND \(visit) defaultTuning \(defaultTuning) bound \(bound) atV4 \(atV4) turns \(turns) drainTurn \(String(describing: drainTurn)) answers \(answers) jStarts \(jStarts)")
        #expect(answers.allSatisfy { $0 == 20 }, "every member is served its own content's 20 bytes: \(answers)")
        // Visit-first releases the whole follow at once (`applyHeld`), so its single figure is not a turn: only the
        // sweep-first loop above counts turns.
        #expect(visit != .sweepFollowsFirst || turns.allSatisfy { $0 <= bound }, "PROBE-C19C-DRAIN-BOUND: no follow turn moves more than followIDsPerTurn (\(bound)) ids: \(turns), drain turn \(String(describing: drainTurn))")
        await T.finishHeld(s)
    }
}
