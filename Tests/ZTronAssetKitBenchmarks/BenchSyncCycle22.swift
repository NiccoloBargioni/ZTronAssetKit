import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

/// The C2 pins of Stage 3 close-out cycle 22 (ruling S3-R27): the re-announcement shape of a commit to a stalled
/// subscriber (item 1; d1 review M1) and the `.failed` arm of a job's terminal events (item 1; d1 review M3), each gated
/// at C2's 10 ms on the heartbeat, best of 3, with the commit's or the resolution's own turn recorded.
extension ZTronAssetKitBenchmarks.SyncBenchmarks {
    @Test("R-SYN-11: a commit that re-announces 10,000 ids to a stalled subscriber already holding them holds the engine's actor at most C2's 10 ms", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func commitReannounceTurns() async throws {
        _ = try await SyncBench.reannounceTurn(count: 1_000)
        var runs: [ReannounceRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.reannounceTurn(count: 10_000))
        }
        for run in runs {
            #expect(run.heldBefore == 10_000, "setup: the stalled subscriber held every id's slot before the second commit: \(run)")
            #expect(run.commit.ids == 10_000 && run.commit.interests == 10_000 && run.commit.served && run.commit.committed && run.commit.buffered >= 10_000, "setup: \(run)")
        }
        let waits = runs.map(\.commit.wait)
        let turns = runs.map(\.commit.turn)
        print("R-SYN-11 commitReannounceTurns at 10,000: heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms (budget \(Self.c2Budget) ms best); the commit's own turn \(turns) ms, best \(turns.min() ?? .infinity) ms; runs \(runs)")
        #expect((waits.min() ?? .infinity) <= Self.c2Budget, "\(waits)")
    }

    @Test("R-SYN-11: a 404 that fails 10,000 user waiters with one stalled subscriber holds the engine's actor at most C2's 10 ms", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func commitFailedArmTurns() async throws {
        _ = try await SyncBench.failedArmTurn(count: 1_000)
        var runs: [CommitRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.failedArmTurn(count: 10_000))
        }
        for run in runs {
            #expect(run.ids == 10_000 && run.interests == 10_000 && run.served && run.committed && run.buffered >= 10_000, "setup: \(run)")
        }
        let waits = runs.map(\.wait)
        let turns = runs.map(\.turn)
        print("R-SYN-11 commitFailedArmTurns at 10,000: heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms (budget \(Self.c2Budget) ms best); the resolution's own turn \(turns) ms, best \(turns.min() ?? .infinity) ms; runs \(runs)")
        #expect((waits.min() ?? .infinity) <= Self.c2Budget, "\(waits)")
    }
}

/// What `SyncBench.reannounceTurn` measured and read.
struct ReannounceRun: CustomStringConvertible {
    var commit = CommitRun()
    /// The `.asset` slots the stalled subscriber's queue held before the second commit.
    var heldBefore = 0

