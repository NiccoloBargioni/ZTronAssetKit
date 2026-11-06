import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// The C2 pins of the take-off before a waiting verdict (Stage 3 close-out cycle 21, ruling S3-R26 item 1;
/// `integrate-rr21.md` R6 and R7, site 2, and its pins "Site 2 with user waiters" and "Zeroing"): a job J whose verdict
/// waits holds ids a visit-first engine's visits had moved off it before the verdict and a later apply moved back; the
/// drain takes them off before the verdict in the verdict's turn, O(held), and owes their re-routes, which drain turns
/// make 512 ids a turn. Each figure is printed with the host's load averages (S3-R23).
extension ZTronAssetKitBenchmarks.SyncBenchmarks {
    /// C2 of the take-off of 10,000 user waiters' interests, all of J's or half of them (ruling 6 of `integrate-rr21.md`):
    /// the verdict's turn reads the held ids' holders from the index, removes each wholly held interest in token order
    /// and owes their re-routes; the drain then makes them. This turn decides whether the take-off is chunked before the
    /// verdict. The heartbeat's longest wait and the longest held turn, timed inside the actor, best of three against C2,
    /// after a warm-up.
    @Test("R-SYN-11: the drain's take-off of 10,000 user waiters' interests before a verdict, all of a job's or half of them, holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(15)))
    @available(macOS 15.0, iOS 18.0, *)
    func movedBeforeDrainWaitersTurns() async throws {
        try await Self.takeOffTurns(held: 10_000, after: 0, label: "10,000 user waiters, all held")
        try await Self.takeOffTurns(held: 5_000, after: 0, label: "10,000 user waiters, half held")
    }

    /// C2 of a verdict whose job holds 5,000 ids moved off it before the verdict and back, and 5,000 that an apply after
    /// the deferral moved away (the "Zeroing" pin): the take-off owes the 5,000 and spends the verdict's turn, so the visit
    /// after the verdict moves none of the other 5,000 in it and leaves its whole move as the follow's rest, which the
    /// follow's next turns make 512 ids a turn before the drain makes the batch.
    @Test("R-SYN-11: a verdict whose take-off owes 5,000 re-routes and whose visit moves 5,000 more spends its turn on the take-off and holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(15)))
    @available(macOS 15.0, iOS 18.0, *)
    func movedBeforeAndAfterTurns() async throws {
        try await Self.takeOffTurns(held: 5_000, after: 5_000, label: "5,000 ids moved before and 5,000 after the deferral")
    }

    /// Runs `SyncBench.takeOffDrain` once at a tenth of the scale and three times at 10,000 members, checks every run's
    /// setup, and gates the best of the three heartbeats, and of the three longest held turns, against C2.
    @available(macOS 15.0, iOS 18.0, *)
    static func takeOffTurns(held: Int, after: Int, label: String) async throws {
        _ = try await SyncBench.takeOffDrain(members: 1_000, held: held / 10, after: after / 10, waiters: after == 0)
        var runs: [TakeOffDrainRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.takeOffDrain(members: 10_000, held: held, after: after, waiters: after == 0))
        }
        for run in runs {
            #expect(run.movedBefore == held && run.given && run.owedAtVerdict == held && run.madeAtVerdict == 0, "setup, \(label): the verdict waited with \(held) ids moved before it, and its turn owed them all and made none: \(run)")
            #expect(run.rerouted == held + (10_000 - held - after), "setup, \(label): the drain re-routed the held ids onto J: \(run)")
            if after > 0 {
                #expect(run.movingAtVerdict && run.movedAtVerdict == 0 && run.movedAfter == after, "setup, \(label): the verdict's turn moved none of the visit's \(after) ids and left its whole move as the follow's rest, which moved them all: \(run)")
            }
        }
        let waits = runs.map(\.wait)
        let turns = runs.map { $0.turns.max() ?? 0 }
        let verdicts = runs.map(\.verdictTurn)
        print("R-SYN-11 take-off, \(label): heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms; longest held turn \(turns) ms, best \(turns.min() ?? .infinity) ms; the verdict's turn \(verdicts) ms (budget \(Self.c2Budget) ms best); load \(SyncBench.loadAverages()); runs \(runs)")
        #expect((waits.min() ?? .infinity) <= Self.c2Budget, "\(label), the heartbeat: \(waits)")
        #expect((turns.min() ?? .infinity) <= Self.c2Budget, "\(label), the held turns: \(turns)")
    }
}

/// One run of `SyncBench.takeOffDrain`.
struct TakeOffDrainRun: CustomStringConvertible {
    /// The heartbeat's longest wait, in milliseconds, from the release of the held turns until the drain is over.
    var wait: Double = 0
    /// The held follow and drain turns released in that window, each timed inside the actor, in milliseconds.
    var turns: [Double] = []
    /// The turn that gave J's verdict, timed inside the actor.
    var verdictTurn: Double = 0
    /// The ids J's waiting verdict recorded as moved before it.
    var movedBefore = 0
    /// Whether the drain gave J's verdict.
    var given = false
    /// After the verdict's turn: the distinct ids owed, the held ids J held again, whether the visit's rest waited, and
    /// the visit's ids moved.
    var owedAtVerdict = 0
    var madeAtVerdict = 0
    var movingAtVerdict = false
    var movedAtVerdict = 0
    /// The visit's ids moved once the drain is over.
    var movedAfter = 0
    /// J's ids once the drain is over.
    var rerouted = 0

