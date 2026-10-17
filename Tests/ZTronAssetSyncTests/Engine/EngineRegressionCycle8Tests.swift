import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The behaviour of the bounds close-out cycle 8 put on the engine's actor turns when many jobs park for lack of space
/// (C2, R-SYN-11; review of close-out cycle 7, PROBE-C7C-2; `docs/adr-drafts/f.md`, F-28). The turn lengths themselves
/// are measured by the release benchmark `R-SYN-11: parking a 10,000-member prefetch group for lack of space, and an
/// ENOSPC's free-space read over it, never hold the engine's actor longer than P-9's heartbeat_gap_ms_p99_max`; these
/// tests pin what the bounds must not change: every job still ends where the gate puts it, and nothing is re-queued only
/// to be parked again.
@Suite("Engine regressions, close-out cycle 8")
struct EngineRegressionCycle8Tests {
    /// More members than one turn parks.
    static let members = SyncEngine.parksPerPump + 64

    /// `count` on-demand 300-byte entries `m0`…, absent after a first sync on a volume with `reserve + 100,000` bytes.
    @available(macOS 15.0, iOS 18.0, *)
    static func started(count: Int, seed: UInt64) async throws -> (EngineHarness, FakeFileSystem, [ManifestEntry]) {
        let time = ManualTimeSource()
        let (harness, fileSystem) = EngineRegressionCycle6Tests.harness(time: time)
        let entries = (0..<count).map { index in
            EngineHarness.onDemand("m\(index)", EngineFixture.bytes(seed + UInt64(index), count: 300))
        }
        await harness.serveManifest(entries)
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        return (harness, fileSystem, entries)
    }

    /// Every job's state.
    @available(macOS 15.0, iOS 18.0, *)
    static func states(_ engine: SyncEngine) async -> [JobState] {
        await engine.readForTests { engine in
            engine.state.jobs.values.map(\.state)
        }
    }

    // MARK: The pump's park bound (C2)

