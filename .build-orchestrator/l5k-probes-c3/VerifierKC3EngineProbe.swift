import Dispatch
import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

// Verifier probes, WP-K close-out cycle 3, correctness lens. Scratch copy only; never committed.

/// A planner whose next `plan` call blocks until the test signals, so a test can hold `ensureAvailable` between its
/// planning view (read before an adoption bound the asset) and its group registration.
@available(macOS 15.0, iOS 18.0, *)
final class VKC3PlannerGate: Sendable {
    struct State: Sendable {
        var armed = false
        var entered = 0
    }

    let state = Mutex(State())
    let semaphore = DispatchSemaphore(value: 0)
}

@available(macOS 15.0, iOS 18.0, *)
struct VKC3GatedPlanner: SyncPlanning {
    let gate: VKC3PlannerGate

    func plan(manifest: ValidatedManifest, snapshot: StorePlanningView, scope: AssetScope, policy: PlanningPolicy, freeSpace: FreeSpace) -> SyncPlan {
        let block = self.gate.state.withLock { state -> Bool in
            guard state.armed else {
                return false
            }
            state.armed = false
            state.entered += 1
            return true
        }
        if block {
            self.gate.semaphore.wait()
        }
        return StandardSyncPlanner().plan(manifest: manifest, snapshot: snapshot, scope: scope, policy: policy, freeSpace: freeSpace)
    }
}

@Suite("Verifier K-C3 engine probes", .serialized)
struct VerifierKC3EngineProbe {
    typealias T = EngineLegacyMigrationTransferTests

