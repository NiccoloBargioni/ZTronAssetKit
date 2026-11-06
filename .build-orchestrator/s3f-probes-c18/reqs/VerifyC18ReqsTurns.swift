import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

// Cycle-18 reqs verifier probes (scratch only, never committed).
//
// VERIFY-C18R-SHARED-DIVERGENCE: a 10,000-member prefetch group whose members all map to O's content from the start (one
// job holds 10,001 ids; no convergence, no `bringInbound`), then the next manifest gives every member a content of its
// own: the follow visits O's job once, and that visit moves 10,000 ids (`follow` -> `move`). CONTROL: the same apply when
// every member already had a content of its own (10,000 jobs, the follow's visits budgeted per turn; R-SYN-6's shape).
//
// VERIFY-C18R-CONC-COMMIT: `concentrationPublicationTurns`' shape, then the publication of O's job, which holds 10,001
// ids once the moves are made, completes: the commit turn binds and answers every id (`committed`, `resolveAll`,
// `publishTerminal`). `concentrationPublicationTurns` stops timing when the publication reaches the store.
extension ZTronAssetKitBenchmarks {
    @Suite("VerifyC18ReqsTurns")
    struct VerifyC18ReqsTurns {
        @Test("VERIFY-C18R-SHARED-DIVERGENCE: 10,000 members sharing one content given contents of their own", .timeLimit(.minutes(5)))
        @available(macOS 15.0, iOS 18.0, *)
        func sharedDivergenceProbe() async throws {
            let warm = try await VerifyC18Turns.shared(members: 1_000, sharedFirst: true)
            let warmControl = try await VerifyC18Turns.shared(members: 1_000, sharedFirst: false)
            print("VERIFY-C18R-SHARED-DIVERGENCE warm-up 1,000: shared \(warm); control \(warmControl)")
            var shared: [VerifyC18Turns.SharedRun] = []
            var control: [VerifyC18Turns.SharedRun] = []
            for _ in 0..<3 {
                shared.append(try await VerifyC18Turns.shared(members: 10_000, sharedFirst: true))
                control.append(try await VerifyC18Turns.shared(members: 10_000, sharedFirst: false))
            }
            let waits = shared.map(\.wait)
            let controls = control.map(\.wait)
            print("VERIFY-C18R-SHARED-DIVERGENCE 10,000 shared then own contents: longest actor wait \(waits) ms, best \(waits.min() ?? .infinity) ms; runs \(shared)")
            print("VERIFY-C18R-SHARED-DIVERGENCE CONTROL 10,000 own contents then others: longest actor wait \(controls) ms, best \(controls.min() ?? .infinity) ms; runs \(control)")
            for run in shared {
                #expect(run.oBefore == 10_001 && run.oAfter == 1, "setup: O's job held every id, then only its own: \(run)")
            }
            for run in control {
                #expect(run.oBefore == 1, "setup: control O holds only its own id: \(run)")
            }
            #expect((waits.min() ?? .infinity) <= SyncBenchmarks.c2Budget, "shared: \(waits)")
            #expect((controls.min() ?? .infinity) <= SyncBenchmarks.c2Budget, "control: \(controls)")
        }

        @Test("VERIFY-C18R-SHARED-CONVERGENCE: 10,000 members sharing one content moved onto another content by one visit", .timeLimit(.minutes(5)))
        @available(macOS 15.0, iOS 18.0, *)
        func sharedConvergenceProbe() async throws {
            let warm = try await VerifyC18Turns.sharedConvergence(members: 1_000)
            print("VERIFY-C18R-SHARED-CONVERGENCE warm-up 1,000: \(warm)")
            var visits: [VerifyC18Turns.ConvergeRun] = []
            for _ in 0..<3 {
                visits.append(try await VerifyC18Turns.sharedConvergence(members: 10_000))
            }
            let visitWaits = visits.map(\.wait)
            print("VERIFY-C18R-SHARED-CONVERGENCE 10,000, H's own visit (O downloading): longest actor wait \(visitWaits) ms, best \(visitWaits.min() ?? .infinity) ms; runs \(visits)")
            for run in visits {
                #expect(run.hBefore == 10_000 && run.oAfter == 10_001, "setup: H held every member, then O's job held every id: \(run)")
            }
            #expect((visitWaits.min() ?? .infinity) <= SyncBenchmarks.c2Budget, "visit: \(visitWaits)")
        }

