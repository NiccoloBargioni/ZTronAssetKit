import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

/// Scratch benchmarks (s3f close-out verification, cycle 17, correctness lens; ruling S3-R20 item 2). Never committed.
extension ZTronAssetKitBenchmarks {
    @Suite("VerifyC17Bench")
    struct VerifyC17Bench {
        /// S3-R20's case: 10,000 ids, held by other jobs, that the copy maps to one content whose attempt ends while the
        /// follow is owed. The heartbeat's longest wait from O's 404 to its waiting verdict (`bringInbound` in that turn).
        @Test("C17-BENCH-INBOUND-CONCENTRATION", .timeLimit(.minutes(5)))
        @available(macOS 15.0, iOS 18.0, *)
        func inboundConcentration() async throws {
            let warm = try await VerifyC17BenchSupport.concentration(members: 1_000, with404: true)
            print("C17-BENCH-INBOUND-CONCENTRATION warm-up 1,000: \(warm)")
            var runs: [VerifyC17BenchSupport.Run] = []
            for _ in 0..<3 {
                runs.append(try await VerifyC17BenchSupport.concentration(members: 10_000, with404: true))
            }
            for run in runs {
                print("C17-BENCH-INBOUND-CONCENTRATION 10,000: \(run)")
            }
            let waits = runs.map(\.wait)
            print("C17-BENCH-INBOUND-CONCENTRATION best \(waits.min() ?? -1) ms median \(waits.sorted()[1]) ms (C2 10 ms)")
            #expect((waits.min() ?? .infinity) <= 10.0, "the 404's turn (bringInbound) at 10,000 converging ids: \(waits)")
        }

        /// The follow's own turns in the same shape, without the 404: each held follow-up turn timed inside the actor.
        @Test("C17-BENCH-FOLLOW-CONCENTRATION", .timeLimit(.minutes(5)))
        @available(macOS 15.0, iOS 18.0, *)
        func followConcentration() async throws {
            _ = try await VerifyC17BenchSupport.concentration(members: 1_000, with404: false)
            var runs: [VerifyC17BenchSupport.Run] = []
            for _ in 0..<3 {
                runs.append(try await VerifyC17BenchSupport.concentration(members: 10_000, with404: false))
            }
            for run in runs {
                print("C17-BENCH-FOLLOW-CONCENTRATION 10,000: \(run)")
            }
            let longest = runs.map { $0.turns.max() ?? 0 }
            print("C17-BENCH-FOLLOW-CONCENTRATION longest turn per run \(longest) ms; best \(longest.min() ?? -1) ms (C2 10 ms)")
            #expect((longest.min() ?? .infinity) <= 10.0, "the follow's longest turn at 10,000 converging ids: \(longest)")
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
enum VerifyC17BenchSupport {
    struct Run: CustomStringConvertible {
        let wait: Double
        let turns: [Double]
        let jobs: Int
        let followOwed: Bool
        let verdictWaits: Bool
        let idsBefore: Int
        let idsAfter: Int

        var description: String {
            let sorted = self.turns.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            return "wait \(self.wait) ms, \(self.turns.count) follow turns (longest \(sorted.last ?? 0) ms, median \(median) ms), jobs \(self.jobs), owed \(self.followOwed), verdict waits \(self.verdictWaits), O ids \(self.idsBefore) -> \(self.idsAfter)"
        }
    }

    /// `SyncBench.inboundWalk`'s setup with v3 mapping every member to O's content.
    @available(macOS 15.0, iOS 18.0, *)
    static func concentration(members count: Int, with404: Bool) async throws -> Run {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let conditions = FakeDeviceConditionsSource()
        let capacity = StoragePolicy().reserveFreeBytes + (32 << 20)
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: capacity, opportunisticCapacity: capacity)
        )
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 0x12),
            conditions: conditions,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        let configuration = StoreConfiguration(
            location: .applicationSupport,
            policy: StoragePolicy(minimumResidency: 0, deletionGrace: 60),
            legacy: LegacyMigrationPolicy(enabled: false),
            limits: ManifestLimits(),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
        let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: SyncTuning()))
        let xBytes = Data(repeating: 0x78, count: 2_000)
        let x = SyncBench.entry("x", xBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData([x]), etag: ETag(rawValue: "\"v1\""))])
        await source.script(x.transferID, [.stage(xBytes)])
        _ = try await engine.start().get()
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the setup sync did not complete")
        }
        let oBytes = Data(repeating: 0x6F, count: 16)
        let o = SyncBench.entry("o", oBytes, policy: .onDemand)
        let old = (0..<count).map { index in
            SyncBench.entry(String(format: "s%05d", index), GeneratedPayload.bytes(seed: 0x21_000 + UInt64(index), offset: 0, length: index % 2 == 0 ? 400 : 3_000), policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(old + [o]), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the pruning sync did not complete")
        }
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast")
        await engine.refreshFreeSpace()
        await source.script(o.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        let waiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        while !Task.isCancelled, !(await SyncBench.isRunning(engine, o.transferID)) {
            await Task.yield()
        }
        guard case .success = await engine.registerGroup(old.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.othersAwaitingSpace(engine, count: count, besides: o.transferID)) {
            await Task.yield()
        }
        // v3: every member's id now names O's content.
        let v3 = (0..<count).map { index in
            SyncBench.entry(String(format: "s%05d", index), oBytes, policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(v3 + [o]), etag: ETag(rawValue: "\"v3\""))])
        await engine.holdFollowFollowUps()
        let sync = Task { await engine.sync(.force) }
        while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
            await Task.yield()
        }
        let before = await SyncBench.inbound(engine, o.transferID)
        await SyncBench.raiseOwnedTaskPriority(engine)
        var wait = 0.0
        var turns: [Double] = []
        if with404 {
            wait = try await SyncBench.longestWait(on: engine) {
                await source.release(o.transferID, with: .progress(received: 0, expected: nil))
                while !Task.isCancelled, !(await SyncBench.verdictWaits(engine, o.transferID)) {
                    await Task.yield()
                }
            }
        } else {
            while !Task.isCancelled {
                guard await VerifyC17BenchSupport.followOwed(engine) else {
                    break
                }
                while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
                    await Task.yield()
                }
                turns.append(await VerifyC17BenchSupport.stepHeldFollow(engine))
            }
        }
        let after = await SyncBench.inbound(engine, o.transferID)
        await engine.releaseFollowFollowUps()
        await engine.shutdown()
        _ = await sync.value
        _ = await waiter.value
        return Run(wait: wait, turns: turns, jobs: before.jobs, followOwed: before.owed, verdictWaits: after.waits, idsBefore: before.ids, idsAfter: after.ids)
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func followOwed(_ engine: isolated SyncEngine) -> Bool {
        engine.followOwed
    }

    /// Runs one held follow-up turn, timed inside it, and holds the next one again.
    @available(macOS 15.0, iOS 18.0, *)
    static func stepHeldFollow(_ engine: isolated SyncEngine) -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        engine.releaseFollowFollowUps()
        let span = clock.now - start
        engine.holdFollowFollowUps()
        return SyncBench.milliseconds(span)
    }
}
