import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

/// The C2 pins of the bounded re-routes (Stage 3 close-out cycle 21, ruling S3-R26 item 1; `integrate-rr21.md`'s pins):
/// a commit whose re-routes do not fit its turn owes them as one batch, which the drain makes at most a drain turn's ids
/// (512) a turn. Each held turn is timed inside the actor (`releaseOneHeldFollowOrDrainTurn`), and the heartbeat covers
/// the commit and the drain's turns; each figure is printed with the host's load averages (S3-R23).
extension ZTronAssetKitBenchmarks.SyncBenchmarks {
    /// C2 of a commit whose 10,000 moved-away ids v4 maps each to a content of its own (`SyncBench.commitReroute`,
    /// `.divergent`): the commit owes them as one batch and re-routes none in its own turn, and the drain makes them over
    /// 20 turns of at most 512 ids, each creating the jobs of its ids' contents. The best of three of the heartbeat and
    /// of the longest held turn against C2, after a warm-up.
    @Test("R-SYN-11: a commit that re-routes 10,000 ids each to a content of its own owes them, and the drain makes them holding the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func commitRerouteDivergentTurns() async throws {
        _ = try await SyncBench.commitReroute(count: 1_000, shape: .divergent)
        var runs: [CommitRerouteBenchRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.commitReroute(count: 10_000, shape: .divergent))
        }
        for run in runs {
            #expect(run.committed && run.served && run.madeAtCommit == 0 && run.batchesAtCommit == 1 && run.owedAtCommit == 10_000, "setup: the commit bound K, answered its waiter, re-routed none of the 10,000 ids and owed them as one batch: \(run)")
            #expect(run.made.count == 20 && run.made.allSatisfy { $0 <= 512 } && run.rerouted == 10_000 && run.violations.isEmpty, "setup: the drain made the batch in 20 turns of at most 512 ids, each id onto its content's job: \(run)")
        }
        let waits = runs.map(\.wait)
        let turns = runs.map(\.longestTurn)
        let commits = runs.map(\.commitTurn)
        print("R-SYN-11 commitRerouteDivergentTurns at 10,000: heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms; longest held turn \(turns) ms, best \(turns.min() ?? .infinity) ms; the commit's own turn \(commits) ms (budget \(Self.c2Budget) ms best); runs \(runs)")
        #expect((waits.min() ?? .infinity) <= Self.c2Budget, "the heartbeat: \(waits)")
        #expect((turns.min() ?? .infinity) <= Self.c2Budget, "the held turns: \(turns)")
    }
}

/// The groupings of `SyncBench.commitReroute`: where v4 maps the moved ids, and who wants them.
enum CommitRerouteShape: String, Sendable, CaseIterable {
    /// Every moved id to a content of its own, one prefetch group of every id (`commitRerouteDivergentTurns`).
    case divergent
}

/// What `SyncBench.commitReroute` measured and read.
struct CommitRerouteBenchRun: CustomStringConvertible {
    /// The heartbeat's longest wait over the commit, and over the held turns after it.
    var commit = 0.0
    var drain = 0.0
    /// The commit's own turn, timed inside the actor.
    var commitTurn = 0.0
    /// Each held turn after the commit, timed inside the actor.
    var turns: [Double] = []
    /// The distinct ids each held turn re-routed, for the turns that re-routed any.
    var made: [Int] = []
    /// The moved ids the commit's own turn re-routed, the distinct ids owed and the batches after it.
    var madeAtCommit = 0
    var owedAtCommit = 0
    var batchesAtCommit = 0
    /// The moved ids on their v4 contents' jobs at the end.
    var rerouted = 0
    /// Whether H's job was gone after the commit, and K's user waiter was answered with a location.
    var committed = false
    var served = false
    /// The invariant violations after the commit and at the end.
    var violations: [String] = []
    /// The host's load averages before and after the run.
    var load = ""

    /// The heartbeat's longest wait over the whole window.
    var wait: Double {
        max(self.commit, self.drain)
    }

    /// The longest held turn, timed inside the actor.
    var longestTurn: Double {
        self.turns.max() ?? 0
    }