        @Test("VERIFY-C18R-CONC-COMMIT: the commit of a publication holding 10,001 converged ids", .timeLimit(.minutes(5)))
        @available(macOS 15.0, iOS 18.0, *)
        func concentrationCommitProbe() async throws {
            let warm = try await VerifyC18Turns.commit(members: 1_000)
            print("VERIFY-C18R-CONC-COMMIT warm-up 1,000: \(warm)")
            var runs: [VerifyC18Turns.CommitRun] = []
            for _ in 0..<3 {
                runs.append(try await VerifyC18Turns.commit(members: 10_000))
            }
            let waits = runs.map(\.commit)
            let moves = runs.map(\.moves)
            print("VERIFY-C18R-CONC-COMMIT 10,000: the commit window's longest actor wait \(waits) ms, best \(waits.min() ?? .infinity) ms; the moves window (control) \(moves) ms; runs \(runs)")
            for run in runs {
                #expect(run.ids == 10_001 && run.served, "setup: \(run)")
            }
            #expect((waits.min() ?? .infinity) <= SyncBenchmarks.c2Budget, "the commit: \(waits)")
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
enum VerifyC18Turns {
    struct SharedRun: CustomStringConvertible {
        var wait: Double = 0
        var oBefore = 0
        var oAfter = 0
        var jobsAfter = 0
        var description: String {
            "wait \(self.wait) ms; O held \(self.oBefore) ids before the apply, \(self.oAfter) after; \(self.jobsAfter) jobs after"
        }
    }

    struct ConvergeRun: CustomStringConvertible {
        var wait: Double = 0
        var hBefore = 0
        var oAfter = 0
        var owedAfter = false
        var description: String {
            "wait \(self.wait) ms; H held \(self.hBefore) ids before; O's job held \(self.oAfter) after; follow owed after \(self.owedAfter)"
        }
    }

    /// A prefetch group of `count` members that all map to H's content (one job, H's download held), and O, a user
    /// request's 16 bytes, downloading (held). v3 maps every member to O's content; the window is v3's sync and its follow:
    /// H's own visit moves every id onto O (H superseded), each a join onto O's job.
    static func sharedConvergence(members count: Int) async throws -> ConvergeRun {
        let bench = Self.bench()
        let engine = bench.engine
        let source = bench.source
        let xBytes = Data(repeating: 0x78, count: 2_000)
        let x = SyncBench.entry("x", xBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData([x]), etag: ETag(rawValue: "\"v1\""))])
        await source.script(x.transferID, [.stage(xBytes)])
        _ = try await engine.start().get()
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the setup sync did not complete")
        }
        let oBytes = Data(repeating: 0x6F, count: 16)
        let hBytes = Data(repeating: 0x68, count: 16)
        let o = SyncBench.entry("o", oBytes, policy: .onDemand)
        let v2 = (0..<count).map { index in
            SyncBench.entry(String(format: "s%05d", index), hBytes, policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(v2 + [o]), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the second sync did not complete")
        }
        try await bench.store.flush(.ordered)
        let hTransfer = v2[0].transferID
        await source.script(o.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        await source.script(hTransfer, [.hold, .stage(hBytes)])
        let waiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        while !Task.isCancelled, !(await SyncBench.isRunning(engine, o.transferID)) {
            await Task.yield()
        }
        guard case .success = await engine.registerGroup(v2.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, await VerifyC18Turns.state(engine, hTransfer).ids < count {
            await Task.yield()
        }
        var run = ConvergeRun()
        run.hBefore = await VerifyC18Turns.state(engine, hTransfer).ids
        let v3 = (0..<count).map { index in
            SyncBench.entry(String(format: "s%05d", index), oBytes, policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(v3 + [o]), etag: ETag(rawValue: "\"v3\""))])
        await SyncBench.raiseOwnedTaskPriority(engine)
        run.wait = try await SyncBench.longestWait(on: engine) {
            _ = await engine.sync(.force)
            while !Task.isCancelled {
                let now = await VerifyC18Turns.state(engine, o.transferID)
                if !now.owed && !now.scheduled {
                    break
                }
                await Task.yield()
            }
        }
        let after = await VerifyC18Turns.state(engine, o.transferID)
        run.oAfter = after.ids
        run.owedAfter = after.owed
        await engine.shutdown()
        _ = await waiter.value
        return run
    }

    struct CommitRun: CustomStringConvertible {
        var moves: Double = 0
        var commit: Double = 0
        var ids = 0
        var served = false
        var description: String {
            "moves window \(self.moves) ms, commit window \(self.commit) ms; O ids \(self.ids), waiter served \(self.served)"
        }
    }

    static func state(_ engine: isolated SyncEngine, _ transfer: TransferID) -> (owed: Bool, ids: Int, jobs: Int, scheduled: Bool, exists: Bool) {
        (
            engine.followOwed,
            engine.state.jobs[transfer]?.assets.count ?? 0,
            engine.state.jobs.count,
            engine.state.drainFollowUpScheduled || engine.state.followFollowUpScheduled,
            engine.state.jobs[transfer] != nil
        )
    }

    struct Bench {
        let engine: SyncEngine
        let source: FakeRemoteSource
        let store: AssetStore
        let fileSystem: FakeFileSystem
        let bulk: SteppedBlockingExecutor
    }

    static func bench() -> Bench {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let conditions = FakeDeviceConditionsSource()
        let capacity = StoragePolicy().reserveFreeBytes + (32 << 20)
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: capacity, opportunisticCapacity: capacity)
        )
        let bulk = SteppedBlockingExecutor(holding: false)
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: bulk,
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
        return Bench(engine: engine, source: source, store: store, fileSystem: fileSystem, bulk: bulk)
    }

