import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

// Scratch probe (s3f close-out verification, cycle 17, requirements lens; never committed). S3-R20 item 2: measure, in a
// BenchSync release case, the turn in which 10,000 ids held by other jobs, which the copy maps to one content, move onto
// that content's job as its attempt ends while the follow is owed (`bringInbound`). Three endings of O's attempt: a 404
// whose verdict waits (`defersFailure`), a completed download whose publication begins (`publish`), and, for contrast,
// no ending at all (the owed follow's own bounded turns in the same shape, stepped one turn at a time).
extension ZTronAssetKitBenchmarks {
    @Suite("VerifyC17ReqsConcentration", .serialized)
    struct VerifyC17ReqsConcentration {
        @Test("VERIFY-C17R-CONC-404", .timeLimit(.minutes(10)))
        @available(macOS 15.0, iOS 18.0, *)
        func concentration404() async throws {
            _ = try await VerifyC17Conc.run(members: 1_000, ending: .notFound)
            var runs: [VerifyC17ConcRun] = []
            for _ in 0..<3 {
                runs.append(try await VerifyC17Conc.run(members: 10_000, ending: .notFound))
            }
            for run in runs {
                print("VERIFY-C17R-CONC-404 members 10000: \(run)")
            }
            let waits = runs.map(\.wait)
            print("VERIFY-C17R-CONC-404 best \(waits.min() ?? .infinity) ms, median \(waits.sorted()[1]) ms, runs \(waits) (C2 budget \(SyncBenchmarks.c2Budget) ms)")
            for run in runs {
                #expect(run.owedBefore && run.waitsAfter && run.idsAfter == 10_001, "setup: \(run)")
            }
            #expect((waits.min() ?? .infinity) <= SyncBenchmarks.c2Budget, "VERIFY-C17R-CONC-404: the 404's turn (bringInbound) best of 3: \(waits)")
        }

        @Test("VERIFY-C17R-CONC-PUBLISH", .timeLimit(.minutes(10)))
        @available(macOS 15.0, iOS 18.0, *)
        func concentrationPublish() async throws {
            _ = try await VerifyC17Conc.run(members: 1_000, ending: .publication)
            var runs: [VerifyC17ConcRun] = []
            for _ in 0..<3 {
                runs.append(try await VerifyC17Conc.run(members: 10_000, ending: .publication))
            }
            for run in runs {
                print("VERIFY-C17R-CONC-PUBLISH members 10000: \(run)")
            }
            let waits = runs.map(\.wait)
            print("VERIFY-C17R-CONC-PUBLISH best \(waits.min() ?? .infinity) ms, median \(waits.sorted()[1]) ms, runs \(waits) (C2 budget \(SyncBenchmarks.c2Budget) ms)")
            for run in runs {
                #expect(run.owedBefore && run.idsAfter == 10_001, "setup: \(run)")
            }
            #expect((waits.min() ?? .infinity) <= SyncBenchmarks.c2Budget, "VERIFY-C17R-CONC-PUBLISH: the publication's first turn (bringInbound) best of 3: \(waits)")
        }

        @Test("VERIFY-C17R-CONC-FOLLOW", .timeLimit(.minutes(10)))
        @available(macOS 15.0, iOS 18.0, *)
        func concentrationFollow() async throws {
            _ = try await VerifyC17Conc.run(members: 1_000, ending: .none)
            var runs: [VerifyC17ConcRun] = []
            for _ in 0..<3 {
                runs.append(try await VerifyC17Conc.run(members: 10_000, ending: .none))
            }
            for run in runs {
                print("VERIFY-C17R-CONC-FOLLOW members 10000: \(run)")
            }
            let longest = runs.map { $0.turns.max() ?? 0 }
            print("VERIFY-C17R-CONC-FOLLOW longest follow turn per run \(longest) ms, best \(longest.min() ?? .infinity) ms (C2 budget \(SyncBenchmarks.c2Budget) ms)")
            for run in runs {
                #expect(run.owedBefore && run.idsAfter == 10_001, "setup: \(run)")
            }
            #expect((longest.min() ?? .infinity) <= SyncBenchmarks.c2Budget, "VERIFY-C17R-CONC-FOLLOW: the longest follow turn, best of 3: \(longest)")
        }
    }
}

enum VerifyC17ConcEnding {
    case notFound
    case publication
    case none
}