    /// PE5 (L5K-R18's window after the lane re-read): a prefetch job's bulk adoption finished and its lane was re-read
    /// (still prefetch); the funnel's RE-S40 re-read (`refreshStoreDeadlineAfterPublish`) then awaits the store. An
    /// `ensureAvailable` that planned while the asset was absent registers its group in that window and joins the job,
    /// promoting it. Its user-initiated asker is then answered from the store: does the readers' snapshot hold the asset?
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PE5: ensureAvailable joining during the funnel's deadline re-read", .timeLimit(.minutes(1)))
    func pe5PromotionDuringTheReRead() async throws {
        let time = ManualTimeSource()
        let catalog = T.catalog(2, seed: 9_700)
        let asset = catalog[1].0
        let bulk = SteppedBlockingExecutor(holding: true)
        let gate = VKC3PlannerGate()
        let harness = EngineHarness.make(
            disk: try EngineRunPathTests.legacyDisk(catalog, time: time),
            time: time,
            bulk: bulk,
            planner: VKC3GatedPlanner(gate: gate),
            installInterval: 0.1,
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
        )
        await harness.scriptTransfers(catalog)
        let engine = harness.engine
        let (_, migration) = try await T.startHoldingMigration(harness, bulk: bulk)
        let token = try await engine.registerGroup([asset.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let jobHash = Set(await bulk.heldUnits).subtracting(migration)
        gate.state.withLock { $0.armed = true }
        let ensure = Task { await engine.ensureAvailable(scope: .identifiers([asset.identifier])) }
        while gate.state.withLock({ $0.entered }) == 0 {
            try Task.checkCancellation()
            for unit in await bulk.heldUnits where !migration.contains(unit) && !jobHash.contains(unit) {
                await bulk.release(unit)
            }
            await Task.yield()
        }
        let viewSawAbsent = try await T.pending(harness, catalog).contains(asset.identifier)
        await engine.holdNextStoreDeadlineRead()
        let deadlineBefore = await engine.readForTests { $0.state.storeDeadline }
        for unit in jobHash {
            await bulk.release(unit)
        }
        try await T.release(bulk, keeping: migration, on: engine) { engine in
            engine.storeDeadlineReadHeld || engine.state.jobs[asset.transferID] == nil || engine.state.jobs[asset.transferID]?.active?.handle != nil
        }
        let held = await engine.readForTests { $0.storeDeadlineReadHeld }
        let laneAtHold = await engine.readForTests { $0.state.jobs[asset.transferID]?.lane }
        let storedAtHold = try await T.pending(harness, catalog).contains(asset.identifier) == false
        let unseenAtHold = await T.unseen(harness, [asset.identifier]).count
        gate.semaphore.signal()
        if held {
            try await T.release(bulk, keeping: migration, on: engine) { engine in
                engine.state.jobs[asset.transferID]?.lane == .userInitiated || engine.state.jobs[asset.transferID] == nil
            }
        }
        let promoted = await engine.readForTests { $0.state.jobs[asset.transferID]?.lane == .userInitiated }
        await engine.releaseStoreDeadlineRead()
        let (result, task) = try await T.duringMigration(keeping: migration, bulk: bulk) {
            await ensure.value
        }
        let report = try result.get()
        let unseen = await T.unseen(harness, [asset.identifier])
        let starts = await harness.source.starts.count
        print("KC3-PROBE PE5 heldRead=\(held) laneAtHold=\(String(describing: laneAtHold)) storedAtHold=\(storedAtHold) unseenAtHold=\(unseenAtHold) viewSawAbsent=\(viewSawAbsent) promotedDuringHold=\(promoted) deadlineBefore=\(String(describing: deadlineBefore)) present=\(report.present) missing=\(report.missing) unseenAtReturn=\(unseen.count) starts=\(starts)")
        #expect(held, "premise: the funnel's re-read awaited the store")
        #expect(promoted, "premise: ensureAvailable joined the job during that re-read")
        #expect(report.present == 1 && report.missing == 0)
        #expect(unseen.isEmpty, "PE5: ensureAvailable (user-initiated) returned before the readers' snapshot held the asset (L5K-R18)")
        #expect(starts == 0)
        await engine.releaseGroup(token)
        await T.finishMigration(harness, bulk: bulk)
        await task.value
        try await T.expectSettled(harness)
        await engine.shutdown()
    }

    /// PE1 (L5K-C2-02's shape, written anew with 150 files): a bulk sync during held migration adopts every pending file
    /// at bulk urgency; after the window every one reaches the readers, within the install rate, and the tripwire holds.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PE1: 150 sync adoptions reach the readers after the window", .timeLimit(.minutes(2)))
    func pe1SyncAdoptionsReachTheReaders() async throws {
        let time = ManualTimeSource()
        let catalog = T.catalog(150, seed: 11_000)
        let (harness, bulk) = try await T.rateLimitedLaunch(catalog, time: time)
        let engine = harness.engine
        let (_, migration) = try await T.startHoldingMigration(harness, bulk: bulk)
        let pending = try await T.pending(harness, catalog)
        let installs0 = await harness.sink.offeredKeys.count
        let (outcome, task) = try await T.duringMigration(keeping: migration, bulk: bulk) {
            await engine.sync(.force)
        }
        let report = try #require(outcome.completeReport, "\(outcome)")
        let unseenAfterSync = await T.unseen(harness, pending).count
        let installsDuringSync = await harness.sink.offeredKeys.count - installs0
        let heapStore = await engine.readForTests { $0.state.heap.deadline(for: .store) }
        let storeNext = await harness.store.nextDeadline()
        try await T.runStoreWork(harness)
        let unseenAfterWindow = await T.unseen(harness, pending).count
        let installsTotal = await harness.sink.offeredKeys.count - installs0
        let starts = await harness.source.starts.count
        print("KC3-PROBE PE1 pending=\(pending.count) fetched=\(report.fetched) installsDuringSync=\(installsDuringSync) unseenAfterSync=\(unseenAfterSync) heapStore=\(String(describing: heapStore)) storeNext=\(String(describing: storeNext)) unseenAfterWindow=\(unseenAfterWindow) installsTotal=\(installsTotal) starts=\(starts) now=\(time.monotonicNow())")
        #expect(starts == 0)
        #expect(unseenAfterWindow == 0, "PE1: \(unseenAfterWindow) of \(pending.count) adopted files never reached the readers")
        #expect(installsDuringSync <= 2)
        await T.finishMigration(harness, bulk: bulk)
        await task.value
        try await T.expectSettled(harness)
        #expect(await T.unseen(harness, catalog.map(\.0.identifier)).isEmpty)
        await engine.shutdown()
    }

    /// PE2 (L5K-C2-03's shape, written anew): 30 standard and 30 on-demand prior-art files, production windows (commit
    /// 0.25 s, install 0.1 s). A bulk sync during held migration adopts the standard ones and takes the launch run's place;
    /// then migration runs freely and adopts the on-demand ones in its own batches. Nothing moves the clock until the
    /// migration has finished; then the clock is driven until idle-silent.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PE2: migration's own batches after the sync reach the readers", .timeLimit(.minutes(2)))
    func pe2MigrationBatchesReachTheReaders() async throws {
        let time = ManualTimeSource()
        let standard = T.catalog(30, seed: 12_000)
        let pages = (0..<30).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(12_500 + UInt64(index))
            return (EngineFixture.entry("page\(index)", bytes, policy: .onDemand), bytes)
        }
        let catalog = standard + pages
        let (harness, bulk) = try await T.rateLimitedLaunch(catalog, time: time)
        let engine = harness.engine
        let (_, migration) = try await T.startHoldingMigration(harness, bulk: bulk)
        let (outcome, task) = try await T.duringMigration(keeping: migration, bulk: bulk) {
            await engine.sync(.force)
        }
        _ = try #require(outcome.completeReport, "\(outcome)")
        let parkedAfterSync = await engine.readForTests { $0.state.migration.launchRunWaiting }
        await T.finishMigration(harness, bulk: bulk)
        await task.value
        let unseenAtMigrationEnd = await T.unseen(harness, catalog.map(\.0.identifier)).count
        let heapStore = await engine.readForTests { $0.state.heap.deadline(for: .store) }
        let storeNext = await harness.store.nextDeadline()
        try await T.expectSettled(harness)
        let unseen = await T.unseen(harness, catalog.map(\.0.identifier))
        let starts = await harness.source.starts.count
        print("KC3-PROBE PE2 parkedAfterSync=\(parkedAfterSync) unseenAtMigrationEnd=\(unseenAtMigrationEnd) heapStore=\(String(describing: heapStore)) storeNext=\(String(describing: storeNext)) unseenAfterIdle=\(unseen.count) starts=\(starts)")
        #expect(starts == 0)
        #expect(unseen.isEmpty, "PE2: \(unseen.count) of \(catalog.count) adopted files never reached the readers")
        await engine.shutdown()
    }

    /// PE3 (crossed answers, stochastic): a prefetch group at the default lane registered right after start beside a
    /// migration that runs at its own pace (inline executors), installInterval 0.1. Every file is adopted by one side or
    /// the other; once both are done the clock is driven to idle-silent: every file must be visible, nothing downloaded,
    /// and the tripwire must hold. Repeated over launches.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PE3: prefetch beside a free-running migration, repeated", .timeLimit(.minutes(4)))
    func pe3PrefetchBesideFreeMigration() async throws {
        var failures: [String] = []
        var unchecked = 0
        for launch in 0..<12 {
            let time = ManualTimeSource()
            let catalog = T.catalog(140, seed: 20_000 + UInt64(launch) * 1_000)
            let harness = EngineHarness.make(
                disk: try EngineRunPathTests.legacyDisk(catalog, time: time),
                time: time,
                commitInterval: launch % 2 == 0 ? 0.25 : 0,
                installInterval: 0.1,
                legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
            )
            // No manifest scripted: the origin answers "not modified", so the launch run that follows migration applies
            // nothing and installs nothing that could flush a missed trailing install.
            await harness.scriptTransfers(catalog)
            let engine = harness.engine
            await engine.setOwnedTaskPriorityFloor(EngineHarness.ownedTaskPriorityFloor)
            _ = try await engine.start().get()
            let ids = catalog.map(\.0.identifier)
            let token = try await engine.registerGroup(ids.reversed(), lane: .prefetch).get()
            let settled: @Sendable (isolated SyncEngine) -> Bool = { engine in
                guard let group = engine.state.groups[token] else {
                    return true
                }
                return group.claimCursor == group.members.count && group.pending.isEmpty && engine.state.jobs.isEmpty
                    && !engine.state.migration.running
            }
            if launch % 2 == 0 {
                await harness.withClock {
                    await engine.awaitCondition(settled)
                }
            } else {
                await engine.awaitCondition(settled)
            }
            let unseenBeforeDrive = await T.unseen(harness, ids).count
            let installsBeforeDrive = await harness.sink.offeredKeys.count
            await engine.releaseGroup(token)
            try await harness.drive { $0.isIdleSilent }
            let installsInDrive = await harness.sink.offeredKeys.count - installsBeforeDrive
            let idle = await harness.idleViolations()
            let unseen = await T.unseen(harness, ids)
            let starts = await harness.source.starts.count
            let pendingFlag = await engine.readForTests { $0.state.migration.pending }
            print("KC3-PROBE PE3 launch=\(launch) unseenBeforeDrive=\(unseenBeforeDrive) installsInDrive=\(installsInDrive) unseenAfterIdle=\(unseen.count) starts=\(starts) migrationPending=\(pendingFlag) tripwireChecked=\(idle.checked) violations=\(idle.violations)")
            if !unseen.isEmpty || starts != 0 || !idle.violations.isEmpty {
                failures.append("launch \(launch): unseen=\(unseen.count) starts=\(starts) violations=\(idle.violations)")
            }
            if !idle.checked {
                unchecked += 1
            }
            await engine.shutdown()
        }
        #expect(failures.isEmpty, "\(failures)")
        print("KC3-PROBE PE3 uncheckedTripwires=\(unchecked)")
    }

    /// PE6 (L5K-R17 with a resolve's adoption, then shutdown): the resolve's adopt-on-demand holds the last claimed file
    /// (its hash unit held). The batch adopts the other file and must wait without calling again; then the engine is shut
    /// down while that adoption is still held, and the adoption is let go: shutdown must complete and the resolve answer.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PE6: a resolve holds the last legacy file, then shutdown", .timeLimit(.minutes(1)))
    func pe6ResolveHoldsTheLastFileThenShutdown() async throws {
        let time = ManualTimeSource()
        let catalog = T.catalog(2, seed: 9_800)
        let (harness, bulk) = await T.launch(disk: try EngineRunPathTests.legacyDisk(catalog, time: time), time: time, served: catalog)
        let engine = harness.engine
        let (_, migration) = try await T.startHoldingMigration(harness, bulk: bulk)
        let resolve = Task { await engine.awaitAsset(catalog[1].0.identifier, lane: .userInitiated) }
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let resolveHash = Set(await bulk.heldUnits).subtracting(migration)
        let calls0 = await engine.readForTests { $0.state.migration.batchCalls }
        let installs0 = await harness.sink.offeredKeys.count
        for unit in migration {
            await bulk.release(unit)
        }
        try await harness.sink.requireInstalls(atLeast: installs0 + 1)
        for _ in 0..<200 {
            _ = await engine.readForTests { $0.state.migration.batchCalls }
            await Task.yield()
        }
        let callsWhileHeld = await engine.readForTests { $0.state.migration.batchCalls } - calls0
        let shutdown = Task { await engine.shutdown() }
        for _ in 0..<200 {
            await Task.yield()
        }
        let lifecycleWhileHeld = await engine.introspect().lifecycle
        for unit in resolveHash {
            await bulk.release(unit)
        }
        await bulk.setHolding(false)
        await shutdown.value
        let answer = await resolve.value
        let starts = await harness.source.starts.count
        print("KC3-PROBE PE6 callsWhileHeld=\(callsWhileHeld) lifecycleWhileHeld=\(lifecycleWhileHeld) resolve=\(answer) starts=\(starts)")
        #expect(callsWhileHeld <= 1)
        #expect(starts == 0)
    }

    /// PSPIN-c3 (L5K-R17, two jobs hold the last two files): the batch must wait for one, then the other, without a call
    /// in between, and finish in at most two calls.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PSPIN-c3: two jobs hold the last two legacy files", .timeLimit(.minutes(1)))
    func pspinTwoJobsHoldTheLastTwoFiles() async throws {
        let time = ManualTimeSource()
        let catalog = T.catalog(4, seed: 9_900)
        let (harness, bulk) = await T.launch(disk: try EngineRunPathTests.legacyDisk(catalog, time: time), time: time, served: catalog)
        let engine = harness.engine
        let (_, migration) = try await T.startHoldingMigration(harness, bulk: bulk)
        let pending = try await T.pending(harness, catalog)
        let candidates = catalog.map(\.0).filter { pending.contains($0.identifier) }
        // The batch holds the first pending file; the jobs take the others.
        let others = Array(candidates.dropFirst().suffix(2))
        try #require(others.count == 2, "premise: two files besides the batch's: \(candidates.count)")
        let tokenA = try await engine.registerGroup([others[0].identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let hashA = Set(await bulk.heldUnits).subtracting(migration)
        let tokenB = try await engine.registerGroup([others[1].identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + hashA.count + 1)
        let hashB = Set(await bulk.heldUnits).subtracting(migration).subtracting(hashA)
        let calls0 = await engine.readForTests { $0.state.migration.batchCalls }
        let kept = hashA.union(hashB)
        for _ in 0..<2_000 {
            for unit in await bulk.heldUnits where !kept.contains(unit) {
                await bulk.release(unit)
            }
            await Task.yield()
        }
        let callsBothHeld = await engine.readForTests { $0.state.migration.batchCalls } - calls0
        for unit in hashA {
            await bulk.release(unit)
        }
        await engine.awaitCondition { $0.state.jobs[others[0].transferID] == nil }
        for _ in 0..<2_000 {
            for unit in await bulk.heldUnits where !hashB.contains(unit) {
                await bulk.release(unit)
            }
            await Task.yield()
        }
        let callsOneHeld = await engine.readForTests { $0.state.migration.batchCalls } - calls0
        let runningOneHeld = await engine.readForTests { $0.state.migration.running }
        for unit in hashB {
            await bulk.release(unit)
        }
        await T.finishMigration(harness, bulk: bulk)
        let calls = await engine.readForTests { $0.state.migration.batchCalls } - calls0
        let starts = await harness.source.starts.count
        print("KC3-PROBE PSPIN-c3 callsBothHeld=\(callsBothHeld) callsOneHeld=\(callsOneHeld) runningOneHeld=\(runningOneHeld) callsTotal=\(calls) starts=\(starts)")
        #expect(callsBothHeld <= 1)
        #expect(callsOneHeld <= 1)
        #expect(calls <= 2)
        #expect(starts == 0)
        #expect(try await T.allPresent(harness, catalog))
        await engine.releaseGroup(tokenA)
        await engine.releaseGroup(tokenB)
        try await T.expectSettled(harness)
        await engine.shutdown()
    }
}

extension VerifierKC3EngineProbe {
    /// DIAG-R17: the shape of `migrationLoopWaitsForTheLastAdoption` (two files, a prefetch job adopts legacy1), repeated,
    /// recording whether its premise held: after the start the migration holds legacy0 (two files pending), so the job's
    /// adoption takes legacy1 from the queue. When legacy0 slipped through during the start the batch holds legacy1 and
    /// the job joins it: the batch then finishes by itself and the loop's call count says nothing about L5K-R17.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("DIAG-R17: premise of the engine's L5K-R17 test shape, repeated", .timeLimit(.minutes(2)))
    func diagR17Premise() async throws {
        var rows: [String] = []
        for run in 0..<20 {
            let time = ManualTimeSource()
            let catalog = T.catalog(2, seed: 9_100)
            let (harness, bulk) = await T.launch(disk: try EngineRunPathTests.legacyDisk(catalog, time: time), time: time, served: catalog)
            let engine = harness.engine
            let (_, migration) = try await T.startHoldingMigration(harness, bulk: bulk)
            let pendingAfterStart = try await T.pending(harness, catalog).count
            let token = try await engine.registerGroup([catalog[1].0.identifier], lane: .prefetch).get()
            try await bulk.requireHeldUnits(atLeast: migration.count + 1)
            let jobHash = Set(await bulk.heldUnits).subtracting(migration)
            let callsBefore = await engine.readForTests { $0.state.migration.batchCalls }
            let installsBefore = await harness.sink.offeredKeys.count
            for unit in migration {
                await bulk.release(unit)
            }
            try await harness.sink.requireInstalls(atLeast: installsBefore + 1)
            for _ in 0..<64 {
                _ = await engine.readForTests { $0.state.migration.batchCalls }
            }
            let callsWhileHeld = await engine.readForTests { $0.state.migration.batchCalls } - callsBefore
            let runningWhileHeld = await engine.readForTests { $0.state.migration.running }
            for unit in jobHash {
                await bulk.release(unit)
            }
            await T.finishMigration(harness, bulk: bulk)
            let calls = await engine.readForTests { $0.state.migration.batchCalls } - callsBefore
            rows.append("run=\(run) pendingAfterStart=\(pendingAfterStart) callsWhileHeld=\(callsWhileHeld) runningWhileHeld=\(runningWhileHeld) calls=\(calls)")
            await engine.releaseGroup(token)
            await engine.shutdown()
        }
        for row in rows {
            print("KC3-PROBE DIAG-R17 \(row)")
        }
        let premiseMissed = rows.filter { $0.contains("pendingAfterStart=1") }.count
        print("KC3-PROBE DIAG-R17 premiseMissed=\(premiseMissed) of \(rows.count)")
        #expect(rows.count == 20)
    }

    /// PE2b (L5K-C2-03 isolated): the sync's own trailing install is run first while migration is still held, so nothing
    /// on the heap remains from the sync; then migration adopts 30 on-demand files in its own batches. Driving the clock
    /// afterwards must show them all: only the loop's re-arm can schedule their trailing install.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PE2b: migration batches after the sync's own trailing install", .timeLimit(.minutes(2)))
    func pe2bMigrationBatchesAfterTheSyncsInstall() async throws {
        let time = ManualTimeSource()
        let standard = T.catalog(20, seed: 13_000)
        let pages = (0..<30).map { index -> (ManifestEntry, Data) in
            let bytes = EngineFixture.bytes(13_500 + UInt64(index))
            return (EngineFixture.entry("page\(index)", bytes, policy: .onDemand), bytes)
        }
        let catalog = standard + pages
        let (harness, bulk) = try await T.rateLimitedLaunch(catalog, time: time)
        let engine = harness.engine
        let (_, migration) = try await T.startHoldingMigration(harness, bulk: bulk)
        let (outcome, task) = try await T.duringMigration(keeping: migration, bulk: bulk) {
            await engine.sync(.force)
        }
        _ = try #require(outcome.completeReport, "\(outcome)")
        try await T.runStoreWork(harness)
        let unseenStandardAfterTrailing = await T.unseen(harness, standard.map(\.0.identifier)).count
        let heapAfterTrailing = await engine.readForTests { $0.state.heap.deadline(for: .store) }
        await T.finishMigration(harness, bulk: bulk)
        await task.value
        let unseenPagesAtEnd = await T.unseen(harness, pages.map(\.0.identifier)).count
        let heapAtEnd = await engine.readForTests { $0.state.heap.deadline(for: .store) }
        let storeNextAtEnd = await harness.store.nextDeadline()
        try await harness.drive { $0.isIdleSilent }
        let idle = await harness.idleViolations()
        let unseen = await T.unseen(harness, catalog.map(\.0.identifier))
        let starts = await harness.source.starts.count
        print("KC3-PROBE PE2b unseenStandardAfterTrailing=\(unseenStandardAfterTrailing) heapAfterTrailing=\(String(describing: heapAfterTrailing)) unseenPagesAtMigrationEnd=\(unseenPagesAtEnd) heapAtEnd=\(String(describing: heapAtEnd)) storeNextAtEnd=\(String(describing: storeNextAtEnd)) unseenAfterIdle=\(unseen.count) tripwire=\(idle.checked)/\(idle.violations) starts=\(starts)")
        #expect(starts == 0)
        #expect(unseenStandardAfterTrailing == 0)
        #expect(unseen.isEmpty, "PE2b: \(unseen.count) adopted files never reached the readers")
        #expect(idle.checked && idle.violations.isEmpty)
        await engine.shutdown()
    }
}

extension VerifierKC3EngineProbe {
    /// DIAG2-R17: the engine's call count over a long observation while a job's adoption holds the last file.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("DIAG2-R17: call count over a long observation", .timeLimit(.minutes(1)))
    func diag2R17() async throws {
        for run in 0..<4 {
            let time = ManualTimeSource()
            let catalog = T.catalog(3, seed: 9_150 + UInt64(run))
            let (harness, bulk) = await T.launch(disk: try EngineRunPathTests.legacyDisk(catalog, time: time), time: time, served: catalog)
            let engine = harness.engine
            let (_, migration) = try await T.startHoldingMigration(harness, bulk: bulk)
            let pending = try await T.pending(harness, catalog)
            let last = try #require(catalog.map(\.0).last { pending.contains($0.identifier) })
            let token = try await engine.registerGroup([last.identifier], lane: .prefetch).get()
            try await bulk.requireHeldUnits(atLeast: migration.count + 1)
            let jobHash = Set(await bulk.heldUnits).subtracting(migration)
            let callsBefore = await engine.readForTests { $0.state.migration.batchCalls }
            // Release everything but the job's hash unit.
            var samples: [Int] = []
            for step in 0..<3_000 {
                for unit in await bulk.heldUnits where !jobHash.contains(unit) {
                    await bulk.release(unit)
                }
                await Task.yield()
                if [64, 500, 1_500, 2_999].contains(step) {
                    samples.append(await engine.readForTests { $0.state.migration.batchCalls } - callsBefore)
                }
            }
            let pendingWhileHeld = try await T.pending(harness, catalog).count
            for unit in jobHash {
                await bulk.release(unit)
            }
            await T.finishMigration(harness, bulk: bulk)
            let calls = await engine.readForTests { $0.state.migration.batchCalls } - callsBefore
            print("KC3-PROBE DIAG2-R17 run=\(run) pendingAfterStart=\(pending.count) pendingWhileHeld=\(pendingWhileHeld) callSamples=\(samples) calls=\(calls)")
            await engine.releaseGroup(token)
            await engine.shutdown()
        }
        #expect(Bool(true) == true)
    }
}
