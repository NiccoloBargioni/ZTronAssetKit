import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch probes (s3f close-out verification, cycle 6, correctness lens). Never committed.
///
/// PROBE-C6-READDROP: the cycle-5 lane-drop defect reproduced through a different sweep and different interests. A
/// free-space read's `.read` sweep (`refreshFreeSpace` -> `reconsiderSpaceBlocked`), not the reclaim's `.reclaimed` one,
/// and only group interests (no waiter, so no fail-fast hides the outcome). Content C (5 MB) is wanted by A through a
/// user-lane group and by B through a prefetch group, so its job is user-lane; K (3 MB) is wanted by a user-lane group.
/// Both are parked `insufficientSpace` (2 MB of important room, none opportunistic, nothing pending reclaim). A forced
/// sync moves A to a 16-byte content while 2,100 changed fillers sort before it, so the bounded follow owes C's visit
/// (held). The volume then gains room: 6 MB important, still none opportunistic, and a free-space read sweeps.
///
/// Right outcome (the one the sweep gives when the follow visited first): C's job is prefetch-lane, does not fit and stays
/// parked; K fits the 6 MB and is re-queued. Pre-fix (`39dadd4` / `48c8dfc`): the sweep judged C on its user lane (fits),
/// followed it (A leaves, lane drops to prefetch), re-queued it and counted its 5 MB ahead, so K was judged against 1 MB
/// and left parked although 6 MB are free; the gate then parks C again.
@Suite("VerifyC6CorrectProbes", .serialized)
struct VerifyC6CorrectProbes {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C6-READDROP: a read sweep's re-queue after a partial follow takes no room from the next user job", .timeLimit(.minutes(1)), arguments: [true, false])
    func readSweepLaneDrop(_ visitFirst: Bool) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 26_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let qBytes = EngineFixture.bytes(990_002, count: 300)
        let q = EngineFixture.entry("q", qBytes)
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        let cBytes = Data(repeating: 0x43, count: 5_000_000)
        let kBytes = Data(repeating: 0x4B, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        try #require(a.transferID == b.transferID, "setup: A and B share one content")
        await harness.serveManifest([q] + fillers(730_000) + [a, b, k])
        await harness.scriptTransfers([(q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        let free0 = try await harness.store.freeSpace()
        #expect(free0.pendingReclaim == 0, "setup: nothing pending reclaim: \(free0)")
        let ballastURL = EngineHarness.base.appendingPathComponent("ballast-c6")
        var ballast = free0.volumeImportant - free0.reserveBytes - 2_000_000
        try fileSystem.write(Data(repeating: 3, count: Int(ballast)), to: ballastURL, mode: .truncate)
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.hold])
        await harness.source.script(k.transferID, [.hold])
        let groupA = try await engine.registerGroup([a.identifier], lane: .userInitiated).get()
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.insufficientSpace) }
        let groupB = try await engine.registerGroup([b.identifier], lane: .prefetch).get()
        let groupK = try await engine.registerGroup([k.identifier], lane: .userInitiated).get()
        await engine.awaitCondition { engine in
            engine.state.jobs[k.transferID]?.state == .blocked(.insufficientSpace) && engine.state.jobs[a.transferID]?.assets.count == 2
        }
        let replacementBytes = EngineFixture.bytes(990_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(830_000) + [replacement, b, k], etag: "v2")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visitFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                lane: engine.state.jobs[a.transferID]?.lane,
                ids: engine.state.jobs[a.transferID]?.assets.count,
                c: engine.state.jobs[a.transferID]?.state,
                k: engine.state.jobs[k.transferID]?.state
            )
        }
        if visitFirst {
            #expect(!before.owed && before.lane == .prefetch && before.ids == 1, "setup: \(before)")
        } else {
            #expect(before.owed && before.lane == .userInitiated && before.ids == 2, "setup: \(before)")
        }
        #expect(before.c == .blocked(.insufficientSpace) && before.k == .blocked(.insufficientSpace), "setup: \(before)")
        // 6 MB of room for user work, none for prefetch work: shrink the ballast.
        let free1 = try await harness.store.freeSpace()
        ballast -= 6_000_000 - (free1.volumeImportant - free1.reserveBytes)
        try fileSystem.write(Data(repeating: 3, count: Int(ballast)), to: ballastURL, mode: .truncate)
        await engine.refreshFreeSpace()
        let after = await engine.readForTests { engine in
            (
                owed: engine.followOwed,
                lane: engine.state.jobs[a.transferID]?.lane,
                c: engine.state.jobs[a.transferID]?.state,
                k: engine.state.jobs[k.transferID]?.state,
                space: engine.state.freeSpace,
                violations: engine.invariantViolations()
            )
        }
        print("PROBE-C6-READDROP visitFirst=\(visitFirst) before=\(before) after=(owed: \(after.owed), lane: \(String(describing: after.lane)), c: \(String(describing: after.c)), k: \(String(describing: after.k)), space: \(String(describing: after.space)), violations: \(after.violations.count))")
        #expect(after.owed == !visitFirst, "the read swept while the follow owed C's visit only when it had not visited first: \(after.owed)")
        #expect(after.k != .blocked(.insufficientSpace), "K (3 MB, user lane) fits 6 MB of room for user work: \(String(describing: after.k))")
        #expect(after.lane == .prefetch && after.c == .blocked(.insufficientSpace), "C's job, left with B's prefetch interest, waits for room prefetch work lacks: \(String(describing: after.c))")
        #expect(after.violations.isEmpty, "\(after.violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.releaseGroup(groupA)
        await engine.releaseGroup(groupB)
        await engine.releaseGroup(groupK)
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.shutdown()
    }

    /// PROBE-C6-PARKFIGURES: the committed lane-drop scenario (`.reclaimed` sweep, alarm path), but B is a prefetch-lane
    /// WAITER instead of a group member, so the fall-through from the re-queue branch into the park branch answers it.
    /// F-22: its figures are the room its own (prefetch) lane lacks: required 5,000,000, available 0 (the opportunistic
    /// volume is 6 MB smaller than the important one, which has 6 MB of room). K's waiter is answered from its 3 MB.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C6-PARKFIGURES: the kept prefetch waiter of a re-judged job gets its own lane's figures", .timeLimit(.minutes(1)), arguments: [true, false])
    func parkFiguresAfterLaneDrop(_ visitFirst: Bool) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 26_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = Data(repeating: 0x58, count: 4_000_000)
        let qBytes = EngineFixture.bytes(991_002, count: 300)
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
        let cBytes = Data(repeating: 0x44, count: 5_000_000)
        let kBytes = Data(repeating: 0x4C, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        try #require(a.transferID == b.transferID)
        await harness.serveManifest([q] + fillers(740_000) + [a, b, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(2_000_000, harness: harness, fileSystem: fileSystem)
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count))
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.hold])
        await harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { engine in
            engine.state.jobs[k.transferID]?.state == .blocked(.awaitingSpace) && engine.state.jobs[a.transferID]?.assets.count == 2
        }
        let replacementBytes = EngineFixture.bytes(991_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(840_000) + [replacement, b, k], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visitFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (owed: engine.followOwed, lane: engine.state.jobs[a.transferID]?.lane, ids: engine.state.jobs[a.transferID]?.assets.count)
        }
        #expect(before.owed == !visitFirst, "setup: \(before)")
        try await EngineSyncTests.leaveRoom(1_999_000, harness: harness, fileSystem: fileSystem)
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state != .blocked(.awaitingSpace) }
        }
        let bResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let kResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let violations = await engine.invariantViolations()
        print("PROBE-C6-PARKFIGURES visitFirst=\(visitFirst) before=\(before) b=\(bResult) k=\(kResult) a=\(aResult) violations=\(violations.count)")
        if case .failure(.insufficientSpace(let required, let available)) = bResult {
            #expect(required == Int64(cBytes.count) && available < required && available == 0, "B's figures are its prefetch lane's room: \(bResult)")
        } else {
            Issue.record("B's prefetch waiter gets insufficientSpace for a 5 MB content with no prefetch room: \(bResult)")
        }
        #expect((try? kResult.get())?.byteSize == Int64(kBytes.count), "K: \(kResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A: \(aResult)")
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.shutdown()
    }

    /// PROBE-C6-LANEGAIN: the park branch's assumption that a lane drop only shrinks the room (the `followBeforeActing`
    /// re-read, cycle 4, and the fall-through of cycle 6) when the opportunistic volume is LARGER than the important one
    /// (the store does not clamp the two readings, and `largestRoom` itself takes their max). C (5 MB) is wanted by A
    /// (a user waiter) and B (a prefetch waiter); 0 bytes of important room, 6 MB of opportunistic room, x's 4 MB
    /// pending reclaim. A forced sync moves A while the bounded follow owes C's visit. After the reclaim: 4 MB important,
    /// 10 MB opportunistic. Followed first (control), C is prefetch and fits: B's waiter gets the asset. During the owed
    /// follow the sweep judges C on A's user lane (does not fit), follows it (prefetch now) and parks it anyway.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C6-LANEGAIN: a park after a follow that raised the job's room", .timeLimit(.minutes(1)), arguments: [true, false])
    func laneGain(_ visitFirst: Bool) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 26_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = Data(repeating: 0x59, count: 4_000_000)
        let qBytes = EngineFixture.bytes(992_002, count: 300)
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
        let cBytes = Data(repeating: 0x45, count: 5_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        try #require(a.transferID == b.transferID)
        await harness.serveManifest([q] + fillers(750_000) + [a, b], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(0, harness: harness, fileSystem: fileSystem)
        let free0 = try await harness.store.freeSpace()
        #expect(free0.pendingReclaim == Int64(xBytes.count), "setup: \(free0)")
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.stage(cBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.assets.count == 2 }
        let replacementBytes = EngineFixture.bytes(992_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(850_000) + [replacement, b], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visitFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (owed: engine.followOwed, lane: engine.state.jobs[a.transferID]?.lane, ids: engine.state.jobs[a.transferID]?.assets.count, c: engine.state.jobs[a.transferID]?.state)
        }
        #expect(before.owed == !visitFirst && before.c == .blocked(.awaitingSpace), "setup: \(before)")
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .blocked(.awaitingSpace) }
        }
        let afterSweep = await engine.readForTests { engine in
            (lane: engine.state.jobs[a.transferID]?.lane, c: engine.state.jobs[a.transferID]?.state, space: engine.state.freeSpace)
        }
        let bResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        print("PROBE-C6-LANEGAIN visitFirst=\(visitFirst) before=\(before) afterSweep=\(afterSweep) b=\(bResult) a=\(aResult)")
        #expect((try? bResult.get())?.byteSize == Int64(cBytes.count), "B's prefetch waiter: 5 MB fit the 10 MB of prefetch room: \(bResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A: \(aResult)")
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        #expect(outcome.completeReport != nil, "\(outcome)")
        await engine.shutdown()
    }
}