    var description: String {
        let sorted = self.turns.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        return "wait \(self.wait) ms, verdict turn \(self.verdictTurn) ms; moved before \(self.movedBefore), given \(self.given), owed \(self.owedAtVerdict), made \(self.madeAtVerdict), rest \(self.movingAtVerdict), visit moved \(self.movedAtVerdict) then \(self.movedAfter), J \(self.rerouted); \(self.turns.count) held turns, longest \(sorted.last ?? 0) ms, median \(median) ms"
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    /// A job J of `count` on-demand members of content C whose 500 waits for the follow with `held` of them moved before
    /// it and moved back, and `after` that the apply after the deferral moves to E (`movedBeforeDrainWaitersTurns`,
    /// `movedBeforeAndAfterTurns`; built as `movedBeforeDrain`): the members are wanted by a user waiter each (`waiters`)
    /// or one prefetch group, and 600 fillers of their own contents, ahead of them in the manifest, by another group. v3
    /// gives every filler a new content and the `held` members D's, with the follow's follow-ups held after its first
    /// turn, which visits 256 fillers: J's visit stays owed. J's 500 then waits with those ids moved before it, and v4 maps
    /// them back to C and the `after` members to E (its first turn visits 256 more fillers, so J's visit is still owed).
    /// The follow's and the drain's held turns are released one at a time, each timed inside the actor, until the drain
    /// is over; the heartbeat's longest wait covers them.
    static func takeOffDrain(members count: Int, held: Int, after: Int, waiters: Bool) async throws -> TakeOffDrainRun {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let conditions = FakeDeviceConditionsSource()
        let capacity = StoragePolicy().reserveFreeBytes + (64 << 20)
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
            random: SeededRandom(seed: 0x14),
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
        let cBytes = Data(repeating: 0x63, count: 16)
        let dBytes = Data(repeating: 0x64, count: 16)
        let eBytes = Data(repeating: 0x65, count: 16)
        func fillers(_ seed: UInt64) -> [ManifestEntry] {
            (0..<600).map { index in
                SyncBench.entry(String(format: "f%05d", index), GeneratedPayload.bytes(seed: seed + UInt64(index), offset: 0, length: 16), policy: .onDemand)
            }
        }
        // Member `index` on `held`'s content for the first `held` members, on `after`'s for the next `after`, else C's.
        func members(held heldBytes: Data, after afterBytes: Data) -> [ManifestEntry] {
            (0..<count).map { index in
                let bytes = index < held ? heldBytes : (index < held + after ? afterBytes : cBytes)
                return SyncBench.entry(String(format: "s%05d", index), bytes, policy: .onDemand)
            }
        }
        let onC = members(held: cBytes, after: cBytes)
        let j = onC[0].transferID
        let fillers2 = fillers(0x32_000)
        await source.scriptManifest([.fetched(SyncBench.manifestData(fillers2 + onC), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the members' sync did not complete")
        }
        await source.script(j, [.hold, .fail(.transient(.serverError(httpStatus: 500), retryAfter: nil))])
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        if waiters {
            for entry in onC {
                let id = entry.identifier
                callers.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
            }
        } else {
            guard case .success = await engine.registerGroup(onC.map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("the members' group was refused")
            }
        }
        let interests = waiters ? count : 1
        var spins = 0
        while !Task.isCancelled {
            let now = await SyncBench.userHolding(engine, j)
            if now.ids == count, now.interests == interests, await SyncBench.isRunning(engine, j) {
                break
            }
            spins += 1
            if spins > 5_000_000 {
                throw SyncBenchError.incomplete("setup: J never held every member: \(now)")
            }
            await Task.yield()
        }
        for filler in fillers2 {
            await source.script(filler.transferID, [.hold])
        }
        guard case .success = await engine.registerGroup(fillers2.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the fillers' group was refused")
        }
        while !Task.isCancelled, await SyncBench.jobCount(engine) < fillers2.count + 1 {
            await Task.yield()
        }
        // v3 moves every filler and the held members; the follow's first turn visits 256 fillers, and v4's first turn 256
        // more, so J's visit is still owed after v4's apply.
        let fillers3 = fillers(0x42_000)
        await source.scriptManifest([.fetched(SyncBench.manifestData(fillers3 + members(held: dBytes, after: cBytes)), etag: ETag(rawValue: "\"v3\""))])
        await engine.holdFollowFollowUps()
        let sync3 = Task { await engine.sync(.force) }
        while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
            await Task.yield()
        }
        var run = TakeOffDrainRun()
        await source.release(j, with: .progress(received: 0, expected: nil))
        while !Task.isCancelled, !(await SyncBench.verdictWaits(engine, j)) {
            await Task.yield()
        }
        run.movedBefore = await SyncBench.movedBefore(engine, j)
        // v4 maps the held members back to C and the `after` ones to E, while the follow still owes J's visit. It goes
        // through the engine's apply path: v3's run is still in flight, its follow held, and a forced sync would join it.
        let onE = members(held: cBytes, after: eBytes)
        let v4 = try ValidatedManifest(entries: fillers3 + onE, digest: ContentHash.sha256(of: Data("v4-take-off-\(count)-\(held)-\(after)".utf8)))
        let applied = await engine.applyAndFollow(v4, etag: nil, eviction: nil)
        guard case .success = applied else {
            throw SyncBenchError.incomplete("v4 was not applied: \(applied)")
        }
        guard await SyncBench.followOwedNow(engine), await SyncBench.verdictWaits(engine, j) else {
            throw SyncBenchError.incomplete("v4's follow is not owed, or J's verdict no longer waits: \(await SyncBench.followShape(engine))")
        }
        let heldIDs = Set(onC.prefix(held).map(\.identifier))
        let e = onE.dropFirst(held).first?.transferID
        await SyncBench.holdTurns(engine)
        await SyncBench.raiseOwnedTaskPriority(engine)
        var turns: [Double] = []
        var waiting = true
        run.wait = try await SyncBench.longestWait(on: engine) {
            while !Task.isCancelled, await SyncBench.verdictOrBarrier(engine, j) {
                guard let turn = await SyncBench.releaseOneHeldFollowOrDrainTurn(engine) else {
                    await Task.yield()
                    continue
                }
                turns.append(turn)
                if waiting, !(await SyncBench.verdictWaits(engine, j)) {
                    waiting = false
                    run.verdictTurn = turn
                    let state = await SyncBench.takeOffState(engine, j, held: heldIDs, e: e)
                    run.owedAtVerdict = state.owed
                    run.madeAtVerdict = state.made
                    run.movingAtVerdict = state.moving
                    run.movedAtVerdict = state.onE
                }
            }
        }
        run.turns = turns
        run.given = !waiting
        let end = await SyncBench.takeOffState(engine, j, held: heldIDs, e: e)
        run.movedAfter = end.onE
        run.rerouted = await SyncBench.inbound(engine, j).ids
        await SyncBench.releaseHeldTurns(engine)
        await engine.shutdown()
        _ = await sync3.value
        for caller in callers {
            _ = await caller.value
        }
        return run
    }

    /// After a take-off turn: the distinct ids the waiting batches owe, the `held` ids J holds again, whether a visit's
    /// rest waits, and the ids E's job holds.
    static func takeOffState(_ engine: isolated SyncEngine, _ j: TransferID, held: Set<AssetID>, e: TransferID?) -> (owed: Int, made: Int, moving: Bool, onE: Int) {
        var owed: Set<AssetID> = []
        for event in engine.state.eventsAfterFollow {
            if case .reroutes(let batch) = event {
                owed.formUnion(batch.items.elements.map(\.asset))
            }
        }
        let made = engine.state.jobs[j]?.assets.intersection(held).count ?? 0
        return (owed.count, made, engine.state.followMoving != nil, e.flatMap { engine.state.jobs[$0]?.assets.count } ?? 0)
    }
}
