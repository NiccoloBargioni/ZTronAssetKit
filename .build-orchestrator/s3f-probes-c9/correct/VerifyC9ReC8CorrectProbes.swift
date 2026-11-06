import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 8, correctness lens). Never committed.
///
/// PROBE-C8-RANK-*: the cycle-7 blocking scenarios (ADMIT, PARK, PROMOTE) re-run against the cycle-8 code, in both
/// visit orders.
///
/// PROBE-C8-DROPPED*: the sweep's pre-phase follows only jobs that `holdsMovedID`, which does not count an id the copy no
/// longer lists. A space-parked job whose user lane comes from a DROPPED id (v3 no longer lists it) is judged at its
/// pre-follow user place, re-queued and counted `ahead`, although it cannot start (`awaitsFollow`) and the follow's visit
/// will end the dropped id's interest `.notFound` (and supersede the job, or lower it to prefetch). The user job K behind
/// it is parked `insufficientSpace` and its waiter answered with a shortage. Visited first, the follow removes the
/// dropped interest and the same sweep serves K.
@Suite("VerifyC9ReC8CorrectProbes", .serialized)
struct VerifyC9ReC8CorrectProbes {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C8-RANK-ADMIT", .timeLimit(.minutes(3)), arguments: [true, false])
    func rankAdmit(_ visitFirst: Bool) async throws {
        try await Self.run(visitFirst: visitFirst, importantExtra: 32_000_000, opportunisticExtra: 32_000_000, leave: 2_000_000, leaveAgain: 1_999_000, kSize: 3_000_000, tag: "admit", mode: .moveA)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C8-RANK-PARK", .timeLimit(.minutes(3)), arguments: [true, false])
    func rankPark(_ visitFirst: Bool) async throws {
        try await Self.run(visitFirst: visitFirst, importantExtra: 26_000_000, opportunisticExtra: 30_000_000, leave: 0, leaveAgain: nil, kSize: 3_900_000, tag: "park", mode: .moveA)
    }

    /// C is wanted only by A (user); v3 drops A's id.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C8-DROPPED: a job whose only id the copy dropped is not admitted ahead of a user job", .timeLimit(.minutes(3)), arguments: [true, false])
    func dropped(_ visitFirst: Bool) async throws {
        try await Self.run(visitFirst: visitFirst, importantExtra: 32_000_000, opportunisticExtra: 32_000_000, leave: 2_000_000, leaveAgain: 1_999_000, kSize: 3_000_000, tag: "dropped", mode: .dropAOnly)
    }

    /// C is wanted by A (user) and B (prefetch); v3 drops A's id and keeps B's: C's user lane comes only from the
    /// dropped id.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C8-DROPPED-KEEP: a job whose user lane comes from a dropped id is judged at its prefetch place", .timeLimit(.minutes(3)), arguments: [true, false])
    func droppedKeep(_ visitFirst: Bool) async throws {
        try await Self.run(visitFirst: visitFirst, importantExtra: 32_000_000, opportunisticExtra: 32_000_000, leave: 2_000_000, leaveAgain: 1_999_000, kSize: 3_000_000, tag: "dropped-keep", mode: .dropAKeepB)
    }

    /// C (5 MB) is wanted by A (user) and B (prefetch); v3 drops A's id and keeps B's. After the reclaim the important
    /// volume has 4 MB and the opportunistic one 12 MB. Followed first, C is prefetch work judged after K (3 MB, user,
    /// important room): K fits, and C fits the opportunistic room K leaves (9 MB), so B is served. Judged at its
    /// pre-follow user place, C does not fit the important room and is parked: B's prefetch waiter is answered
    /// `insufficientSpace` although C's own lane has room.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C8-DROPPED-LANE: a job whose user lane comes from a dropped id is judged on its own lane's volume", .timeLimit(.minutes(3)), arguments: [true, false])
    func droppedLane(_ visitFirst: Bool) async throws {
        try await Self.run(visitFirst: visitFirst, importantExtra: 26_000_000, opportunisticExtra: 34_000_000, leave: 0, leaveAgain: nil, kSize: 3_000_000, tag: "dropped-lane", mode: .dropAKeepB, expectBServed: true)
    }

    enum Mode: Sendable {
        case moveA
        case dropAOnly
        case dropAKeepB
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func run(visitFirst: Bool, importantExtra: Int64, opportunisticExtra: Int64, leave: Int64, leaveAgain: Int64?, kSize: Int, tag: String, mode: Mode, expectBServed: Bool = false) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + importantExtra, opportunisticCapacity: reserve + opportunisticExtra)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = Data(repeating: 0x71, count: 4_000_000)
        let qBytes = EngineFixture.bytes(987_002, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([x, q])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        let cBytes = Data(repeating: 0x72, count: 5_000_000)
        let kBytes = Data(repeating: 0x73, count: kSize)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share one content")
        let withB = mode != .dropAOnly
        await harness.serveManifest([q] + fillers(741_000) + (withB ? [a, b, k] : [a, k]), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(leave, harness: harness, fileSystem: fileSystem)
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.stage(cBytes)])
        await harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }
        var bWaiter: Task<Result<AssetLocation, AssetError>, Never>?
        if withB {
            bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
            await engine.awaitCondition { $0.state.jobs[a.transferID]?.assets.count == 2 }
        }
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .blocked(.awaitingSpace) }
        let replacementBytes = EngineFixture.bytes(987_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        let v3: [ManifestEntry]
        switch mode {
        case .moveA:
            v3 = [q] + fillers(841_000) + [replacement, b, k]
        case .dropAOnly:
            v3 = [q] + fillers(841_000) + [k]
        case .dropAKeepB:
            v3 = [q] + fillers(841_000) + [b, k]
        }
        await harness.serveManifest(v3, etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visitFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                cHolds: engine.state.jobs[a.transferID].map { engine.holdsMovedID($0) },
                cRank: engine.state.jobs[a.transferID].map { engine.queueRank($0) },
                cTicket: engine.state.jobs[a.transferID]?.ticket,
                kRank: engine.state.jobs[k.transferID].map { engine.queueRank($0) },
                kTicket: engine.state.jobs[k.transferID]?.ticket,
                c: engine.state.jobs[a.transferID]?.state,
                k: engine.state.jobs[k.transferID]?.state
            )
        }
        print("PROBE-C8-\(tag) visitFirst=\(visitFirst) before: \(before)")
        #expect(before.k == .blocked(.awaitingSpace), "setup: \(before)")
        if !visitFirst {
            #expect(before.owed && before.c == .blocked(.awaitingSpace), "setup: \(before)")
        }
        if let leaveAgain {
            try await EngineSyncTests.leaveRoom(leaveAgain, harness: harness, fileSystem: fileSystem)
        }
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state != .blocked(.awaitingSpace) }
        }
        let afterSweep = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                c: engine.state.jobs[a.transferID]?.state,
                cAdmitted: engine.state.spaceAdmitted[a.transferID] != nil,
                k: engine.state.jobs[k.transferID]?.state,
                kError: engine.state.jobs[k.transferID]?.lastError,
                violations: engine.invariantViolations()
            )
        }
        print("PROBE-C8-\(tag) visitFirst=\(visitFirst) afterSweep: \(afterSweep)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let kResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        var bDescription = "-"
        if let bWaiter {
            let bResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: bWaiter) }
            bDescription = "\(bResult)"
            if expectBServed {
                #expect((try? bResult.get())?.byteSize == 5_000_000, "PROBE-C8-\(tag): B's prefetch waiter is answered from C's content: \(bResult)")
            }
        }
        print("PROBE-C8-\(tag) visitFirst=\(visitFirst) kResult: \(kResult) aResult: \(aResult) bResult: \(bDescription)")
        #expect((try? kResult.get())?.byteSize == Int64(kBytes.count), "PROBE-C8-\(tag): K's user waiter is answered from its content: \(kResult)")
        switch mode {
        case .moveA:
            #expect((try? aResult.get())?.byteSize == 16, "A's waiter is answered from its 16-byte new content: \(aResult)")
        case .dropAOnly, .dropAKeepB:
            #expect(aResult == .failure(.notFound), "A's dropped id is answered notFound: \(aResult)")
        }
        #expect(afterSweep.violations.isEmpty, "\(afterSweep.violations.prefix(3))")
        _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        await engine.shutdown()
    }

    /// PROBE-C8-RANK-PROMOTE: the cycle-7 mirror case, re-run.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C8-RANK-PROMOTE", .timeLimit(.minutes(3)), arguments: [true, false])
    func rankPromote(_ visitFirst: Bool) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = Data(repeating: 0x74, count: 4_000_000)
        let qBytes = EngineFixture.bytes(988_002, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([x, q])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        let cBytes = Data(repeating: 0x75, count: 5_000_000)
        let rBytes = Data(repeating: 0x76, count: 3_500_000)
        let pBytes = Data(repeating: 0x77, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let r = EngineHarness.onDemand("zz-r", rBytes)
        let p = EngineHarness.onDemand("zz-p", pBytes)
        await harness.serveManifest([q] + fillers(761_000) + [a, p, r], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(2_000_000, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.stage(cBytes)])
        await harness.source.script(r.transferID, [.stage(rBytes)])
        await harness.source.script(p.transferID, [.stage(pBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }
        let rWaiter = Task { await engine.awaitAsset(r.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[r.transferID]?.state == .blocked(.awaitingSpace) }
        let pWaiter = Task { await engine.awaitAsset(p.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state == .blocked(.awaitingSpace) }
        let moved = EngineHarness.onDemand("zz-a", pBytes)
        try #require(moved.transferID == p.transferID, "setup: A's new content is P's")
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(861_000) + [moved, p, r], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visitFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                c: engine.state.jobs[a.transferID].map { ($0.state, engine.queueRank($0), $0.ticket) },
                r: engine.state.jobs[r.transferID].map { ($0.state, engine.queueRank($0), $0.ticket) },
                p: engine.state.jobs[p.transferID].map { ($0.state, engine.queueRank($0), $0.ticket, $0.lane) }
            )
        }
        print("PROBE-C8-RANK-PROMOTE visitFirst=\(visitFirst) before: \(before)")
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[r.transferID]?.state != .blocked(.awaitingSpace) }
        }
        let violations = await engine.invariantViolations()
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let rResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: rWaiter) }
        let pResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: pWaiter) }
        print("PROBE-C8-RANK-PROMOTE visitFirst=\(visitFirst) aResult: \(aResult) rResult: \(rResult) pResult: \(pResult)")
        #expect((try? aResult.get())?.byteSize == Int64(pBytes.count), "PROBE-C8-RANK-PROMOTE: A's user waiter is answered from P's content: \(aResult)")
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        await engine.shutdown()
    }
}