    var description: String {
        "\(self.commit); asset slots held before the second commit \(self.heldBefore)"
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    /// The re-announcement shape (ruling S3-R27 item 1; d1 review M1): `commitTurn(.waitersStalledSubscriber)` with the
    /// stalled queue already holding all `count` ids' `assetAvailable` from an earlier commit of the same ids. The earlier
    /// commit's blobs are purged before the waiters register (a purge publishes no per-id event, so the queue keeps the
    /// earlier commit's slots), since a stale location would answer a waiter at once and no job would start.
    static func reannounceTurn(count: Int) async throws -> ReannounceRun {
        var run = ReannounceRun()
        let loadBefore = SyncBench.loadAverages()
        let held = try await SyncBench.heldPublicationBench()
        let engine = held.bench.engine
        let source = held.bench.source
        let bulk = held.bulk
        let time = held.time
        let hBytes = Data(repeating: 0x68, count: 16)
        let members = SyncBench.sharing(count, hBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData(members), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the second sync did not complete")
        }
        try await held.bench.store.flush(.ordered)
        let subscription = try await engine.subscribe().get()
        let holder = members[0].transferID
        await source.script(holder, [.hold, .stage(hBytes)])
        var earlier: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for entry in members {
            let id = entry.identifier
            earlier.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
        }
        try await SyncBench.untilHolding(engine, holder, ids: count, interests: count)
        await source.release(holder, with: .progress(received: 0, expected: nil))
        for caller in earlier {
            guard case .success = await caller.value else {
                throw SyncBenchError.incomplete("setup: the earlier commit did not answer every waiter")
            }
        }
        // The store's purge waits out the deletion grace of the blobs it dooms (`awaitReclaim`) on the bench's manual
        // clock, which a ticker moves to each next deadline while the purge runs.
        let ticker = Task {
            while !Task.isCancelled {
                if let next = time.nextDeadline {
                    time.advance(to: next)
                }
                await Task.yield()
            }
        }
        let purge = await engine.purge(.all)
        ticker.cancel()
        _ = await ticker.value
        guard case .success = purge else {
            throw SyncBenchError.incomplete("setup: the purge failed: \(purge)")
        }
        run.heldBefore = await SyncBench.assetSlots(engine)
        await source.script(holder, [.hold, .stage(hBytes)])
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for entry in members {
            let id = entry.identifier
            callers.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
        }
        try await SyncBench.untilHolding(engine, holder, ids: count, interests: count)
        let before = await SyncBench.userHolding(engine, holder)
        run.commit.ids = before.ids
        run.commit.interests = before.interests
        await bulk.setHolding(true)
        await source.release(holder, with: .progress(received: 0, expected: nil))
        await bulk.waitForHeldUnits(atLeast: 1)
        await SyncBench.raiseOwnedTaskPriority(engine)
        let clock = CommitTurnClock()
        await SyncBench.markCommitTurns(engine) { ended in clock.mark(ended) }
        run.commit.wait = try await SyncBench.longestWait(on: engine) {
            await bulk.setHolding(false)
            await bulk.releaseAll()
            while !Task.isCancelled, await SyncBench.commitUnanswered(engine, holder) {
                await bulk.releaseAll()
                await Task.yield()
            }
        }
        run.commit.turn = clock.longest
        await SyncBench.markCommitTurns(engine, nil)
        run.commit.committed = !(await SyncBench.jobExists(engine, holder))
        run.commit.buffered = await engine.introspect().bufferedEvents
        withExtendedLifetime(subscription) {}
        var served = true
        for caller in callers {
            if case .success = await caller.value {
                continue
            }
            served = false
        }
        run.commit.served = served
        await engine.shutdown()
        run.commit.load = "\(loadBefore) -> \(SyncBench.loadAverages())"
        return run
    }

    /// The `.failed` arm (ruling S3-R27 item 1; d1 review M3): `count` user waiters on one job, every id sharing its
    /// content, that a 404 fails at `.userInitiated` (`resolveAll(.failed)`), with one stalled subscriber; the
    /// resolution's own turn is timed inside the actor.
    static func failedArmTurn(count: Int) async throws -> CommitRun {
        var run = CommitRun()
        let loadBefore = SyncBench.loadAverages()
        let held = try await SyncBench.heldPublicationBench()
        let engine = held.bench.engine
        let source = held.bench.source
        let hBytes = Data(repeating: 0x68, count: 16)
        let members = SyncBench.sharing(count, hBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData(members), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the second sync did not complete")
        }
        try await held.bench.store.flush(.ordered)
        let holder = members[0].transferID
        await source.script(holder, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for entry in members {
            let id = entry.identifier
            callers.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
        }
        try await SyncBench.untilHolding(engine, holder, ids: count, interests: count)
        let before = await SyncBench.userHolding(engine, holder)
        run.ids = before.ids
        run.interests = before.interests
        let subscription = try await engine.subscribe().get()
        await SyncBench.raiseOwnedTaskPriority(engine)
        let clock = CommitTurnClock()
        await SyncBench.markCommitTurns(engine) { ended in clock.mark(ended) }
        run.wait = try await SyncBench.longestWait(on: engine) {
            await source.release(holder, with: .progress(received: 0, expected: nil))
            var spins = 0
            while !Task.isCancelled, await SyncBench.commitUnanswered(engine, holder) {
                spins += 1
                if spins > 50_000_000 {
                    throw SyncBenchError.incomplete("the 404 never resolved H's waiters")
                }
                await Task.yield()
            }
        }
        run.turn = clock.longest
        await SyncBench.markCommitTurns(engine, nil)
        run.committed = !(await SyncBench.jobExists(engine, holder))
        run.buffered = await engine.introspect().bufferedEvents
        withExtendedLifetime(subscription) {}
        var served = true
        for caller in callers {
            if case .failure(.notFound) = await caller.value {
                continue
            }
            served = false
        }
        run.served = served
        await engine.shutdown()
        run.load = "\(loadBefore) -> \(SyncBench.loadAverages())"
        return run
    }

    /// Waits until `holder`'s job holds `ids` ids under `interests` interests and runs.
    static func untilHolding(_ engine: SyncEngine, _ holder: TransferID, ids: Int, interests: Int) async throws {
        var spins = 0
        while !Task.isCancelled {
            let now = await SyncBench.userHolding(engine, holder)
            if now.ids == ids, now.interests == interests, await SyncBench.isRunning(engine, holder) {
                return
            }
            spins += 1
            if spins > 5_000_000 {
                throw SyncBenchError.incomplete("setup: H never held every id: \(now)")
            }
            await Task.yield()
        }
    }

    /// The `.asset` slots of the fullest subscriber queue.
    static func assetSlots(_ engine: isolated SyncEngine) -> Int {
        engine.state.subscribers.values.map { queue in
            queue.liveSlots.filter { if case .asset = $0 { true } else { false } }.count
        }.max() ?? 0
    }
}
