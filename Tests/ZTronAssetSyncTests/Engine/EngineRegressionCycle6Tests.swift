import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Regressions the verifiers of close-out cycle 5 found in WP-F (cycle 6 of the level-4 close-out). Each failed before
/// its fix (`docs/adr-drafts/f.md`, F-26).
@Suite("Engine regressions, close-out cycle 6")
struct EngineRegressionCycle6Tests {
    /// 300-byte assets on a volume with `reserve + 100,000` bytes, a deletion grace of 60 s; `storeTime`, when given, is
    /// the store's own clock (`EngineHarness.make`).
    @available(macOS 15.0, iOS 18.0, *)
    static func harness(time: ManualTimeSource, storeTime: ManualTimeSource? = nil) -> (EngineHarness, FakeFileSystem) {
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: storeTime ?? time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 100_000, opportunisticCapacity: reserve + 100_000)
        )
        let harness = EngineHarness.make(
            time: time,
            storeTime: storeTime,
            storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60),
            fileSystem: fileSystem
        )
        return (harness, fileSystem)
    }

    /// Fills the volume until `room` bytes are left above the reserve; returns the ballast's URL.
    @available(macOS 15.0, iOS 18.0, *)
    static func leaveRoom(_ room: Int64, harness: EngineHarness, fileSystem: FakeFileSystem) async throws -> URL {
        let free = try await harness.store.freeSpace()
        let ballast = EngineHarness.base.appendingPathComponent("ballast")
        try fileSystem.write(Data(repeating: 1, count: Int(free.volumeImportant - free.reserveBytes - room)), to: ballast, mode: .truncate)
        return ballast
    }

    /// Runs `operation` while a driver wakes the sleepers of `clocks`: each round moves every clock still before the
    /// earliest sleeper's deadline to it (never back), so a clock that is ahead stays put until the others reach it.
    /// Never a wall-clock wait; the driver's own wait ends on its cancellation, after which it advances nothing, and
    /// the call returns only once the driver has ended: a driver that outlived the call advanced the clocks to a sleeper
    /// registered afterwards (PROBE-C8C-5, close-out cycle 9). With `fence`, the engine whose clock is among `clocks`,
    /// no clock moves to or past the engine's clock fence (`SyncEngine.clockFence()`), decided in one engine turn: the
    /// driver waits for the fenced work, which the fakes finish without the clock, or for one more sleeper (L4-R17).
    /// `hooks` let the helper's own regression test observe the driver without yielding for it.
    @available(macOS 15.0, iOS 18.0, *)
    static func driving<T: Sendable>(
        _ clocks: [ManualTimeSource],
        fence engine: SyncEngine? = nil,
        hooks: DrivingHooks? = nil,
        _ operation: @Sendable () async -> T
    ) async -> T {
        let driver = Task {
            defer {
                hooks?.ended()
            }
            while !Task.isCancelled {
                await withTaskGroup(of: Void.self) { group in
                    for clock in clocks {
                        group.addTask {
                            if let hooks {
                                _ = await clock.waitForSleepers(atLeast: 1, registered: hooks.waiting)
                            } else {
                                await clock.waitForSleepers(atLeast: 1)
                            }
                        }
                    }
                    _ = await group.next()
                    group.cancelAll()
                }
                // The wait also ends on cancellation: a cancelled driver must not advance to a later sleeper.
                guard !Task.isCancelled else {
                    return
                }
                guard let engine else {
                    Self.advance(clocks)
                    continue
                }
                // The sleepers are counted before the deadlines are read, so one registered after the count ends the wait.
                let fenced = await engine.readForTests { engine -> (fence: MonotonicInstant, sleepers: [Int])? in
                    let sleepers = clocks.map(\.pendingSleepers)
                    guard !Task.isCancelled else {
                        return nil
                    }
                    if let fence = engine.clockFence(), let next = clocks.compactMap(\.nextDeadline).min(), next >= fence {
                        return (fence, sleepers)
                    }
                    Self.advance(clocks)
                    return nil
                }
                guard let fenced, !Task.isCancelled else {
                    continue
                }
                let (fence, waiting) = fenced
                // Fenced: wait for the fenced work to end, or for one more sleeper on any clock (an earlier store wait).
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await engine.awaitCondition { $0.clockFence() != fence }
                    }
                    for (clock, count) in zip(clocks, waiting) {
                        group.addTask {
                            await clock.waitForSleepers(atLeast: count + 1)
                        }
                    }
                    _ = await group.next()
                    group.cancelAll()
                }
            }
        }
        let value = await operation()
        driver.cancel()
        await driver.value
        return value
    }

    /// What `driving` reports to its own regression test (`R-SYN-11: the clock driver of the space tests has stopped
    /// when driving returns, …`): `waiting` runs each time a wait of the driver for a sleeper is registered, `ended`
    /// once the driver's task has ended. Explicit signals, so the test waits for them instead of yielding (L4-R17).
    struct DrivingHooks: Sendable {
        /// A wait of the driver for a sleeper is registered.
        let waiting: @Sendable () -> Void
        /// The driver's task has ended.
        let ended: @Sendable () -> Void
    }

    /// Moves every clock still before the earliest sleeper's deadline to it (never back).
    @available(macOS 15.0, iOS 18.0, *)
    static func advance(_ clocks: [ManualTimeSource]) {
        guard let next = clocks.compactMap(\.nextDeadline).min() else {
            return
        }
        for clock in clocks where clock.monotonicNow() < next {
            clock.advance(to: next)
        }
    }

    // MARK: A purge reclaims the bytes a job waits for before the engine's alarm runs (R-SYN-11; PROBE-C5-4b)

    /// PROBE-C5-4b: `y` (300 B) waits `awaitingSpace` for `x`'s pruned bytes, with the store's deadline for them armed.
    /// A purge of `q` waits out its grace; when it ends the purge's reaper reclaims `q` and `x` before the engine's alarm
    /// for `x`'s deadline runs (the verifier held the engine actor; here the store's clock passes the grace first). The
    /// engine then learnt that nothing was left to reap or schedule and parked `y` `insufficientSpace` on its last
    /// free-space read (taken before either reclaim): the ensure failed `insufficientSpace(300, …)` while the volume held
    /// `y` above the reserve.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-11: ensureAvailable whose member waits for bytes a purge reclaimed before the engine's alarm ran fetches it instead of failing on older free-space figures",
        .timeLimit(.minutes(1))
    )
    func purgeReclaimsBeforeTheAlarm() async throws {
        let time = ManualTimeSource()
        let storeTime = ManualTimeSource()
        let (harness, fileSystem) = Self.harness(time: time, storeTime: storeTime)
        let engine = harness.engine
        let xBytes = EngineFixture.bytes(9_931, count: 300)
        let qBytes = EngineFixture.bytes(9_932, count: 300)
        let yBytes = EngineFixture.bytes(9_933, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineFixture.entry("q", qBytes)
        let y = EngineHarness.onDemand("y", yBytes)
        await harness.serveManifest([x, q])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes), (y, yBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        _ = try await Self.leaveRoom(200, harness: harness, fileSystem: fileSystem)
        // v2 prunes x (doomed for the 60 s grace) and lists q and the on-demand y.
        await harness.serveManifest([q, y], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for reclaim")
        // The ensure's plan counts x's pending bytes as room; y's job waits for them.
        let ensure = Task { await engine.ensureAvailable(scope: .identifiers(["y"])) }
        await engine.awaitCondition { $0.state.jobs[y.transferID]?.state == .blocked(.awaitingSpace) }
        #expect(await engine.readForTests { $0.state.storeDeadline != nil }, "setup: y waits with the store's deadline armed")
        // Only the store's clock passes the grace: the purge reaps q and x before the engine's alarm for x can run.
        let purge = Task { await engine.purge(.scope(.identifiers(["q"]))) }
        let purged = await Self.driving([storeTime]) { await purge.value }
        #expect(purged.successValue?.bytesFreed == Int64(qBytes.count), "the purge freed q: \(purged)")
        #expect(try await harness.store.freeSpace().pendingReclaim == 0, "setup: the purge's reaper reclaimed x's bytes too")
        // The engine's clock catches up: its alarm for x's deadline finds nothing left to reap.
        let ensured = await Self.driving([time, storeTime], fence: engine) { await ensure.value }
        let after = try await harness.store.freeSpace()
        switch ensured {
        case .success(let report):
            #expect(report.present == 1, "y is present: \(report)")
        case .failure(let error):
            Issue.record("y fits once the purge reclaimed q and x, yet the ensure answered \(error) (room above the reserve now \(after.volumeImportant - after.reserveBytes))")
        }
        #expect(await harness.source.starts.filter { $0.id == y.transferID }.count == 1, "y downloaded once")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    // MARK: A job waiting for space fails only on a fresh read (R-SYN-11; review of close-out cycle 5)

    /// `y` waits `awaitingSpace` for `x`'s pruned bytes; the volume then gains room the engine has not read (another
    /// app freed space). At the end of `x`'s grace the store's due work installs a fresh snapshot that nobody
    /// acknowledges, so it reaps nothing and schedules nothing more. The engine parked `y` `insufficientSpace` on its
    /// last read, taken before the volume gained the room: a false shortage. Only a fresh read may decide that.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-11: a job waiting for space that nothing will reclaim is re-checked on a fresh free-space read before it fails with insufficientSpace",
        .timeLimit(.minutes(1))
    )
    func spaceWaitSettledOnAFreshRead() async throws {
        let time = ManualTimeSource()
        let (harness, fileSystem) = Self.harness(time: time)
        let engine = harness.engine
        let xBytes = EngineFixture.bytes(9_941, count: 300)
        let yBytes = EngineFixture.bytes(9_942, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let y = EngineHarness.onDemand("y", yBytes)
        await harness.serveManifest([x])
        await harness.scriptTransfers([(x, xBytes), (y, yBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let ballast = try await Self.leaveRoom(200, harness: harness, fileSystem: fileSystem)
        // v2 prunes x and lists the on-demand y; once its install is acknowledged, x's grace deadline is armed.
        await harness.serveManifest([y], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { engine in
            engine.state.manifestCatchUps == 0 && !engine.state.storeWorkInFlight && engine.state.storeDeadline.map { $0 > time.monotonicNow() } == true
        }
        // From now on no install is acknowledged: once x's grace ends, the store's due work installs a fresh snapshot to
        // prove readers moved on, and without its acknowledgement it reaps nothing.
        await harness.sink.setBehaviour(.ignore)
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for reclaim")
        let ensure = Task { await engine.ensureAvailable(scope: .identifiers(["y"])) }
        await engine.awaitCondition { $0.state.jobs[y.transferID]?.state == .blocked(.awaitingSpace) }
        #expect(await engine.readForTests { $0.state.storeDeadline != nil }, "setup: y waits with the store's deadline armed")
        // The volume gains room the engine has not read.
        try fileSystem.removeItem(at: ballast)
        let ensured = await harness.withClock { await EngineHarness.value(of: ensure) }
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes were never reclaimed")
        switch ensured {
        case .success(let report):
            #expect(report.present == 1, "y is present: \(report)")
        case .failure(let error):
            let after = try await harness.store.freeSpace()
            Issue.record("the volume holds y, yet the ensure answered \(error) (room above the reserve now \(after.volumeImportant - after.reserveBytes))")
        }
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    // MARK: Bytes a purge reclaimed re-admit a job waiting for space at once (R-SYN-10; review of close-out cycle 5)

    /// `y` waits `awaitingSpace` for bytes pending reclaim: `q`'s (purged, its grace ends first) and `x`'s (pruned 10 s
    /// later). The purge reclaims `q`'s bytes, enough for `y`, and the store's next deadline is then `x`'s. The engine
    /// left `y` waiting for that deadline although the volume already held it: only the alarm's own reclaim re-read the
    /// free space.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-10: ensureAvailable whose member waits for space fetches it as soon as a purge reclaimed the bytes, not at the store's next deadline",
        .timeLimit(.minutes(1))
    )
    func purgeReclaimWakesSpaceWaits() async throws {
        let time = ManualTimeSource()
        let storeTime = ManualTimeSource()
        let (harness, fileSystem) = Self.harness(time: time, storeTime: storeTime)
        let engine = harness.engine
        let xBytes = EngineFixture.bytes(9_951, count: 300)
        let qBytes = EngineFixture.bytes(9_952, count: 300)
        let yBytes = EngineFixture.bytes(9_953, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineHarness.onDemand("q", qBytes)
        let y = EngineHarness.onDemand("y", yBytes)
        await harness.serveManifest([x, q, y])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes), (y, yBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        let fetched = await Self.driving([time, storeTime], fence: engine) { await engine.ensureAvailable(scope: .identifiers(["q"])) }
        #expect(fetched.successValue?.present == 1, "setup: q is present: \(fetched)")
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        _ = try await Self.leaveRoom(200, harness: harness, fileSystem: fileSystem)
        // The purge of q dooms it and waits out its grace on the store's clock.
        let purge = Task { await engine.purge(.scope(.identifiers(["q"]))) }
        await storeTime.waitForSleepers(atLeast: 1)
        storeTime.advance(by: 10)
        // v2 prunes x 10 s into q's grace, so x's bytes are reclaimable only 10 s after q's.
        await harness.serveManifest([q, y], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        // A broken setup ends the test here instead of in a wait that never holds (close-out cycle 9).
        try #require(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count + qBytes.count), "setup: q's and x's bytes wait for reclaim")
        let ensure = Task { await engine.ensureAvailable(scope: .identifiers(["y"])) }
        await engine.awaitCondition { engine in
            switch engine.state.jobs[y.transferID]?.state {
            case .blocked(.awaitingSpace)?:
                return engine.state.storeDeadline != nil
            case .downloading?, .verifying?, .committing?, .failed?, .blocked?:
                // Anywhere else y did not wait for the reclaim: the requirement below fails at once.
                return true
            case .queued?, nil:
                return false
            }
        }
        try #require(await engine.readForTests { $0.state.jobs[y.transferID]?.state } == .blocked(.awaitingSpace), "setup: y waits for space")
        // Only the store's clock passes q's grace: the purge reclaims q; x's deadline, 10 s later, is still ahead.
        let purged = await Self.driving([storeTime]) { await purge.value }
        #expect(purged.successValue?.bytesFreed == Int64(qBytes.count), "the purge freed q: \(purged)")
        // The volume now holds y: 200 bytes of room above the reserve plus q's 300 (y may already be written).
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes still wait for their deadline")
        let stateAfterPurge = await engine.readForTests { $0.state.jobs[y.transferID]?.state }
        #expect(stateAfterPurge != .blocked(.awaitingSpace), "y still waits for the store's next deadline after the purge reclaimed its room")
        let ensured = await Self.driving([time, storeTime], fence: engine) { await ensure.value }
        #expect(ensured.successValue?.present == 1, "y is present: \(ensured)")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }
}

extension Result {
    /// The success value, or `nil` for a failure.
    var successValue: Success? {
        if case .success(let value) = self {
            return value
        }
        return nil
    }
}
