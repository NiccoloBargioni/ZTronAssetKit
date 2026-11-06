import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 15, correctness lens). Never committed.
///
/// PROBE-C15C-RETRY-FAULT-RACE: `barrierAnswersAPassedJobsRetryAsVisitedFirst` (sweep-first) installs its `.read`
/// `.verifying` nth(1) EIO fault for C's hash once the barrier drained, but nothing orders N's publication (started at
/// once by the follow's visit) before that install. When N's first hash read runs after the install, N takes the fault,
/// N's retry finds no script left and the fake parks it, so B is never answered and the test hits its 3-minute limit
/// (syncx-2: `EngineFollowBarrierAnswerTests.swift:721:6: Time limit was exceeded`, `:781:9` B == cancelled).
@Suite("VerifyC15CorrectFlake")
struct VerifyC15CorrectFlake {
    typealias FollowBarrier = EngineSyncTests.FollowBarrier
    typealias Answer = EngineFollowBarrierTests

    @available(macOS 15.0, iOS 18.0, *)
    struct Scenario {
        let s: FollowBarrier.Setup
        let bulk: SteppedBlockingExecutor
        let a: ManifestEntry
        let b: ManifestEntry
        let c: ManifestEntry
        let bMoved: ManifestEntry
        let nBytes: Data
        let wrong: Data
        let aWaiter: Task<Result<AssetLocation, AssetError>, Never>
        let bWaiter: Task<Result<AssetLocation, AssetError>, Never>
        let cWaiter: Task<Result<AssetLocation, AssetError>, Never>
        let cUnit: Int
    }

    /// The test's own steps up to and including the fault install, sweep-first; `holdN` holds N's download (the forced
    /// variant), otherwise N's script is the test's `[.stage(nBytes)]`.
    @available(macOS 15.0, iOS 18.0, *)
    static func reachFault(seed: UInt64, holdN: Bool) async throws -> Scenario {
        let (s, bulk) = try await Answer.setUpHeldPublications(seed: seed)
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
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b, c] + Answer.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(bMoved.transferID, holdN ? [.hold, .stage(nBytes)] : [.stage(nBytes)])
        await s.harness.source.script(cMoved.transferID, [.stage(n2Bytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        let cWaiter = Task { await engine.awaitAsset(c.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 3 }
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Answer.laterFillers(seed + 6_000)
        try await Answer.applyHeld([s.q] + fillers + [a, bMoved, c] + later, tag: "v3-retry-\(seed)", s, visit: .sweepFollowsFirst)
        let releaser = try await Answer.holdPublication(of: a.transferID, s, bulk: bulk)
        let cUnit = try #require(await bulk.heldUnits.first)
        await Answer.runOneFollowTurn(engine)
        let passed = await engine.readForTests { e in
            (
                owed: e.followOwed, c: e.state.jobs[a.transferID]?.state,
                holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, n: e.state.jobs[bMoved.transferID]?.state
            )
        }
        try #require(passed.owed && passed.c == .verifying && !passed.holdsB, "setup: the follow's turn re-routed B at once, as the test: \(passed)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        releaser.cancel()
        await releaser.value
        s.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .io))
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong)])
        return Scenario(
            s: s, bulk: bulk, a: a, b: b, c: c, bMoved: bMoved, nBytes: nBytes, wrong: wrong,
            aWaiter: aWaiter, bWaiter: bWaiter, cWaiter: cWaiter, cUnit: cUnit
        )
    }

    /// The forced timeline: N's download ends after the fault install (a loaded run's late N), its units run as the
    /// test's releaser runs them, and C's unit is still held. N's first hash read takes the fault, N's retry parks in the
    /// fake (no script left), and B is stranded until the test's time limit. Giving N's retry its bytes then serves B,
    /// so the strand is the test's, not the engine's.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C15C-RETRY-FAULT-RACE (forced)", .timeLimit(.minutes(3)))
    func forced() async throws {
        let x = try await Self.reachFault(seed: 1_317_002, holdN: true)
        let s = x.s
        let engine = s.engine
        let n = x.bMoved.transferID
        let lateReleaser = Task {
            while !Task.isCancelled {
                await x.bulk.waitForHeldUnits(atLeast: 2)
                for other in await x.bulk.heldUnits where other != x.cUnit {
                    await x.bulk.release(other)
                }
            }
        }
        await s.harness.source.release(n, with: .progress(received: 0, expected: nil))
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[n] == nil || ($0.state.jobs[n]?.attempts ?? 0) >= 1 }
        }
        lateReleaser.cancel()
        await lateReleaser.value
        await x.bulk.setHolding(false)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: x.aWaiter) }
        let failed = s.fileSystem.operations.filter { $0.kind == .read && $0.failure != nil }.map { $0.url.lastPathComponent }
        let stranded = await engine.readForTests { e in
            (n: e.state.jobs[n]?.state, attempts: e.state.jobs[n]?.attempts, interests: e.state.jobs[n]?.interests.count, c: e.state.jobs[x.a.transferID]?.state)
        }
        let nStarts = await s.harness.source.starts.filter { $0.id == n }.count
        print("PROBE-C15C-RETRY-FAULT-RACE forced: aResult=\(aResult) stranded=\(stranded) nStarts=\(nStarts) failedReads=\(failed) n=\(n) c=\(x.a.transferID)")
        #expect(stranded.n == nil, "B is served N by the time C has answered A (the test's expectation); instead N's read took the test's fault and its retry parks with no script: \(stranded) nStarts=\(nStarts)")
        await s.harness.source.script(n, [.stage(x.nBytes)])
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: x.bWaiter) }
        print("PROBE-C15C-RETRY-FAULT-RACE forced: once N's retry has bytes, bResult=\(bResult)")
        #expect((try? bResult.get())?.byteSize == 16, "B is served N once N's retry is given bytes: \(bResult)")
    }

    /// The test's own timeline, unforced, in 24 concurrent copies (load): records whose read took the fault.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C15C-RETRY-FAULT-RACE (stress)", .timeLimit(.minutes(3)), arguments: 0..<24)
    func stress(_ copy: Int) async throws {
        let x = try await Self.reachFault(seed: 1_317_002 + UInt64(copy) * 100_000, holdN: false)
        let s = x.s
        let engine = s.engine
        let n = x.bMoved.transferID
        let cID = x.a.transferID
        await x.bulk.setHolding(false)
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                let nDone = e.state.jobs[n] == nil || (e.state.jobs[n]?.attempts ?? 0) >= 1
                let cDone = e.state.jobs[cID] == nil || (e.state.jobs[cID]?.attempts ?? 0) >= 1
                return nDone && cDone
            }
        }
        let state = await engine.readForTests { e in (n: e.state.jobs[n]?.state, nAttempts: e.state.jobs[n]?.attempts, c: e.state.jobs[cID]?.state, cAttempts: e.state.jobs[cID]?.attempts) }
        let failed = s.fileSystem.operations.filter { $0.kind == .read && $0.failure != nil }.map { $0.url.lastPathComponent }
        print("PROBE-C15C-RETRY-FAULT-RACE stress copy=\(copy): \(state) failedReads=\(failed) n=\(n) c=\(cID)")
        #expect(state.nAttempts == nil, "copy \(copy): N's publication is done before the fault, so C's read takes it: \(state) failedReads=\(failed)")
    }
}
