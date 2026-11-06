import Dispatch
import Foundation
import Synchronization
import Testing
import ZTronAssetModel
@testable import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

// Verifier probes, WP-K close-out cycle 4, correctness lens (second file). Scratch copy only; never committed.

/// A planner whose next `plan` call, once armed, blocks until `open()`.
@available(macOS 15.0, iOS 18.0, *)
final class VKC4Gate: Sendable {
    private let state = Mutex((armed: false, entered: false))
    private let semaphore = DispatchSemaphore(value: 0)

    func arm() {
        self.state.withLock { $0.armed = true }
    }

    var entered: Bool {
        self.state.withLock { $0.entered }
    }

    func open() {
        self.semaphore.signal()
    }

    func pass() {
        let blocks = self.state.withLock { state -> Bool in
            guard state.armed else {
                return false
            }
            state.armed = false
            state.entered = true
            return true
        }
        if blocks {
            self.semaphore.wait()
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
struct VKC4GatedPlanner: SyncPlanning {
    let gate: VKC4Gate

    func plan(manifest: ValidatedManifest, snapshot: StorePlanningView, scope: AssetScope, policy: PlanningPolicy, freeSpace: FreeSpace) -> SyncPlan {
        self.gate.pass()
        return StandardSyncPlanner().plan(manifest: manifest, snapshot: snapshot, scope: scope, policy: policy, freeSpace: freeSpace)
    }
}

@Suite("Verifier K-C4 engine probes 2", .serialized)
struct VerifierKC4EngineProbe2 {
    typealias T = EngineLegacyMigrationTransferTests

    /// P16-MULTI (L5K-R16's invariant after L5K-R21 moved the funnel's re-arm out of the per-id read): a prefetch job of
    /// one content under two ids, both with prior-art files that verify. Its read of the first id adopts at `.bulk`
    /// (coalesced: the clock stands still after open's install); its read of the second id then hashes, held here. The
    /// clock passes the window meanwhile. Does the engine's heap hold the store's deadline, and do the readers see the
    /// first id, while the second read runs?
    @available(macOS 15.0, iOS 18.0, *)
    @Test("P16-MULTI: a multi-id job's first bulk adoption while its second read is held", .timeLimit(.minutes(1)))
    func p16Multi() async throws {
        let time = ManualTimeSource()
        let bytes = EngineFixture.bytes(9_980)
        let other = T.catalog(1, seed: 9_990)[0]
        let first = EngineFixture.entry("legacy1", bytes)
        let second = EngineFixture.entry("legacy2", bytes)
        let bulk = SteppedBlockingExecutor(holding: true)
        let harness = EngineHarness.make(
            disk: try EngineRunPathTests.legacyDisk([other, (first, bytes), (second, bytes)], time: time),
            time: time,
            bulk: bulk,
            installInterval: 0.1,
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
        )
        await harness.scriptTransfers([other, (first, bytes)])
        let engine = harness.engine
        let (_, migration) = try await T.startHoldingMigration(harness, bulk: bulk)
        try #require(first.transferID == second.transferID, "premise: one content, one job")
        let pendingAtStart = try await harness.view().records[first.identifier]?.referencedBlob == nil
        let token = try await engine.registerGroup([first.identifier, second.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let firstHash = Set(await bulk.heldUnits).subtracting(migration)
        for unit in firstHash {
            await bulk.release(unit)
        }
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let secondHash = Set(await bulk.heldUnits).subtracting(migration)
        let firstStored = try await harness.view().records[first.identifier]?.referencedBlob != nil
        let installDue = await harness.store.state.core.snapshots.installDue
        let heapBefore = await engine.readForTests { $0.state.heap.deadline(for: .store) }
        let storeNext = await harness.store.nextDeadline()
        // The second read's hash takes 0.3 s.
        time.advance(by: 0.3)
        try await T.runStoreWork(harness)
        let unseen = await T.unseen(harness, [first.identifier])
        let heapAfter = await engine.readForTests { $0.state.heap.deadline(for: .store) }
        let held = Set(await bulk.heldUnits).isSuperset(of: secondHash)
        print("KC4-PROBE P16-MULTI pendingAtStart=\(pendingAtStart) firstStored=\(firstStored) installDue=\(installDue) heapBefore=\(String(describing: heapBefore)) storeNext=\(String(describing: storeNext)) heapAfter=\(String(describing: heapAfter)) unseenFirstAfterWindow=\(unseen.count) secondStillHeld=\(held) now=\(time.monotonicNow())")
        #expect(pendingAtStart && firstStored && installDue && held, "premises")
        #expect(unseen.isEmpty, "P16-MULTI: the first id, adopted at bulk urgency, stayed out of the readers' snapshot past the install window while the job's read of the second id ran (no store deadline on the heap: L5K-R16's invariant)")
        for unit in secondHash {
            await bulk.release(unit)
        }
        // The job ends (answered from the store) before its group is released, so no abandoned attempt sends a request.
        try await T.release(bulk, keeping: migration, on: engine) { engine in
            engine.state.jobs[first.transferID] == nil
        }
        await engine.releaseGroup(token)
        await T.finishMigration(harness, bulk: bulk)
        try await T.expectSettled(harness)
        let startsMulti = await harness.source.starts.map { "\($0)" }
        print("KC4-PROBE P16-MULTI starts=\(startsMulti)")
        #expect(startsMulti.isEmpty)
        await engine.shutdown()
    }

    /// P18-REARM (L5K-C3-00 reproduced against the new code, own variant): three files, the job's asset the last pending
    /// one; an `ensureAvailable` that planned while the asset was absent registers during the job's held RE-S40 re-read and
    /// promotes the job. When it returns, the readers' snapshot must hold the asset, with exactly one install made between
    /// the promotion and the return.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("P18-REARM: ensureAvailable promoted during the funnel's re-read (L5K-C3-00)", .timeLimit(.minutes(1)))
    func p18ReArm() async throws {
        let time = ManualTimeSource()
        let catalog = T.catalog(3, seed: 9_720)
        let gate = VKC4Gate()
        defer {
            gate.open()
        }
        let bulk = SteppedBlockingExecutor(holding: true)
        let harness = EngineHarness.make(
            disk: try EngineRunPathTests.legacyDisk(catalog, time: time),
            time: time,
            bulk: bulk,
            planner: VKC4GatedPlanner(gate: gate),
            installInterval: 0.1,
            legacy: LegacyMigrationPolicy(enabled: true, root: EngineRunPathTests.legacyRoot)
        )
        await harness.scriptTransfers(catalog)
        let engine = harness.engine
        let (_, migration) = try await T.startHoldingMigration(harness, bulk: bulk)
        let pending = try await T.pending(harness, catalog)
        let asset = try #require(catalog.map(\.0).last { pending.contains($0.identifier) })
        let token = try await engine.registerGroup([asset.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let jobHash = Set(await bulk.heldUnits).subtracting(migration)
        gate.arm()
        let ensure = Task { await engine.ensureAvailable(scope: .identifiers([asset.identifier])) }
        while !gate.entered {
            for unit in await bulk.heldUnits where !migration.contains(unit) && !jobHash.contains(unit) {
                await bulk.release(unit)
            }
            try Task.checkCancellation()
            await Task.yield()
        }
        let plannedAbsent = try await T.pending(harness, catalog).contains(asset.identifier)
        await engine.holdNextStoreDeadlineRead()
        for unit in jobHash {
            await bulk.release(unit)
        }
        try await T.release(bulk, keeping: migration, on: engine) { engine in
            engine.storeDeadlineReadHeld || engine.state.jobs[asset.transferID] == nil
        }
        let heldRead = await engine.readForTests { $0.storeDeadlineReadHeld }
        let unseenAtHold = await T.unseen(harness, [asset.identifier]).count
        gate.open()
        try await T.release(bulk, keeping: migration, on: engine) { engine in
            engine.state.jobs[asset.transferID]?.lane == .userInitiated || engine.state.jobs[asset.transferID] == nil
        }
        let promoted = await engine.readForTests { $0.state.jobs[asset.transferID]?.lane == .userInitiated }
        let installsBefore = await harness.sink.offeredKeys.count
        await engine.releaseStoreDeadlineRead()
        let (result, task) = try await T.duringMigration(keeping: migration, bulk: bulk) {
            await ensure.value
        }
        let report = try result.get()
        let unseen = await T.unseen(harness, [asset.identifier])
        let installs = await harness.sink.offeredKeys.count - installsBefore
        print("KC4-PROBE P18-REARM plannedAbsent=\(plannedAbsent) heldRead=\(heldRead) unseenAtHold=\(unseenAtHold) promoted=\(promoted) present=\(report.present) unseenAtReturn=\(unseen.count) installsAfterPromotion=\(installs)")
        #expect(plannedAbsent && heldRead && promoted && unseenAtHold == 1, "premises")
        #expect(report.present == 1)
        #expect(unseen.isEmpty, "P18-REARM: ensureAvailable returned before the readers' snapshot held the asset")
        #expect(installs == 1, "one install, the answer site's: \(installs)")
        await engine.releaseGroup(token)
        await T.finishMigration(harness, bulk: bulk)
        await task.value
        try await T.expectSettled(harness)
        #expect(await harness.source.starts.isEmpty)
        await engine.shutdown()
    }

    /// P20-WAIT (L5K-C3-01 reproduced against the new code, own variant): six files, a prefetch job's adoption holds the
    /// last claimed file, the batch adopts the five others inside the window. Once the migration waits for that adoption,
    /// the heap must hold the store's deadline no later than `nextDeadline()`, and one interval later the readers see the
    /// five files while the job's adoption still holds its file.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("P20-WAIT: batch adoptions while the migration waits (L5K-C3-01)", .timeLimit(.minutes(1)))
    func p20Wait() async throws {
        let time = ManualTimeSource()
        let catalog = T.catalog(6, seed: 9_640)
        let (harness, bulk) = try await T.rateLimitedLaunch(catalog, time: time)
        let engine = harness.engine
        let (_, migration) = try await T.startHoldingMigration(harness, bulk: bulk)
        let pending = try await T.pending(harness, catalog)
        let jobAsset = try #require(catalog.map(\.0).last { pending.contains($0.identifier) })
        let batchIDs = pending.subtracting([jobAsset.identifier])
        let token = try await engine.registerGroup([jobAsset.identifier], lane: .prefetch).get()
        try await bulk.requireHeldUnits(atLeast: migration.count + 1)
        let jobHash = Set(await bulk.heldUnits).subtracting(migration)
        let callsBefore = await engine.readForTests { $0.state.migration.batchCalls }
        let waited = try await T.releaseUntilTheBatchWaits(harness, bulk: bulk, keeping: jobHash, callsBefore: callsBefore)
        // The engine may still be applying the early return's re-read: wait until the loop is suspended in its second call.
        let calls = await engine.readForTests { $0.state.migration.batchCalls } - callsBefore
        await engine.awaitCondition { $0.state.storeWorkRuns == 0 }
        let heapRead = await engine.readForTests { ($0.state.heap.deadline(for: .store), $0.state.storeWorkRuns, $0.state.storeDeadline) }
        let heap = heapRead.0
        let storeNext = await harness.store.nextDeadline()
        print("KC4-PROBE P20-WAIT heapRead=\(heapRead)")
        let unseenAtWait = await T.unseen(harness, batchIDs).count
        time.advance(by: 0.1)
        try await T.runStoreWork(harness)
        let unseen = await T.unseen(harness, batchIDs)
        let held = Set(await bulk.heldUnits).isSuperset(of: jobHash)
        print("KC4-PROBE P20-WAIT waited=\(waited) callsBeforeWait=\(calls) heap=\(String(describing: heap)) storeNext=\(String(describing: storeNext)) unseenAtWait=\(unseenAtWait) unseenAfterOneInterval=\(unseen.count) held=\(held)")
        #expect(waited && held && unseenAtWait == batchIDs.count, "premises")
        if let storeNext {
            #expect(heap.map { $0 <= storeNext } == true, "the heap holds the store deadline no later than nextDeadline()")
        }
        #expect(unseen.isEmpty, "P20-WAIT: \(unseen.count) batch-adopted files unseen one interval later")
        for unit in jobHash {
            await bulk.release(unit)
        }
        await T.finishMigration(harness, bulk: bulk)
        await engine.releaseGroup(token)
        try await T.expectSettled(harness)
        let startsWait = await harness.source.starts.map { "\($0)" }
        print("KC4-PROBE P20-WAIT starts=\(startsWait)")
        #expect(startsWait.isEmpty)
        await engine.shutdown()
    }
}