    static func shared(members count: Int, sharedFirst: Bool) async throws -> SharedRun {
        let bench = Self.bench()
        let engine = bench.engine
        let source = bench.source
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
        // v2: the members map to O's content (shared) or each to a content of its own (control); x is pruned, so a member
        // job of its own waits `awaitingSpace`.
        let v2 = (0..<count).map { index in
            let name = String(format: "s%05d", index)
            return sharedFirst ? SyncBench.entry(name, oBytes, policy: .onDemand) : SyncBench.entry(name, GeneratedPayload.bytes(seed: 0x21_000 + UInt64(index), offset: 0, length: index % 2 == 0 ? 400 : 3_000), policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(v2 + [o]), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the pruning sync did not complete")
        }
        try await bench.store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: bench.store, fileSystem: bench.fileSystem, ballast: "ballast")
        await engine.refreshFreeSpace()
        await source.script(o.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        let waiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        while !Task.isCancelled, !(await SyncBench.isRunning(engine, o.transferID)) {
            await Task.yield()
        }
        guard case .success = await engine.registerGroup(v2.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        if sharedFirst {
            while !Task.isCancelled, await VerifyC18Turns.state(engine, o.transferID).ids < count + 1 {
                await Task.yield()
            }
        } else {
            while !Task.isCancelled, !(await SyncBench.othersAwaitingSpace(engine, count: count, besides: o.transferID)) {
                await Task.yield()
            }
        }
        var run = SharedRun()
        run.oBefore = await VerifyC18Turns.state(engine, o.transferID).ids
        // v3 gives every member another content of its own.
        let v3 = (0..<count).map { index in
            SyncBench.entry(String(format: "s%05d", index), GeneratedPayload.bytes(seed: 0x99_000 + UInt64(index), offset: 0, length: index % 2 == 0 ? 400 : 3_000), policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(v3 + [o]), etag: ETag(rawValue: "\"v3\""))])
        await SyncBench.raiseOwnedTaskPriority(engine)
        run.wait = try await SyncBench.longestWait(on: engine) {
            _ = await engine.sync(.force)
            while !Task.isCancelled {
                let now = await VerifyC18Turns.state(engine, o.transferID)
                if !now.owed && !now.scheduled {
                    break
                }
                await Task.yield()
            }
        }
        let after = await VerifyC18Turns.state(engine, o.transferID)
        run.oAfter = after.ids
        run.jobsAfter = after.jobs
        await engine.shutdown()
        _ = await waiter.value
        return run
    }

    static func commit(members count: Int) async throws -> CommitRun {
        let bench = Self.bench()
        let engine = bench.engine
        let source = bench.source
        let bulk = bench.bulk
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
        try await bench.store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: bench.store, fileSystem: bench.fileSystem, ballast: "ballast")
        await engine.refreshFreeSpace()
        await source.script(o.transferID, [.hold, .stage(oBytes)])
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
        let v3 = (0..<count).map { index in
            SyncBench.entry(String(format: "s%05d", index), oBytes, policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(v3 + [o]), etag: ETag(rawValue: "\"v3\""))])
        await engine.holdFollowFollowUps()
        let sync = Task { await engine.sync(.force) }
        while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
            await Task.yield()
        }
        await SyncBench.raiseOwnedTaskPriority(engine)
        var run = CommitRun()
        await bulk.setHolding(true)
        // O's bytes arrive; the moves are made over the follow's turns (released freely), then the publication reaches the
        // store, held at its first unit (as `concentrationPublicationTurns` measures it: the control).
        run.moves = try await SyncBench.longestWait(on: engine) {
            await source.release(o.transferID, with: .progress(received: 0, expected: nil))
            while !Task.isCancelled, !(await SyncBench.leftDownloading(engine, o.transferID)) {
                await Task.yield()
            }
            await engine.releaseFollowFollowUps()
            await bulk.waitForHeldUnits(atLeast: 1)
        }
        run.ids = await VerifyC18Turns.state(engine, o.transferID).ids
        // The publication completes: the store binds every id, and the engine commits them (`committed`).
        run.commit = try await SyncBench.longestWait(on: engine) {
            await bulk.setHolding(false)
            await bulk.releaseAll()
            while !Task.isCancelled, await VerifyC18Turns.state(engine, o.transferID).exists {
                await bulk.releaseAll()
                await Task.yield()
            }
        }
        let served = await waiter.value
        if case .success = served {
            run.served = true
        }
        await engine.shutdown()
        _ = await sync.value
        return run
    }
}
