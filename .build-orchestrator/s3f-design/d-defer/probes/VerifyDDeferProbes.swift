import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Design probes (s3f structural design D1 "defer"). Never committed as is. Each compares the order "the follow's visit
/// first" with "the space decision first" and asserts the visit-first outcome in both, on code that compiles at 40ecd95
/// and with the design (only state both have is read).
///
/// - PROBE-D-PUMP-PROMOTE: the pump starts a job that holds no moved id (J, prefetch, 3 MB) while the follow owes the
///   visit that moves a user waiter's interest onto new content (N, 3 MB); 5 MB of room hold one of them.
/// - PROBE-D-PUMP-FREED: a user request (K, 3 MB) made during the owed follow is gated against room a downloading job the
///   follow supersedes (D, 4 MB, wanted only by the moved id) still holds.
/// - PROBE-D-JOIN-FREED: a user waiter joins a job parked `insufficientSpace` (K, 3 MB, a prefetch group's) during the
///   owed follow; the room is held by D as above. A second joiner cancels while its answer would wait.
/// - PROBE-D-REFOLLOW: the cycle-8 DROPPED-LANE setup, with a second follow started (`followApplied` again, as a later
///   apply's follow restarts its visits) after the reclaim and before the follow's turns are released.
/// - PROBE-D-SHUTDOWN: shutdown while a sweep and a join wait for the follow: every waiter is answered `.shutDown`.
/// - PROBE-D-ENOSPC: an ENOSPC's verdict during the owed follow, on room a downloading job the follow supersedes holds.
@Suite("VerifyDDeferProbes", .serialized)
struct VerifyDDeferProbes {
    /// The 4 user holders that occupy every slot, A (C, 4 MB) queued behind them, J (3 MB, prefetch) queued; v3 moves A
    /// to N (3 MB). A slot frees while the follow owes C's visit.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D-PUMP-PROMOTE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func pumpPromote(_ visit: LaneDropVisit) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(disk: DiskImage(), time: time, configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000))
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let qBytes = EngineFixture.bytes(990_002, count: 300)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([q])
        await harness.scriptTransfers([(q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        let holderBytes = (0..<4).map { EngineFixture.bytes(990_100 + UInt64($0), count: 16) }
        let holders = (0..<4).map { EngineHarness.onDemand("h\($0)", holderBytes[$0]) }
        let cBytes = Data(repeating: 0x81, count: 4_000_000)
        let jBytes = Data(repeating: 0x82, count: 3_000_000)
        let nBytes = Data(repeating: 0x83, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let j = EngineHarness.onDemand("zz-j", jBytes)
        await harness.serveManifest([q] + fillers(770_000) + holders + [a, j], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(5_000_000, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        for (entry, bytes) in zip(holders, holderBytes) {
            await harness.source.script(entry.transferID, [.hold, .stage(bytes)])
        }
        let holderWaiters = holders.map { entry in Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) } }
        await engine.awaitCondition { engine in holders.allSatisfy { engine.state.jobs[$0.transferID]?.state == .downloading } }
        await harness.source.script(a.transferID, [.stage(cBytes)])
        await harness.source.script(j.transferID, [.stage(jBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .queued }
        let jWaiter = Task { await engine.awaitAsset(j.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[j.transferID]?.state == .queued }
        let n = EngineHarness.onDemand("zz-a", nBytes)
        await harness.source.script(n.transferID, [.stage(nBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(870_000) + holders + [n, j], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let before = await engine.readForTests { engine in
            (owed: engine.followOwed, c: engine.state.jobs[a.transferID]?.state, n: engine.state.jobs[n.transferID]?.state, j: engine.state.jobs[j.transferID]?.state)
        }
        print("PROBE-D-PUMP-PROMOTE \(visit) before: \(before)")
        #expect(before.j == .queued, "setup: J waits for a slot: \(before)")
        switch visit {
        case .followVisitedFirst:
            #expect(!before.owed && before.c == nil && before.n == .queued, "setup: the follow superseded C and N waits for a slot: \(before)")
        case .sweepFollowsFirst:
            #expect(before.owed && before.c == .queued && before.n == nil, "setup: C still holds A: \(before)")
        }
        // A slot frees: h0 commits, and any later event pumps.
        await harness.source.release(holders[0].transferID, with: .progress(received: 0, expected: nil))
        _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: holderWaiters[0]) }
        await engine.readForTests { $0.pump() }
        let afterSlot = await engine.readForTests { engine in
            (owed: engine.followOwed, j: engine.state.jobs[j.transferID]?.state, n: engine.state.jobs[n.transferID]?.state, violations: engine.invariantViolations())
        }
        print("PROBE-D-PUMP-PROMOTE \(visit) afterSlot: \(afterSlot)")
        #expect(afterSlot.violations.isEmpty, "\(afterSlot.violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        await engine.awaitCondition { !$0.followOwed }
        for holder in holders.dropFirst() {
            await harness.source.release(holder.transferID, with: .progress(received: 0, expected: nil))
        }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let jResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: jWaiter) }
        for waiter in holderWaiters.dropFirst() {
            _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: waiter) }
        }
        print("PROBE-D-PUMP-PROMOTE \(visit) A: \(aResult) | J: \(jResult)")
        #expect((try? aResult.get())?.byteSize == Int64(nBytes.count), "A's user waiter, moved onto N, is answered from N's 3 MB: \(aResult)")
        if case .failure(.insufficientSpace(let required, let available)) = jResult {
            #expect(required == Int64(jBytes.count) && available < required, "J's figures: \(jResult)")
        } else {
            Issue.record("J's prefetch waiter is answered insufficientSpace: N's user work took the room first: \(jResult)")
        }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        await engine.shutdown()
    }

    /// The scenario of PROBE-D-PUMP-FREED and PROBE-D-JOIN-FREED.
    enum Freed: Sendable {
        /// A user request for K made during the owed follow.
        case request
        /// A user waiter joins K parked `insufficientSpace` for a prefetch group, and a second joiner cancels.
        case join
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D-PUMP-FREED", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func pumpFreed(_ visit: LaneDropVisit) async throws {
        try await Self.freed(visit, .request)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D-JOIN-FREED", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func joinFreed(_ visit: LaneDropVisit) async throws {
        try await Self.freed(visit, .join)
    }

    /// D (4 MB) downloads for A's user waiter only, with 5 MB of room; v3 moves A to a 16-byte content while the follow
    /// owes D's visit. K is 3 MB. Visited first, D is superseded (its bytes leave the ledger) and K fits.
    @available(macOS 15.0, iOS 18.0, *)
    static func freed(_ visit: LaneDropVisit, _ scenario: Freed) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(disk: DiskImage(), time: time, configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000))
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let qBytes = EngineFixture.bytes(991_002, count: 300)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([q])
        await harness.scriptTransfers([(q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        let dBytes = Data(repeating: 0x91, count: 4_000_000)
        let kBytes = Data(repeating: 0x92, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", dBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        await harness.serveManifest([q] + fillers(780_000) + [a, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(5_000_000, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.hold, .stage(dBytes)])
        await harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        var group: InterestToken?
        if scenario == .join {
            group = try await engine.registerGroup([k.identifier], lane: .prefetch).get()
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .blocked(.insufficientSpace) }
        }
        let replacementBytes = EngineFixture.bytes(991_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(880_000) + [replacement, k], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        let tokens = await engine.readForTests { $0.state.lastToken }
        let uWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.lastToken > tokens }
        var cancelled: Task<Result<AssetLocation, AssetError>, Never>?
        if scenario == .join {
            let joined = await engine.readForTests { $0.state.lastToken }
            let second = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
            // K may have committed already when the follow visited first: the second request is then answered from the
            // store without a join.
            await engine.awaitCondition { $0.state.lastToken > joined || $0.state.jobs[k.transferID] == nil }
            second.cancel()
            cancelled = second
        }
        let between = await engine.readForTests { engine in
            (owed: engine.followOwed, d: engine.state.jobs[a.transferID]?.state, k: engine.state.jobs[k.transferID]?.state, violations: engine.invariantViolations())
        }
        print("PROBE-D-\(scenario) \(visit) between: \(between)")
        #expect(between.violations.isEmpty, "\(between.violations.prefix(3))")
        switch visit {
        case .followVisitedFirst:
            #expect(!between.owed && between.d == nil, "setup: the follow superseded D: \(between)")
        case .sweepFollowsFirst:
            #expect(between.owed && between.d == .downloading, "setup: D still downloads for A: \(between)")
        }
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let uResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        print("PROBE-D-\(scenario) \(visit) U: \(uResult) | A: \(aResult)")
        #expect((try? uResult.get())?.byteSize == Int64(kBytes.count), "the user request for K is served from the room the follow frees: \(uResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A's waiter is answered from its new content: \(aResult)")
        if let cancelled {
            let second = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: cancelled) }
            print("PROBE-D-\(scenario) \(visit) cancelled joiner: \(second)")
            #expect(second == .failure(.cancelled) || (try? second.get())?.byteSize == Int64(kBytes.count), "the cancelled joiner: \(second)")
        }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        if let group {
            await engine.releaseGroup(group)
        }
        _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        await engine.shutdown()
    }

    /// PROBE-D-ENOSPC: D (4 MB, wanted only by A's user waiter) downloads; E (1.5 MB, U's user waiter) downloads beside
    /// it in 6 MB of room. v3 moves A to a 16-byte content while the follow owes D's visit. The volume then shrinks to
    /// 5 MB and E's attempt fails ENOSPC. Visited first, D is superseded, E's room is 5 MB, and the ENOSPC is retried
    /// (`retryLater`): U is served. Decided first, E's room is 1 MB (D's 4 MB in flight) and E is parked
    /// `insufficientSpace`, U answered with that shortage.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D-ENOSPC", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func enospc(_ visit: LaneDropVisit) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(disk: DiskImage(), time: time, configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000))
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let qBytes = EngineFixture.bytes(994_002, count: 300)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([q])
        await harness.scriptTransfers([(q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        let fillers = { (seed: UInt64) in
            (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
        }
        let dBytes = Data(repeating: 0x95, count: 4_000_000)
        let eBytes = Data(repeating: 0x96, count: 1_500_000)
        let a = EngineHarness.onDemand("zz-a", dBytes)
        let e = EngineHarness.onDemand("zz-e", eBytes)
        await harness.serveManifest([q] + fillers(790_000) + [a, e], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(6_000_000, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.hold, .stage(dBytes)])
        await harness.source.script(e.transferID, [.hold, .fail(.insufficientSpace(requiredBytes: Int64(eBytes.count))), .stage(eBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let uWaiter = Task { await engine.awaitAsset(e.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[e.transferID]?.state == .downloading }
        let replacementBytes = EngineFixture.bytes(994_004, count: 16)
        let replacement = EngineHarness.onDemand("zz-a", replacementBytes)
        await harness.source.script(replacement.transferID, [.stage(replacementBytes)])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(890_000) + [replacement, e], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        if visit == .followVisitedFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followOwed }
        }
        // The volume shrinks to 5 MB above the reserve, then E's attempt fails ENOSPC.
        try await EngineSyncTests.leaveRoom(5_000_000, harness: harness, fileSystem: fileSystem)
        let shrunk = try await harness.store.freeSpace().volumeImportant
        await harness.source.release(e.transferID, with: .progress(received: 0, expected: nil))
        // The ENOSPC's own free-space read adopted (its verdict, or its deferral, is in the same turn).
        await engine.awaitCondition { $0.state.jobs[e.transferID]?.state != .downloading && $0.state.freeSpace?.volumeImportant == shrunk }
        let between = await engine.readForTests { engine in
            (owed: engine.followOwed, d: engine.state.jobs[a.transferID]?.state, e: engine.state.jobs[e.transferID]?.state, eError: engine.state.jobs[e.transferID]?.lastError, violations: engine.invariantViolations())
        }
        print("PROBE-D-ENOSPC \(visit) between: \(between)")
        #expect(between.violations.isEmpty, "\(between.violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let uResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: uWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        print("PROBE-D-ENOSPC \(visit) U: \(uResult) | A: \(aResult)")
        #expect((try? uResult.get())?.byteSize == Int64(eBytes.count), "the ENOSPC is retried in the room the follow frees, and U is served: \(uResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A: \(aResult)")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        await engine.shutdown()
    }

    /// PROBE-D-REFOLLOW: DROPPED-LANE's setup (C, 5 MB, user through A, prefetch through B; K, 3 MB, user; 4 MB important
    /// and 12 MB opportunistic room after the reclaim; v3 drops A) in the sweep-first order, and a second follow
    /// (`followApplied` from the copy, as a later apply restarts the follow's visits) between the reclaim and the follow's
    /// release. K and B are served, A gets `.notFound`, and no deferred decision is left once everything settles.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D-REFOLLOW", .timeLimit(.minutes(3)))
    func refollow() async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(disk: DiskImage(), time: time, configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 26_000_000, opportunisticCapacity: reserve + 34_000_000))
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = Data(repeating: 0x71, count: 4_000_000)
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
        let cBytes = Data(repeating: 0x72, count: 5_000_000)
        let kBytes = Data(repeating: 0x73, count: 3_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        await harness.serveManifest([q] + fillers(742_000) + [a, b, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(0, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        await harness.source.script(a.transferID, [.stage(cBytes)])
        await harness.source.script(k.transferID, [.stage(kBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.assets.count == 2 }
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .blocked(.awaitingSpace) }
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(842_000) + [b, k], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state != .blocked(.awaitingSpace) || ($0.state.storeWorkRuns == 0 && $0.state.freeSpace?.pendingReclaim == 0) }
        }
        // A second follow restarts the visits from `unfollowed` while the first still owes its pass.
        let second = await engine.readForTests { engine in
            engine.followApplied(from: engine.state.applied)
            return (owed: engine.followOwed, violations: engine.invariantViolations())
        }
        print("PROBE-D-REFOLLOW second follow: \(second)")
        #expect(second.violations.isEmpty, "\(second.violations.prefix(3))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let kResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: kWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        print("PROBE-D-REFOLLOW K: \(kResult) | B: \(bResult) | A: \(aResult)")
        #expect((try? kResult.get())?.byteSize == Int64(kBytes.count), "K: \(kResult)")
        #expect((try? bResult.get())?.byteSize == Int64(cBytes.count), "B is served from the opportunistic room: \(bResult)")
        #expect(aResult == .failure(.notFound), "A: \(aResult)")
        _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        let settled = await engine.readForTests { engine in (owed: engine.followOwed, violations: engine.invariantViolations()) }
        #expect(!settled.owed && settled.violations.isEmpty, "\(settled)")
        await engine.shutdown()
    }

    /// PROBE-D-SHUTDOWN: RANK-ADMIT's setup in the sweep-first order (the reclaim's sweep waits for the follow), plus a
    /// user waiter joined to a job parked `insufficientSpace` (a prefetch group's E, 30 MB) whose answer waits too; then
    /// shutdown with the follow's turns still held. Every waiter is answered `.shutDown`, and shutdown returns.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-D-SHUTDOWN", .timeLimit(.minutes(3)))
    func shutdownWhileDeferred() async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(disk: DiskImage(), time: time, configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000))
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = Data(repeating: 0x71, count: 4_000_000)
        let qBytes = EngineFixture.bytes(993_002, count: 300)
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
        let kBytes = Data(repeating: 0x73, count: 3_000_000)
        let eBytes = Data(repeating: 0x74, count: 30_000_000)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let k = EngineHarness.onDemand("zz-k", kBytes)
        let e = EngineHarness.onDemand("zz-e", eBytes)
        await harness.serveManifest([q] + fillers(743_000) + [a, e, k], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(2_000_000, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .blocked(.awaitingSpace) }
        let kWaiter = Task { await engine.awaitAsset(k.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[k.transferID]?.state == .blocked(.awaitingSpace) }
        let group = try await engine.registerGroup([e.identifier], lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs[e.transferID]?.state.isSpaceParked == true }
        let replacement = EngineHarness.onDemand("zz-a", EngineFixture.bytes(993_004, count: 16))
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + fillers(843_000) + [replacement, e, k], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[k.transferID]?.state != .blocked(.awaitingSpace) || ($0.state.storeWorkRuns == 0 && $0.state.freeSpace?.pendingReclaim == 0) }
        }
        let tokens = await engine.readForTests { $0.state.lastToken }
        let joiner = Task { await engine.awaitAsset(e.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.lastToken > tokens }
        let before = await engine.readForTests { engine in
            (owed: engine.followOwed, e: engine.state.jobs[e.transferID]?.state, k: engine.state.jobs[k.transferID]?.state, waiters: engine.state.waiters.count)
        }
        print("PROBE-D-SHUTDOWN before: \(before)")
        await engine.shutdown()
        let kResult = await EngineHarness.value(of: kWaiter)
        let aResult = await EngineHarness.value(of: aWaiter)
        let jResult = await EngineHarness.value(of: joiner)
        let outcome = await EngineHarness.value(of: sync)
        print("PROBE-D-SHUTDOWN K: \(kResult) | A: \(aResult) | joiner: \(jResult) | sync: \(outcome)")
        #expect(kResult == .failure(.shutDown) || (try? kResult.get()) != nil, "K: \(kResult)")
        #expect(aResult == .failure(.shutDown), "A: \(aResult)")
        #expect(jResult == .failure(.shutDown) || jResult == .failure(.insufficientSpace(required: Int64(eBytes.count), available: 6_000_000)) || {
            if case .failure(.insufficientSpace) = jResult { return true }
            return false
        }(), "the joiner: \(jResult)")
        let after = await engine.readForTests { engine in (waiters: engine.state.waiters.count, jobs: engine.state.jobs.count) }
        #expect(after.waiters == 0, "\(after)")
        _ = group
    }
}