    /// A pump parks at most `parksPerPump` jobs and leaves the rest to a follow-up turn; the follow-ups must reach every
    /// queued job. More members than that wait behind three running ones; the network drops, the three fail offline, and
    /// the others park `offline`; the volume then fills to the reserve. When the network returns, every member is
    /// re-queued at once (the parked ones, and the failed ones on the edge, R-SYN-13), and the gate parks each
    /// `insufficientSpace` (the store counts no pending reclaim): more than one pump's worth, and nothing starts again.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-11: when the network returns under more queued members than one pump turn parks, every member the volume cannot hold ends parked for lack of space",
        .timeLimit(.minutes(1))
    )
    func pumpParksEveryMemberAcrossTurns() async throws {
        let count = Self.members
        let (harness, fileSystem, entries) = try await Self.started(count: count, seed: 10_801)
        let engine = harness.engine
        _ = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        // Unscripted transfers wait in the fake source: three run (the non-user slots), the others wait in the queue.
        await engine.awaitCondition { $0.state.jobs.count == count && $0.state.inFlight.count == 3 }
        await engine.waitForAllHandles()
        let running = await harness.source.starts.map(\.id)
        #expect(running.count == 3, "setup: three members run")
        // The engine watches the conditions while it has work.
        await harness.conditions.send(DeviceConditions(network: NetworkConditions(satisfied: false, expensive: false, constrained: false), power: PowerConditions(lowPowerMode: false, thermal: .nominal)))
        await engine.awaitCondition { $0.state.conditions?.network.satisfied == false }
        for transfer in running {
            await harness.source.script(transfer, [.fail(.offline(.noConnection))])
        }
        await engine.awaitCondition { engine in
            engine.state.inFlight.isEmpty && !engine.state.jobs.values.contains { $0.state == .queued }
        }
        _ = try await EngineRegressionCycle6Tests.leaveRoom(0, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        await harness.conditions.send(.unrestricted)
        // The count of jobs parked for space is kept by the transition funnel: the wait reads it in O(1) per mutation.
        await engine.awaitCondition { $0.state.spaceParked.count == count }
        let states = await Self.states(engine)
        #expect(states.count == count)
        #expect(states.allSatisfy { $0 == .blocked(.insufficientSpace) }, "every member parked for lack of space")
        #expect(await harness.source.starts.count == 3, "nothing started again: the volume holds none of them")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    // MARK: The space sweep (C2, T17)

    /// A free-space read re-admits the jobs parked for space that the room holds together, in queue order, and leaves the
    /// others parked as they were: re-queuing every job that fits on its own only for the gate to park all but the first
    /// again made each read cost a re-queue and a park per parked job (16 ms in one turn at 10,000; review of close-out
    /// cycle 7). With 1,000 bytes above the reserve and three parked 400-byte members, the first two start and the third
    /// keeps its place: it is never re-queued, so its queue ticket does not change.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-11: a free-space read re-admits the jobs parked for space that the room holds together and leaves the others parked untouched",
        .timeLimit(.minutes(1))
    )
    func sweepAdmitsWhatTheRoomHoldsTogether() async throws {
        let time = ManualTimeSource()
        let (harness, fileSystem) = EngineRegressionCycle6Tests.harness(time: time)
        let engine = harness.engine
        let entries = (1...3).map { index in
            EngineHarness.onDemand("p\(index)", EngineFixture.bytes(10_811 + UInt64(index), count: 400))
        }
        await harness.serveManifest(entries)
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        let ballast = try await EngineRegressionCycle6Tests.leaveRoom(300, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        _ = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.values.filter { $0.state == .blocked(.insufficientSpace) }.count == 3 }
        let third = entries[2].transferID
        let ticket = await engine.readForTests { $0.state.jobs[third]?.ticket }
        // Room for two of the three above the reserve, each of which fits on its own.
        let free = try await harness.store.freeSpace()
        let ballastBytes = try #require(try fileSystem.itemInfo(at: ballast)?.byteSize)
        try fileSystem.write(Data(repeating: 1, count: Int(ballastBytes - (1_000 - (free.volumeOpportunistic - free.reserveBytes)))), to: ballast, mode: .truncate)
        #expect(try await harness.store.freeSpace().volumeOpportunistic - free.reserveBytes == 1_000, "setup: 1,000 bytes above the reserve")
        await engine.refreshFreeSpace()
        await engine.waitForAllHandles()
        // The fake records a start when the attempt's driver task reaches it, and the two drivers race there; the queue
        // order is the engine's own dispatch order (`startSequence`, taken in the turn that dispatched both).
        let started = await harness.source.starts.map(\.id)
        #expect(started.count == 2 && Set(started) == [entries[0].transferID, entries[1].transferID], "the two members ahead in the queue start: \(started)")
        let order = await engine.readForTests { engine in
            entries.prefix(2).map { engine.state.jobs[$0.transferID]?.active?.startSequence }
        }
        #expect(order.allSatisfy { $0 != nil } && order[0]! < order[1]!, "dispatched in queue order: \(order)")
        let after = await engine.readForTests { ($0.state.jobs[third]?.state, $0.state.jobs[third]?.ticket) }
        #expect(after.0 == .blocked(.insufficientSpace), "the third stays parked")
        #expect(after.1 == ticket, "the third was never re-queued (its queue ticket is unchanged)")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// A sweep of the jobs parked for space parks at most `parksPerPump` of them per turn and owes a follow-up sweep the
    /// rest; the follow-ups must reach every one, whatever the engine's other wakes. More members than that wait
    /// `awaitingSpace` for `x`'s doomed bytes on a volume with no other room above the reserve; only the store's clock
    /// passes the grace and its due work reaps `x`, so the engine's own alarm for that deadline stays armed and never
    /// fires. The store call that may have reclaimed bytes (the purge path) then reads 300 bytes of room and no pending
    /// reclaim: the first member is re-admitted, and every other one is parked `insufficientSpace` (nothing is left to
    /// reclaim for it), more than one turn's worth.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-11: once the store reclaimed what jobs waited for, every one the room does not hold is parked insufficientSpace, more than one turn's worth",
        .timeLimit(.minutes(1))
    )
    func reclaimedSweepReachesEveryWaitingMember() async throws {
        let count = Self.members
        let time = ManualTimeSource()
        let storeTime = ManualTimeSource()
        let (harness, fileSystem) = EngineRegressionCycle6Tests.harness(time: time, storeTime: storeTime)
        let engine = harness.engine
        let xBytes = EngineFixture.bytes(10_821, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let entries = (0..<count).map { index in
            EngineHarness.onDemand("m\(index)", EngineFixture.bytes(10_822 + UInt64(index), count: 300))
        }
        await harness.serveManifest([x])
        await harness.scriptTransfers([(x, xBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        // v2 prunes x (doomed for the 60 s grace) and lists the on-demand members.
        await harness.serveManifest(entries, etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for reclaim")
        _ = try await EngineRegressionCycle6Tests.leaveRoom(0, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        _ = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.spaceParked.count == count }
        #expect(await Self.states(engine).allSatisfy { $0 == .blocked(.awaitingSpace) }, "setup: every member waits for x's bytes")
        storeTime.advance(by: 61)
        let reaped = await harness.store.runDueWork().reapedBytes
        #expect(reaped == Int64(xBytes.count), "setup: the store reaped x")
        await engine.spaceMayHaveBeenReclaimed()
        // Cheap terms first: the scan of every parked job runs only once no follow-up sweep is owed.
        await engine.awaitCondition { engine in
            engine.state.spaceParked.count == count - 1 && engine.state.spaceSweepFollowUp == nil
                && engine.state.spaceParked.allSatisfy { engine.state.jobs[$0]?.state == .blocked(.insufficientSpace) }
        }
        await engine.waitForAllHandles()
        let started = await harness.source.starts.map(\.id).filter { $0 != x.transferID }
        #expect(started == [entries[0].transferID], "the room holds one member, the first in the queue: \(started)")
        #expect(await engine.readForTests { $0.state.storeDeadline != nil }, "the engine's alarm for x's deadline is still armed")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// A job waiting `awaitingSpace` that the room after a reclaim still does not hold keeps waiting while the store counts
    /// more pending reclaim (the sweep leaves it parked instead of re-queuing it for the gate to park it again), and starts
    /// once the rest is reclaimed. `x` and `z` (300 bytes each) are doomed 30 s apart; `y` (500 bytes, on demand) needs
    /// both reclaimed on a volume with no other room above the reserve. Only the store's clock moves; the store's due
    /// work reaps, and the purge path (`spaceMayHaveBeenReclaimed`) re-checks the engine's parked jobs.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-11: a job waiting for space keeps waiting after a reclaim that leaves it short while more is pending, and starts once the rest is reclaimed",
        .timeLimit(.minutes(1))
    )
    func reclaimedSweepKeepsWaitingWhileMoreIsPending() async throws {
        let time = ManualTimeSource()
        let storeTime = ManualTimeSource()
        let (harness, fileSystem) = EngineRegressionCycle6Tests.harness(time: time, storeTime: storeTime)
        let engine = harness.engine
        let xBytes = EngineFixture.bytes(10_831, count: 300)
        let zBytes = EngineFixture.bytes(10_832, count: 300)
        let yBytes = EngineFixture.bytes(10_833, count: 500)
        let x = EngineFixture.entry("x", xBytes)
        let z = EngineFixture.entry("z", zBytes)
        let y = EngineHarness.onDemand("y", yBytes)
        await harness.serveManifest([x, z])
        await harness.scriptTransfers([(x, xBytes), (z, zBytes), (y, yBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        // v2 prunes x (doomed for the 60 s grace); 30 s later v3 prunes z.
        await harness.serveManifest([z, y], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        storeTime.advance(by: 30)
        await harness.serveManifest([y], etag: "v3")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count + zBytes.count), "setup: x's and z's bytes wait for reclaim")
        _ = try await EngineRegressionCycle6Tests.leaveRoom(0, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        let resolve = Task { await engine.awaitAsset("y", lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[y.transferID]?.state == .blocked(.awaitingSpace) }
        // x's grace ends: the store reaps 300 bytes and still counts z's 300 as pending; y needs 500.
        storeTime.advance(by: 31)
        #expect(await harness.store.runDueWork().reapedBytes == Int64(xBytes.count), "setup: the store reaped x")
        await engine.spaceMayHaveBeenReclaimed()
        #expect(await engine.readForTests { $0.state.jobs[y.transferID]?.state } == .blocked(.awaitingSpace), "y keeps waiting for z's bytes")
        #expect(await harness.source.starts.filter { $0.id == y.transferID }.isEmpty, "y did not start on 300 bytes")
        // z's grace ends: the store reaps the rest, and y fits.
        storeTime.advance(by: 30)
        #expect(await harness.store.runDueWork().reapedBytes == Int64(zBytes.count), "setup: the store reaped z")
        await engine.spaceMayHaveBeenReclaimed()
        let result = await resolve.value
        #expect(result.successValue != nil, "y is served once x's and z's bytes are reclaimed: \(result)")
        #expect(await harness.source.starts.filter { $0.id == y.transferID }.count == 1, "y downloaded once")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }
}
