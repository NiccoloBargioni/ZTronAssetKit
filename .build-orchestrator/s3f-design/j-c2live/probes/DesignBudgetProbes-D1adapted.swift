import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch probes (s3f structural design D2 "budget", designer's probes). Never committed as is.
///
/// Each runs one scenario in both visit orders (`LaneDropVisit`): the follow's held turns released and ended before the
/// space event (`followVisitedFirst`, the reference outcome), or the space event while the follow still owes the visits
/// (`sweepFollowsFirst`). The expectations are the visit-first outcome; a probe passes when both orders give it.
///
/// - PROBE-D2-FOLLOW-ORDER: two space-parked user jobs C2 (earlier ticket) and C1; v3 moves their only ids (A1, A2) to
///   new 3.5 MB contents no job holds yet, of which only one fits after the reclaim. The follow's pass finds C1 first
///   (entry order zz-a1 < zz-a2), so its visits create N1 before N2 and N1 is served. A pre-phase that follows the
///   holders in the sweep's order (rank, ticket) creates N2 first and serves N2 instead.
/// - PROBE-D2-INFLIGHT-ABANDON: C (5 MB) downloads for A only; v3 moves A to a 16-byte content, so the follow's visit
///   abandons C's download and its 5 MB leave the ledger. K (3 MB, user) waits for the reclaim. Visit-first, K fits the
///   room the reclaim leaves; judged beside C's in-flight bytes, K is parked and its waiter answered insufficientSpace.
/// - PROBE-D2-JOIN-ABANDON: as INFLIGHT-ABANDON, but K is requested while the follow owes C's visit; the gate parks it
///   `awaitingSpace` (a 1,000-byte reclaim is pending) and the reclaim's sweep decides it beside C's in-flight bytes.
/// - PROBE-D2-PUMP-PROMOTE: one slot, held by D (a user download). C (wanted by A, user) and R (3.5 MB) and P (3 MB),
///   both prefetch, are queued for the slot; 4 MB of room, nothing pending reclaim. v3 moves A onto P's content while
///   the follow owes C's visit; then D ends. Visit-first, P is user work and takes the slot and the room, and R is
///   parked; pump-first, the pump starts R (C's head waits for the follow), and the promotion's preemption frees the
///   slot but not R's in-flight bytes, so P is parked and A's user waiter failed fast.
/// - PROBE-D2-GATE-ABANDON: as JOIN-ABANDON with nothing pending reclaim: the pump's gate (not a sweep) parks K
///   `insufficientSpace` beside C's in-flight bytes and fails its user waiter fast.
@Suite("DesignBudgetProbes", .serialized)
struct DesignBudgetProbes {
    /// An engine over a 32 MB volume with a 60 s deletion grace, after a first sync of `x` (pruned later) and `q`.
    @available(macOS 15.0, iOS 18.0, *)
    static func setUp(xSize: Int, seed: UInt64, tuning: SyncTuning = SyncTuning()) async throws -> (time: ManualTimeSource, fileSystem: FakeFileSystem, harness: EngineHarness, q: ManifestEntry, x: ManifestEntry) {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let harness = EngineHarness.make(time: time, tuning: tuning, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = Data(repeating: 0x81, count: xSize)
        let qBytes = EngineFixture.bytes(seed, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([x, q])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        return (time, fileSystem, harness, q, x)
    }

    /// Changed on-demand entries without jobs that sort before the scenario's ids: the follow's first pass formats
    /// `followFormatsPerTurn` of them and stops before those ids.
    @available(macOS 15.0, iOS 18.0, *)
    static func fillers(_ seed: UInt64) -> [ManifestEntry] {
        (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D2-FOLLOW-ORDER", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func followOrder(_ visit: LaneDropVisit) async throws {
        let (time, fileSystem, harness, q, _) = try await Self.setUp(xSize: 4_000_000, seed: 979_002)
        let engine = harness.engine
        let c1Bytes = Data(repeating: 0x82, count: 5_000_000)
        let c2Bytes = Data(repeating: 0x83, count: 5_000_000)
        let a1 = EngineHarness.onDemand("zz-a1", c1Bytes)
        let a2 = EngineHarness.onDemand("zz-a2", c2Bytes)
        await harness.serveManifest([q] + Self.fillers(770_000) + [a1, a2], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(2_000_000, harness: harness, fileSystem: fileSystem)
        #expect(try await harness.store.freeSpace().pendingReclaim == 4_000_000, "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        await harness.source.script(a1.transferID, [.stage(c1Bytes)])
        await harness.source.script(a2.transferID, [.stage(c2Bytes)])
        // A2's waiter first: C2's job takes the earlier ticket.
        let a2Waiter = Task { await engine.awaitAsset(a2.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a2.transferID]?.state == .blocked(.awaitingSpace) }
        let a1Waiter = Task { await engine.awaitAsset(a1.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a1.transferID]?.state == .blocked(.awaitingSpace) }
        let n1Bytes = Data(repeating: 0x84, count: 3_500_000)
        let n2Bytes = Data(repeating: 0x85, count: 3_500_000)
        let n1 = EngineHarness.onDemand("zz-a1", n1Bytes)
        let n2 = EngineHarness.onDemand("zz-a2", n2Bytes)
        await harness.source.script(n1.transferID, [.stage(n1Bytes)])
        await harness.source.script(n2.transferID, [.stage(n2Bytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + Self.fillers(870_000) + [n1, n2], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                c1: engine.state.jobs[a1.transferID].map { (state: $0.state, ticket: $0.ticket) },
                c2: engine.state.jobs[a2.transferID].map { (state: $0.state, ticket: $0.ticket) },
                n1: engine.state.jobs[n1.transferID].map { (state: $0.state, ticket: $0.ticket) },
                n2: engine.state.jobs[n2.transferID].map { (state: $0.state, ticket: $0.ticket) }
            )
        }
        print("PROBE-D2-FOLLOW-ORDER \(visit) before: \(before)")
        switch visit {
        case .followVisitedFirst:
            let n1Job = try #require(before.n1, "setup: the follow created N1's job")
            let n2Job = try #require(before.n2, "setup: the follow created N2's job")
            #expect(!before.owed && before.c1 == nil && before.c2 == nil && n1Job.ticket < n2Job.ticket, "setup: the follow visited C1 first: \(before)")
        case .sweepFollowsFirst:
            let c1Job = try #require(before.c1, "setup: C1's job waits")
            let c2Job = try #require(before.c2, "setup: C2's job waits")
            #expect(before.owed && before.n1 == nil && before.n2 == nil && c2Job.ticket < c1Job.ticket, "setup: C2 ranks before C1 in the sweep's order: \(before)")
        }
        // The grace ends: the alarm reaps x's 4 MB (6 MB of room) and runs its sweep.
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { engine in
                (engine.spaceDecisionsOwed && engine.state.storeWorkRuns == 0 && engine.state.freeSpace?.pendingReclaim == 0) || engine.state.freeSpace?.pendingReclaim == 0 && engine.state.spaceSweepFollowUp == nil
                    && engine.state.jobs[a1.transferID] == nil && engine.state.jobs[a2.transferID] == nil
                    && engine.state.jobs[n1.transferID]?.state != .blocked(.awaitingSpace) && engine.state.jobs[n2.transferID]?.state != .blocked(.awaitingSpace)
            }
        }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let a1Result = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: a1Waiter) }
        let a2Result = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: a2Waiter) }
        print("PROBE-D2-FOLLOW-ORDER \(visit) A1: \(a1Result) | A2: \(a2Result)")
        #expect((try? a1Result.get())?.byteSize == Int64(n1Bytes.count), "A1's waiter is answered from N1, whose job the follow created first: \(a1Result)")
        if case .failure(.insufficientSpace(let required, let available)) = a2Result {
            #expect(required == Int64(n2Bytes.count) && available < required, "A2's figures: \(a2Result)")
        } else {
            Issue.record("A2's waiter is answered insufficientSpace: N2 does not fit beside N1: \(a2Result)")
        }
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D2-INFLIGHT-ABANDON", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func inflightAbandon(_ visit: LaneDropVisit) async throws {
        try await Self.abandon(visit, reclaim: true)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D2-JOIN-ABANDON", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func joinAbandon(_ visit: LaneDropVisit) async throws {
        try await Self.abandon(visit, reclaim: false)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D2-GATE-ABANDON", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func gateAbandon(_ visit: LaneDropVisit) async throws {
        try await Self.abandon(visit, reclaim: false, pending: false)
    }

    /// INFLIGHT-ABANDON (`reclaim`: K waits for the reclaim, which a sweep judges) and GATE-ABANDON (K is requested while
    /// the follow is owed, and the pump's gate judges it).
    @available(macOS 15.0, iOS 18.0, *)
    ///
    /// JOIN-ABANDON (`reclaim` false, `pending` true): K is requested while the follow is owed and a 1,000-byte reclaim is
    /// pending, so the gate parks it `awaitingSpace` and the reclaim's sweep decides it. GATE-ABANDON (`pending` false):
    /// v2 keeps x, nothing waits for a reclaim, and the gate parks K `insufficientSpace` and fails its waiter fast.
    static func abandon(_ visit: LaneDropVisit, reclaim: Bool, pending: Bool = true) async throws {
        let (time, fileSystem, harness, q, x) = try await Self.setUp(xSize: reclaim ? 4_000_000 : 1_000, seed: 979_102)
        let engine = harness.engine
        let tag = reclaim ? "INFLIGHT-ABANDON" : pending ? "JOIN-ABANDON" : "GATE-ABANDON"
        let kept = pending ? [] : [x]
        let cBytes = Data(repeating: 0x86, count: 5_000_000)
        let kBytes = Data(repeating: 0x87, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        await harness.serveManifest(kept + [q] + Self.fillers(780_000) + [a, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        // 7 MB of room (with a reclaim pending) or 6 MB (without): C starts, K does not fit beside it.
        _ = try await EngineRegressionCycle6Tests.leaveRoom(reclaim ? 7_000_000 : 6_000_000, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        var kWaiter: Task<Result<AssetLocation, AssetError>, Never>?
        if reclaim {
            kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .blocked(.awaitingSpace) }
        }
        // v3 moves A, C's only id, to a 16-byte content: the follow's visit abandons C's download.
        let nBytes = EngineFixture.bytes(979_104, count: 16)
        let n = EngineHarness.onDemand("zz-a", nBytes)
        await harness.source.script(n.transferID, [.stage(nBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest(kept + [q] + Self.fillers(880_000) + [n, k], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (owed: engine.followOwed, c: engine.state.jobs[a.transferID]?.state, k: engine.state.jobs[k.transferID]?.state, inFlight: engine.state.inFlightBytes.clamped)
        }
        print("PROBE-D2-\(tag) \(visit) before: \(before)")
        switch visit {
        case .followVisitedFirst:
            #expect(!before.owed && before.c == nil, "setup: the follow abandoned C: \(before)")
        case .sweepFollowsFirst:
            #expect(before.owed && before.c == .downloading, "setup: C still downloads, its visit owed: \(before)")
        }
        if reclaim {
            // 1 MB of room above the reserve before the reclaim: 5 MB after it, none beside C's 5 MB in flight.
            try await EngineSyncTests.leaveRoom(1_000_000, harness: harness, fileSystem: fileSystem)
            await EngineRegressionCycle6Tests.driving([time], fence: engine) {
                await engine.awaitCondition { ($0.spaceDecisionsOwed && $0.state.storeWorkRuns == 0 && $0.state.freeSpace?.pendingReclaim == 0) || $0.state.jobs[k.transferID]?.state != .blocked(.awaitingSpace) }
            }
        } else {
            // 1 MB of room beside C's 5 MB: K is requested while the follow owes C's visit.
            // K's request runs while the follow owes C's visit (its interest's token marks the request's turn, in which
            // the pump gates K: a fail-fast answer removes the job in that turn).
            let tokenBefore = await engine.readForTests { $0.state.lastToken }
            kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
            await engine.awaitCondition { $0.state.lastToken > tokenBefore }
            if pending {
                // JOIN-ABANDON: the grace ends while the follow is still owed; the reclaim's sweep decides K.
                await EngineRegressionCycle6Tests.driving([time], fence: engine) {
                    await engine.awaitCondition { engine in
                        let state = engine.state.jobs[k.transferID]?.state
                        return (engine.spaceDecisionsOwed && engine.state.storeWorkRuns == 0 && engine.state.freeSpace?.pendingReclaim == 0) || (engine.state.freeSpace?.pendingReclaim == 0 && engine.state.spaceSweepFollowUp == nil && state != .blocked(.awaitingSpace) && state != .queued)
                    }
                }
            }
            let afterRequest = await engine.readForTests { engine in (owed: engine.followOwed, k: engine.state.jobs[k.transferID]?.state, waits: engine.state.pumpWaitsForFollow) }
            print("PROBE-D2-\(tag) \(visit) after K's request: \(afterRequest)")
        }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let waiter = try #require(kWaiter)
        let kResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: waiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        await harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        print("PROBE-D2-\(tag) \(visit) K: \(kResult) | A: \(aResult)")
        #expect((try? kResult.get())?.byteSize == Int64(kBytes.count), "K's user waiter is answered from its content: \(kResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A's waiter is answered from its 16-byte new content: \(aResult)")
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D2-PUMP-PROMOTE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func pumpPromote(_ visit: LaneDropVisit) async throws {
        let (time, fileSystem, harness, q, x) = try await Self.setUp(xSize: 1_000, seed: 979_202, tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0))
        let engine = harness.engine
        let cBytes = Data(repeating: 0x88, count: 5_000_000)
        let dBytes = EngineFixture.bytes(979_204, count: 16)
        let rBytes = Data(repeating: 0x89, count: 3_500_000)
        let pBytes = Data(repeating: 0x8A, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let d = EngineHarness.onDemand("zz-d", dBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        let r = EngineHarness.onDemand("zz-r", rBytes)
        await harness.serveManifest([x, q] + Self.fillers(790_000) + [a, d, p, r], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(4_000_000, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        await harness.source.script(d.transferID, [.hold, .stage(dBytes)])
        await harness.source.script(a.transferID, [.stage(cBytes)])
        await harness.source.script(r.transferID, [.stage(rBytes)])
        await harness.source.script(p.transferID, [.stage(pBytes)])
        let dWaiter = Task { await engine.awaitAsset(d.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[d.transferID]?.state == .downloading }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .queued }
        let rWaiter = Task { await engine.awaitAsset(r.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[r.transferID]?.state == .queued }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .queued }
        let moved = EngineHarness.onDemand("zz-a", pBytes)
        try #require(moved.transferID == p.transferID, "setup: A's new content is P's")
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([x, q] + Self.fillers(890_000) + [moved, d, p, r], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                c: engine.state.jobs[a.transferID].map { (state: $0.state, holdsA: $0.assets.contains(a.identifier)) },
                r: engine.state.jobs[r.transferID].map { (state: $0.state, lane: $0.lane) },
                p: engine.state.jobs[p.transferID].map { (state: $0.state, lane: $0.lane) }
            )
        }
        print("PROBE-D2-PUMP-PROMOTE \(visit) before: \(before)")
        // D ends: its slot frees.
        await harness.source.release(d.transferID, with: .progress(received: 0, expected: nil))
        _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: dWaiter) }
        // The freed slot is given (R or P leaves the queue), or the pump leaves the queues to the owed follow.
        await engine.awaitCondition { $0.state.jobs[r.transferID]?.state != .queued || $0.state.jobs[p.transferID]?.state != .queued || $0.state.pumpWaitsForFollow }
        let started = await engine.readForTests { engine in
            (r: engine.state.jobs[r.transferID]?.state, p: engine.state.jobs[p.transferID]?.state, owed: engine.followOwed)
        }
        print("PROBE-D2-PUMP-PROMOTE \(visit) after D: \(started)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        let rResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: rWaiter) }
        print("PROBE-D2-PUMP-PROMOTE \(visit) A: \(aResult) | P: \(pResult) | R: \(rResult)")
        #expect((try? aResult.get())?.byteSize == Int64(pBytes.count), "A's user waiter, moved onto P, is answered from P's 3 MB: \(aResult)")
        if case .failure(.insufficientSpace(let required, let available)) = rResult {
            #expect(required == Int64(rBytes.count) && available < required, "R's figures: \(rResult)")
        } else {
            Issue.record("R's prefetch waiter is answered insufficientSpace: R does not fit beside P: \(rResult)")
        }
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.shutdown()
    }

    /// PROBE-D2-READ-ORDER (boundary, not the sweep's judging): C (5 MB) downloads for A (user) and B (prefetch); P (3 MB)
    /// is a prefetch group's member parked `insufficientSpace` (1 MB beside C). v3 moves A onto P's content while the
    /// follow owes C's visit. Then the ballast is removed and a free-space read runs. Visit-first, A's interest joins P
    /// before the read: `failFastJoiner` answers it `insufficientSpace` with the room of that moment. Read-first, the
    /// interest joins P after the read (the sweep's bring-forward, or the follow's own turn), and `relane` re-queues P.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D2-READ-ORDER", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func readOrder(_ visit: LaneDropVisit) async throws {
        let (time, fileSystem, harness, q, x) = try await Self.setUp(xSize: 1_000, seed: 979_302)
        let engine = harness.engine
        let cBytes = Data(repeating: 0x8B, count: 5_000_000)
        let pBytes = Data(repeating: 0x8C, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        await harness.serveManifest([x, q] + Self.fillers(795_000) + [a, b, p], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        let ballast = try await EngineRegressionCycle6Tests.leaveRoom(6_000_000, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await harness.source.script(p.transferID, [.stage(pBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let group = try await engine.registerGroup([p.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .blocked(.insufficientSpace) }
        let moved = EngineHarness.onDemand("zz-a", pBytes)
        try #require(moved.transferID == p.transferID, "setup: A's new content is P's")
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([x, q] + Self.fillers(895_000) + [moved, b, p], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        // Room appears (the ballast goes) and a free-space read runs.
        try fileSystem.removeItem(at: ballast)
        await engine.refreshFreeSpace()
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { ($0.spaceDecisionsOwed && $0.state.storeWorkRuns == 0 && $0.state.freeSpace?.pendingReclaim == 0) || ($0.state.jobs[p.transferID]?.state != .blocked(.insufficientSpace) && $0.state.spaceSweepFollowUp == nil) }
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        await harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        let bResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("PROBE-D2-READ-ORDER \(visit) A: \(aResult) | B: \(bResult)")
        // The reference is the visit-first answer.
        if case .failure(.insufficientSpace) = aResult {
        } else {
            Issue.record("A's waiter gets the visit-first answer (insufficientSpace at its join, before the read): \(aResult)")
        }
        #expect((try? bResult.get())?.byteSize == Int64(cBytes.count), "B is answered from C: \(bResult)")
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }
}
