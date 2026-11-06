import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

// VERIFY-C18R-DIVERGENCE (cycle-18 reqs verifier probe, scratch only): the concentration shape of S3-R20/S3-R21, then
// the next manifest maps the converged ids away again. The owed follow visits O's job, which holds every id, once: one
// visit moves all of them (`move(_:of:listing:)`), creating a job per id in one turn.
extension ZTronAssetKitBenchmarks {
    @Suite("VerifyC18ReqsDivergence")
    struct VerifyC18ReqsDivergence {
        @Test("VERIFY-C18R-DIVERGENCE: 10,000 ids converged on one content mapped away again", .timeLimit(.minutes(5)))
        @available(macOS 15.0, iOS 18.0, *)
        func divergenceProbe() async throws {
            let warm = try await VerifyC18Divergence.run(members: 1_000, away: .ownContents)
            print("VERIFY-C18R-DIVERGENCE warm-up 1,000: \(warm)")
            var runs: [VerifyC18Divergence.Run] = []
            for _ in 0..<3 {
                runs.append(try await VerifyC18Divergence.run(members: 10_000, away: .ownContents))
            }
            var fresh: [VerifyC18Divergence.Run] = []
            for _ in 0..<3 {
                fresh.append(try await VerifyC18Divergence.run(members: 10_000, away: .freshContents))
            }
            let waits = runs.map(\.wait)
            let freshWaits = fresh.map(\.wait)
            print("VERIFY-C18R-DIVERGENCE 10,000 back to their own contents: longest actor wait \(waits) ms, best \(waits.min() ?? .infinity) ms; runs \(runs)")
            print("VERIFY-C18R-DIVERGENCE 10,000 on to fresh contents: longest actor wait \(freshWaits) ms, best \(freshWaits.min() ?? .infinity) ms; runs \(fresh)")
            for run in runs + fresh {
                #expect(run.converged == 10_001, "setup: O held every id before v4: \(run)")
            }
            #expect((waits.min() ?? .infinity) <= SyncBenchmarks.c2Budget, "own contents: \(waits)")
            #expect((freshWaits.min() ?? .infinity) <= SyncBenchmarks.c2Budget, "fresh contents: \(freshWaits)")
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
enum VerifyC18Divergence {
    enum Away: Sendable {
        case ownContents
        case freshContents
    }

    struct Run: CustomStringConvertible {
        var wait: Double = 0
        var convergeWait: Double = 0
        var converged = 0
        var oAfter = 0
        var jobsAfter = 0
        var owedAfter = false
        var description: String {
            "wait \(self.wait) ms (convergence control \(self.convergeWait) ms); O held \(self.converged) ids before v4, \(self.oAfter) after; \(self.jobsAfter) jobs after, follow owed \(self.owedAfter)"
        }
    }

    static func state(_ engine: isolated SyncEngine, _ transfer: TransferID) -> (owed: Bool, ids: Int, jobs: Int, scheduled: Bool) {
        (engine.followOwed, engine.state.jobs[transfer]?.assets.count ?? 0, engine.state.jobs.count, engine.state.drainFollowUpScheduled || engine.state.followFollowUpScheduled)
    }

    static func run(members count: Int, away: Away) async throws -> Run {
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
        // v3 maps every member to O's content; the follow runs to its end (nothing held): O's job holds every id.
        let v3 = (0..<count).map { index in
            SyncBench.entry(String(format: "s%05d", index), oBytes, policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(v3 + [o]), etag: ETag(rawValue: "\"v3\""))])
        await SyncBench.raiseOwnedTaskPriority(engine)
        var run = Run()
        // Control: the convergence's own follow (the turns that move every holder onto O), timed the same way.
        run.convergeWait = try await SyncBench.longestWait(on: engine) {
            _ = await engine.sync(.force)
            while !Task.isCancelled {
                let now = await VerifyC18Divergence.state(engine, o.transferID)
                if !now.owed && !now.scheduled && now.ids == count + 1 {
                    break
                }
                await Task.yield()
            }
        }
        run.converged = await VerifyC18Divergence.state(engine, o.transferID).ids
        // v4 maps every member away from O again.
        let v4: [ManifestEntry]
        switch away {
        case .ownContents:
            v4 = old
        case .freshContents:
            v4 = (0..<count).map { index in
                SyncBench.entry(String(format: "s%05d", index), GeneratedPayload.bytes(seed: 0x99_000 + UInt64(index), offset: 0, length: index % 2 == 0 ? 400 : 3_000), policy: .onDemand)
            }
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(v4 + [o]), etag: ETag(rawValue: "\"v4\""))])
        run.wait = try await SyncBench.longestWait(on: engine) {
            _ = await engine.sync(.force)
            while !Task.isCancelled {
                let now = await VerifyC18Divergence.state(engine, o.transferID)
                if !now.owed && !now.scheduled {
                    break
                }
                await Task.yield()
            }
        }
        let after = await VerifyC18Divergence.state(engine, o.transferID)
        run.oAfter = after.ids
        run.jobsAfter = after.jobs
        run.owedAfter = after.owed
        await engine.shutdown()
        _ = await waiter.value
        return run
    }
}
