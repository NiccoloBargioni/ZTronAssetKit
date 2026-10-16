import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Regressions the verifiers of close-out cycle 8 found in WP-F (cycle 9 of the level-4 close-out). Each failed before
/// its fix (`docs/adr-drafts/f.md`, F-29).
@Suite("Engine regressions, close-out cycle 9")
struct EngineRegressionCycle9Tests {
    // MARK: The cycle-6 clock driver outlived `driving` (L4-R8; PROBE-C8C-5)

    /// PROBE-C8C-5: `EngineRegressionCycle6Tests.driving` cancelled its clock driver without awaiting it, and the
    /// driver's wait for a sleeper returns on cancellation, so the driver could compute the earliest deadline and advance
    /// the clocks once more after `driving` returned: to a sleeper registered after it returned. In
    /// `R-SYN-10: ensureAvailable whose member waits for space fetches it as soon as a purge reclaimed the bytes, not at
    /// the store's next deadline` that sleeper was a purge's grace, which then reaped before the test's setup was done (a
    /// failed setup expectation, then a wait that never ended: the cycle-8 sanitizer run's time-limit overrun). Each round
    /// drives nothing while the driver waits, registers a sleeper 60 s ahead, waits until it is registered and gives a
    /// stale driver turns to act; the clock must not move. The verifier counted 7 and 6 stale advances in 2,000 rounds.
    @Test("R-SYN-11: the clock driver of the space tests has stopped when driving returns, so it never advances a clock to a sleeper registered afterwards (2,000 rounds)", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func drivingStopsBeforeReturning() async {
        var stale = 0
        var unseen = 0
        for _ in 0..<2_000 {
            let clock = ManualTimeSource()
            let start = clock.monotonicNow()
            // The operation yields so the driver reaches its wait for a sleeper before `driving` cancels it.
            let value = await EngineRegressionCycle6Tests.driving([clock]) {
                for _ in 0..<4 {
                    await Task.yield()
                }
                return 0
            }
            let sleeper = Task {
                try? await clock.sleep(until: start.adding(seconds: 60))
            }
            // The registration is awaited by yielding (never a wall-clock wait): a stale driver may wake the sleeper
            // before it is seen, and then the clock has moved.
            var turns = 0
            while clock.pendingSleepers == 0, clock.monotonicNow() == start, turns < 10_000 {
                await Task.yield()
                turns += 1
            }
            for _ in 0..<8 {
                await Task.yield()
            }
            if clock.monotonicNow() != start || value != 0 {
                stale += 1
            } else if clock.pendingSleepers == 0 {
                unseen += 1
            }
            sleeper.cancel()
            await sleeper.value
        }
        #expect(stale == 0, "the clock moved after driving returned in \(stale) of 2,000 rounds")
        #expect(unseen == 0, "the sleeper never registered in \(unseen) rounds")
    }

    // MARK: Bounded actor turns at scale (C2; review of close-out cycle 8)

    /// More members than one bounded turn handles (`readmissionsPerTurn`, `releasesPerTurn`).
    static let members = SyncEngine.readmissionsPerTurn + 64

    /// No network, nominal power.
    static let offline = DeviceConditions(network: NetworkConditions(satisfied: false, expensive: false, constrained: false), power: PowerConditions(lowPowerMode: false, thermal: .nominal))

    /// Every job's state.
    @available(macOS 15.0, iOS 18.0, *)
    static func states(_ engine: SyncEngine) async -> [JobState] {
        await EngineRegressionCycle8Tests.states(engine)
    }

    /// `count` on-demand 300-byte entries `m0`…, absent after a first sync on a volume with `reserve + 1,000,000` bytes
    /// (room for every member of `members`).
    @available(macOS 15.0, iOS 18.0, *)
    static func startedRoomy(count: Int, seed: UInt64) async throws -> (EngineHarness, FakeFileSystem, [ManifestEntry]) {
        let reserve = StoragePolicy().reserveFreeBytes
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 1_000_000, opportunisticCapacity: reserve + 1_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let entries = (0..<count).map { index in
            EngineHarness.onDemand("m\(index)", EngineFixture.bytes(seed + UInt64(index), count: 300))
        }
        await harness.serveManifest(entries)
        try await harness.start()
        _ = try #require(await harness.engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        return (harness, fileSystem, entries)
    }

    /// When the network returns, the jobs parked `offline` and those failed `whenOnline` are re-queued at most
    /// `readmissionsPerTurn` per turn (one turn re-queued 10,000 in about 22 ms); the follow-up turns must reach every
    /// one. More members than that wait behind three running ones; the network drops, the three fail offline and the
    /// others park `offline`; the network returns on a roomy volume.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-13: when the network returns under more members parked offline than one turn re-queues, every member is re-queued",
        .timeLimit(.minutes(1))
    )
    func networkReturnRequeuesEveryMember() async throws {
        let count = Self.members
        let (harness, _, entries) = try await EngineRegressionCycle8Tests.started(count: count, seed: 10_901)
        let engine = harness.engine
        _ = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count && $0.state.inFlight.count == 3 }
        await engine.waitForAllHandles()
        let running = await harness.source.starts.map(\.id)
        #expect(running.count == 3, "setup: three members run")
        await harness.conditions.send(Self.offline)
        await engine.awaitCondition { $0.state.conditions?.network.satisfied == false }
        for transfer in running {
            await harness.source.script(transfer, [.fail(.offline(.noConnection))])
        }
        await engine.awaitCondition { $0.state.inFlight.isEmpty && $0.state.laneParked.count + $0.state.failedJobs.count == count }
        #expect(await engine.readForTests { $0.state.laneParked.count } == count - 3, "setup: the queued members are parked offline")
        await harness.conditions.send(.unrestricted)
        // Once no follow-up is owed: a re-queue left to a turn nobody scheduled would leave members parked.
        await engine.awaitCondition { engine in
            engine.state.inFlight.count == 3 && !engine.state.readmissionFollowUpScheduled && !engine.state.pumpFollowUpScheduled
        }
        let states = await Self.states(engine)
        #expect(states.count == count)
        #expect(states.filter { $0 == .queued }.count == count - 3, "every member not running waits in the queue")
        #expect(!states.contains { $0.kind == .blocked || $0.kind == .failed }, "no member is left parked or failed")
        await engine.waitForAllHandles()
        #expect(await harness.source.starts.count == 6, "three members start again")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// A free-space read re-queues at most `readmissionsPerTurn` jobs parked for space per turn (one turn re-admitted
    /// 10,000 in about 15 ms) and owes a follow-up sweep the rest; the follow-ups must reach every one. More members than
    /// that are parked `insufficientSpace` on a volume with room for two (the third non-user slot stays free, so the pump
    /// gates and parks each); the volume then gains room for all of them.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-11: when the volume gains room for more members parked for space than one turn re-admits, every one is re-queued",
        .timeLimit(.minutes(1))
    )
    func roomReadmitsEveryParkedMember() async throws {
        let count = Self.members
        let (harness, fileSystem, entries) = try await Self.startedRoomy(count: count, seed: 10_911)
        let engine = harness.engine
        let ballast = try await EngineRegressionCycle6Tests.leaveRoom(600, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        _ = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.inFlight.count == 2 && $0.state.spaceParked.count == count - 2 }
        try fileSystem.removeItem(at: ballast)
        await engine.refreshFreeSpace()
        // Once no follow-up is owed: a re-admission left to a sweep nobody scheduled would leave members parked.
        await engine.awaitCondition { engine in
            engine.state.inFlight.count == 3 && engine.state.spaceSweepFollowUp == nil && !engine.state.pumpFollowUpScheduled
        }
        let states = await Self.states(engine)
        #expect(states.count == count)
        #expect(states.filter { $0 == .queued }.count == count - 3, "every member not running waits in the queue")
        #expect(await engine.readForTests { $0.state.spaceParked.isEmpty }, "no member is left parked for space")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// The jobs a sweep re-queued count against the room until they start, also for a later sweep: a sweep that the
    /// re-admission bound splits over turns, or the next read's, would otherwise admit again the room the waiting ones
    /// were admitted for (and the gate would park the surplus once a slot frees). Two 300-byte members run on a volume
    /// with room for two; eleven more are parked for space (the third non-user slot is free, so the pump gates each).
    /// The volume gains room for four: the read re-queues four, the free slot starts one, and three wait in the queue,
    /// every slot taken. A second read of the same volume re-queues none.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-11: a later free-space read counts the jobs an earlier one re-admitted that still wait for a slot, so together they never exceed the room",
        .timeLimit(.minutes(1))
    )
    func laterReadCountsWaitingAdmissions() async throws {
        let count = 13
        let (harness, fileSystem, entries) = try await EngineRegressionCycle8Tests.started(count: count, seed: 10_921)
        let engine = harness.engine
        let ballast = try await EngineRegressionCycle6Tests.leaveRoom(600, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        _ = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.inFlight.count == 2 && $0.state.spaceParked.count == count - 2 }
        let ballastBytes = try #require(try fileSystem.itemInfo(at: ballast)?.byteSize)
        try fileSystem.write(Data(repeating: 1, count: Int(ballastBytes) - 1_200), to: ballast, mode: .truncate)
        await engine.refreshFreeSpace()
        let first = await Self.states(engine)
        #expect(first.filter { $0 == .downloading }.count == 3, "the free slot starts one of the four re-admitted")
        #expect(first.filter { $0 == .queued }.count == 3, "the other three wait for a slot")
        await engine.refreshFreeSpace()
        let second = await Self.states(engine)
        #expect(second.filter { $0 == .queued }.count == 3, "the second read re-queues none: the three waiting take the room")
        #expect(second.filter { $0 == .blocked(.insufficientSpace) }.count == count - 6, "the others stay parked")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// Releasing a prefetch handle removes at most `releasesPerTurn` members' interests per turn (one turn removed
    /// 10,000 in about 15 ms); the follow-up turns must reach every member, and a member only the released handle wants
    /// must not start meanwhile (R-CAR-4: no transfer runs for nobody). More members than that wait behind three running
    /// ones on a roomy volume; the release cancels the three, and no member starts.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-CAR-4: releasing a prefetch handle of more members than one turn releases leaves no job and starts none of its members meanwhile",
        .timeLimit(.minutes(1))
    )
    func releaseRemovesEveryMemberAndStartsNone() async throws {
        let count = Self.members
        let (harness, _, entries) = try await EngineRegressionCycle8Tests.started(count: count, seed: 10_931)
        let engine = harness.engine
        let token = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count && $0.state.inFlight.count == 3 }
        await engine.waitForAllHandles()
        let running = await harness.source.starts.map(\.id)
        #expect(running.count == 3, "setup: three members run")
        await engine.releaseGroup(token)
        // Once no follow-up is owed: interests left to a turn nobody scheduled would keep their jobs.
        await engine.awaitCondition { !$0.state.releaseFollowUpScheduled }
        #expect(await engine.readForTests { $0.state.jobs.isEmpty }, "no member keeps a job")
        #expect(await engine.readForTests { $0.state.releasing.isEmpty }, "no interest is left to remove")
        #expect(await harness.source.starts.count == 3, "no member started after the release")
        let cancelled = Set(await harness.source.controlLog.filter { $0.control == .cancel }.map(\.transfer))
        #expect(cancelled == Set(running), "the three running transfers were cancelled")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    /// A released group's members wait in the queue until their interests leave, and the pump must not take them for
    /// user work it should preempt or wait for: a prefetch handle registered at user-initiated priority left its
    /// released members in the user queue, so the pump of the release's own turn saw user work waiting, found nothing to
    /// preempt and stopped before the prefetch queue, and other work started only after the release's last turn. Four
    /// members of such a handle run (every slot); a two-member prefetch handle waits; the release, in one actor turn,
    /// cancels the four and must start the two.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-CAR-4: releasing a user-initiated handle of more members than one turn releases lets queued prefetch work start in that turn",
        .timeLimit(.minutes(1))
    )
    func releasedUserMembersDoNotHoldBackOtherWork() async throws {
        let count = Self.members
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 0))
        let engine = harness.engine
        let users = (0..<count).map { index in
            EngineHarness.onDemand("u\(index)", EngineFixture.bytes(10_941 + UInt64(index), count: 300))
        }
        let prefetched = (0..<2).map { index in
            EngineHarness.onDemand("p\(index)", EngineFixture.bytes(10_940 - UInt64(index), count: 300))
        }
        await harness.serveManifest(users + prefetched)
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        let userToken = try await engine.registerGroup(users.map(\.identifier), lane: .userInitiated).get()
        await engine.awaitCondition { $0.state.jobs.count == count && $0.state.inFlight.count == 4 }
        _ = try await engine.registerGroup(prefetched.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count + 2 }
        let waiting = Set(prefetched.map(\.transferID))
        #expect(await engine.readForTests { engine in waiting.allSatisfy { engine.state.jobs[$0]?.state == .queued } }, "setup: the prefetch members wait")
        // The release's own turn, and what it started, read in that turn (its follow-up turn has not run).
        let started = await engine.readForTests { engine in
            engine.performReleaseGroup(userToken)
            return (waiting.filter { engine.state.inFlight.contains($0) }.count, engine.state.releasing.isEmpty)
        }
        #expect(!started.1, "setup: the release continues in a later turn")
        #expect(started.0 == 2, "both prefetch members start in the release's turn")
        await engine.awaitCondition { !$0.state.releaseFollowUpScheduled }
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }
}