struct VerifyC17ConcRun: CustomStringConvertible {
    var wait: Double = 0
    var jobsBefore = 0
    var owedBefore = false
    var idsBefore = 0
    var idsAfter = 0
    var waitsAfter = false
    var stateAfter = ""
    var turns: [Double] = []

    var description: String {
        let sorted = self.turns.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        return "wait \(self.wait) ms; jobs \(self.jobsBefore), owed \(self.owedBefore), O ids \(self.idsBefore) -> \(self.idsAfter), verdict waits \(self.waitsAfter), O state \(self.stateAfter); follow turns \(self.turns.count), max \(sorted.last ?? 0) ms, median \(median) ms"
    }
}

enum VerifyC17Conc {
    @available(macOS 15.0, iOS 18.0, *)
    static func run(members count: Int, ending: VerifyC17ConcEnding) async throws -> VerifyC17ConcRun {
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
        switch ending {
        case .notFound, .none:
            await source.script(o.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        case .publication:
            await source.script(o.transferID, [.hold, .stage(oBytes)])
        }
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
        // v3 maps every member to O's content.
        let v3 = (0..<count).map { index in
            SyncBench.entry(String(format: "s%05d", index), oBytes, policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(v3 + [o]), etag: ETag(rawValue: "\"v3\""))])
        await engine.holdFollowFollowUps()
        let sync = Task { await engine.sync(.force) }
        while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
            await Task.yield()
        }
        var result = VerifyC17ConcRun()
        let before = await SyncBench.inbound(engine, o.transferID)
        result.jobsBefore = before.jobs
        result.owedBefore = before.owed
        result.idsBefore = before.ids
        await SyncBench.raiseOwnedTaskPriority(engine)
        switch ending {
        case .notFound:
            result.wait = try await SyncBench.longestWait(on: engine) {
                await source.release(o.transferID, with: .progress(received: 0, expected: nil))
                while !Task.isCancelled, !(await SyncBench.verdictWaits(engine, o.transferID)) {
                    await Task.yield()
                }
            }
            let after = await SyncBench.inbound(engine, o.transferID)
            result.idsAfter = after.ids
            result.waitsAfter = after.waits
            result.stateAfter = await VerifyC17Conc.state(engine, o.transferID)
        case .publication:
            var ids = 0
            var state = ""
            result.wait = try await SyncBench.longestWait(on: engine) {
                await source.release(o.transferID, with: .progress(received: 0, expected: nil))
                while !Task.isCancelled {
                    let read = await VerifyC17Conc.publishing(engine, o.transferID)
                    if read.publishing {
                        ids = read.ids
                        state = read.state
                        break
                    }
                    await Task.yield()
                }
            }
            result.idsAfter = ids
            result.stateAfter = state
        case .none:
            while await VerifyC17Conc.owed(engine) {
                let span = await VerifyC17Conc.releaseOneTurn(engine)
                result.turns.append(span)
                while !Task.isCancelled, await VerifyC17Conc.turnPending(engine) {
                    await Task.yield()
                }
            }
            result.idsAfter = await SyncBench.inbound(engine, o.transferID).ids
        }
        await engine.releaseFollowFollowUps()
        await engine.shutdown()
        _ = await sync.value
        _ = await waiter.value
        return result
    }

    static func state(_ engine: isolated SyncEngine, _ transfer: TransferID) -> String {
        engine.state.jobs[transfer].map { "\($0.state)" } ?? "nil"
    }

    /// Whether O's job left `downloading` (its publication began: `verifying` or later), with its ids then.
    static func publishing(_ engine: isolated SyncEngine, _ transfer: TransferID) -> (publishing: Bool, ids: Int, state: String) {
        guard let job = engine.state.jobs[transfer] else {
            return (true, -1, "nil")
        }
        return (job.state != .downloading, job.assets.count, "\(job.state)")
    }

    static func owed(_ engine: isolated SyncEngine) -> Bool {
        engine.followOwed
    }

    static func turnPending(_ engine: isolated SyncEngine) -> Bool {
        engine.followOwed && !engine.state.followFollowUpWaiting
    }

    /// Runs the held follow turn in this turn, timed, and holds the next one.
    @available(macOS 15.0, iOS 18.0, *)
    static func releaseOneTurn(_ engine: isolated SyncEngine) -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        engine.releaseFollowFollowUps()
        let span = clock.now - start
        engine.holdFollowFollowUps()
        return SyncBench.milliseconds(span)
    }
}