    var description: String {
        "heartbeat commit \(String(format: "%.2f", self.commit)) ms, drain \(String(format: "%.2f", self.drain)) ms; commit turn \(String(format: "%.2f", self.commitTurn)) ms; \(self.turns.count) held turns, longest \(String(format: "%.2f", self.longestTurn)) ms; made at the commit \(self.madeAtCommit), owed \(self.owedAtCommit) in \(self.batchesAtCommit) batches; made per turn \(self.made); re-routed \(self.rerouted); committed \(self.committed), served \(self.served); violations \(self.violations.prefix(3)); load \(self.load)"
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    /// A commit that re-routes `count` moved-away ids (Stage 3 close-out cycle 21, ruling S3-R26 item 1;
    /// `integrate-rr21.md`'s pins at site 1): K and `count` members share H's 16 bytes, one job, downloading (held),
    /// wanted as `shape` says, K by a user waiter too. H's download is released with the bulk executor holding, so its
    /// publication waits at its first store unit; v4 maps the members away (`shape`) and is applied, its follow ended.
    /// Then the follow's and the drain's turns are held, the unit is released, and the heartbeat times the turns until
    /// H's job is gone, while the engine's seam times the commit's own turn inside the actor. Then the held turns are
    /// released one at a time, each timed inside the actor, under the heartbeat, until the drain is over.
    static func commitReroute(count: Int, shape: CommitRerouteShape) async throws -> CommitRerouteBenchRun {
        var run = CommitRerouteBenchRun()
        let loadBefore = SyncBench.loadAverages()
        let held = try await SyncBench.heldPublicationBench()
        let engine = held.bench.engine
        let source = held.bench.source
        let bulk = held.bulk
        let hBytes = Data(repeating: 0x68, count: 16)
        let kept = SyncBench.entry("k", hBytes, policy: .onDemand)
        let members = SyncBench.sharing(count, hBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData([kept] + members), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the second sync did not complete")
        }
        try await held.bench.store.flush(.ordered)
        let holder = kept.transferID
        await source.script(holder, [.hold, .stage(hBytes)])
        let waiter = Task { await engine.awaitAsset(kept.identifier, lane: .userInitiated) }
        switch shape {
        case .divergent:
            guard case .success = await engine.registerGroup(([kept] + members).map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("the prefetch group was refused")
            }
        }
        var spins = 0
        while !Task.isCancelled {
            let now = await SyncBench.userHolding(engine, holder)
            if now.ids == count + 1, now.interests == 2, await SyncBench.isRunning(engine, holder) {
                break
            }
            spins += 1
            if spins > 5_000_000 {
                throw SyncBenchError.incomplete("setup: H never held every id: \(now)")
            }
            await Task.yield()
        }
        await bulk.setHolding(true)
        await source.release(holder, with: .progress(received: 0, expected: nil))
        await bulk.waitForHeldUnits(atLeast: 1)
        guard let unit = await bulk.heldUnits.first else {
            throw SyncBenchError.incomplete("H's publication is not held at the store")
        }
        let releaser = Task {
            while !Task.isCancelled {
                await bulk.waitForHeldUnits(atLeast: 2)
                for other in await bulk.heldUnits where other != unit {
                    await bulk.release(other)
                }
            }
        }
        let moved: [ManifestEntry]
        switch shape {
        case .divergent:
            moved = (0..<count).map { index in
                SyncBench.entry(String(format: "s%05d", index), GeneratedPayload.bytes(seed: 0x52_000 + UInt64(index), offset: 0, length: 16), policy: .onDemand)
            }
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData([kept] + moved), etag: ETag(rawValue: "\"v4\""))])
        // The sync ends with the engine (its run may wait for the re-routed downloads); only its apply matters here.
        _ = Task { await engine.sync(.force) }
        spins = 0
        while !Task.isCancelled, !(await SyncBench.appliedAndFollowed(engine, etag: "\"v4\"")) {
            spins += 1
            if spins > 50_000_000 {
                throw SyncBenchError.incomplete("setup: v4 was never applied and followed: \(await SyncBench.followShape(engine))")
            }
            await Task.yield()
        }
        releaser.cancel()
        _ = await releaser.value
        await SyncBench.holdTurns(engine)
        await SyncBench.raiseOwnedTaskPriority(engine)
        let clock = CommitTurnClock()
        await SyncBench.markCommitTurns(engine) { ended in clock.mark(ended) }
        run.commit = try await SyncBench.longestWait(on: engine) {
            await bulk.setHolding(false)
            await bulk.releaseAll()
            while !Task.isCancelled, await SyncBench.jobExists(engine, holder) {
                await bulk.releaseAll()
                await Task.yield()
            }
        }
        run.commitTurn = clock.longest
        await SyncBench.markCommitTurns(engine, nil)
        run.committed = !(await SyncBench.jobExists(engine, holder))
        let atCommit = await SyncBench.rerouteState(engine, moved)
        run.madeAtCommit = atCommit.made
        run.owedAtCommit = atCommit.owed
        run.batchesAtCommit = atCommit.batches
        run.violations += atCommit.violations
        var owed = atCommit.owed
        var made: [Int] = []
        run.drain = try await SyncBench.longestWait(on: engine) {
            run.turns = try await SyncBench.releaseTurnsUntilSettled(engine) { _ in
                let now = await SyncBench.owedReroutes(engine)
                if owed - now > 0 {
                    made.append(owed - now)
                }
                owed = now
            }
        }
        run.made = made
        let end = await SyncBench.rerouteState(engine, moved)
        run.rerouted = end.made
        run.violations += end.violations
        await engine.shutdown()
        if case .success = await waiter.value {
            run.served = true
        }
        run.load = "\(loadBefore) -> \(SyncBench.loadAverages())"
        return run
    }

    /// The distinct ids every waiting batch of re-routes owes.
    static func owedReroutes(_ engine: isolated SyncEngine) -> Int {
        var owed: Set<AssetID> = []
        for event in engine.state.eventsAfterFollow {
            if case .reroutes(let batch) = event {
                owed.formUnion(batch.items.elements.lazy.map(\.asset))
            }
        }
        return owed.count
    }

    /// The `moved` entries whose content's job holds their id, the distinct ids owed, the waiting batches of re-routes,
    /// and the invariant violations.
    static func rerouteState(_ engine: isolated SyncEngine, _ moved: [ManifestEntry]) -> (made: Int, owed: Int, batches: Int, violations: [String]) {
        let made = moved.count { engine.state.jobs[$0.transferID]?.assets.contains($0.identifier) ?? false }
        let batches = engine.state.eventsAfterFollow.count { if case .reroutes = $0 { true } else { false } }
        return (made, SyncBench.owedReroutes(engine), batches, engine.invariantViolations())
    }
}
