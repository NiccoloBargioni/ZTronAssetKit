import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

/// PROBE-C21-APM (Stage 3 close-out cycle 21, a scratch probe in `.build-s3f/c21/apm`, not committed): the C2 figure of
/// `answerPresentMembers`' rows at 10,000 present ids (ruling S3-R26 item 9; the inventory row item B's B11 changed).
/// No BenchSync case reaches the answer site with present ids, so the answer turn's own work, the binding (`bind`) and
/// `answerPresentMembers`, is timed alone inside the engine's actor, as `indexOwnCosts` times the index's, on a job of
/// 10,000 ids sharing one content whose download is held, in three groupings: one prefetch group (one row of 10,000
/// ids), 10,000 one-member prefetch groups and a user waiter per id (10,000 rows each).
@Suite("ProbeC21APM", .serialized)
struct ProbeC21APM {
    /// How the job's 10,000 ids are wanted.
    enum Shape: String, Sendable, CaseIterable {
        case group
        case groups
        case users
    }

    /// One run of `run(_:count:)`.
    struct Run: CustomStringConvertible {
        var turn = 0.0
        var interestsBefore = 0
        var heldBefore = 0
        var interestsAfter = -1
        var heldAfter = -1
        var waitersAnswered = 0
        var load = ""

        var description: String {
            "turn \(String(format: "%.3f", self.turn)) ms; interests \(self.interestsBefore) -> \(self.interestsAfter), ids \(self.heldBefore) -> \(self.heldAfter); waiters moved to the store \(self.waitersAnswered); load \(self.load)"
        }
    }

    static func holding(_ engine: isolated SyncEngine, _ transfer: TransferID) -> (ids: Int, interests: Int, running: Bool) {
        let job = engine.state.jobs[transfer]
        return (job?.assets.count ?? 0, job?.interests.count ?? 0, job?.active != nil)
    }

    static func fromStore(_ engine: isolated SyncEngine) -> Int {
        engine.state.waiters.values.filter(\.fromStore).count
    }

    /// The answer site's turn without its reads: the binding, then the rows, timed inside the actor.
    @available(macOS 15.0, iOS 18.0, *)
    static func answerTurn(_ engine: isolated SyncEngine, _ transfer: TransferID, _ present: Set<AssetID>) -> Double {
        let clock = ContinuousClock()
        let started = clock.now
        engine.bind(present, to: transfer, since: engine.state.ledgerForgets)
        engine.answerPresentMembers(of: transfer, present)
        return SyncBench.milliseconds(clock.now - started)
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func run(_ shape: Shape, count: Int) async throws -> Run {
        var run = Run()
        let loadBefore = SyncBench.loadAverages()
        let bench = try await SyncBench.followBench()
        let engine = bench.engine
        let source = bench.source
        let bytes = Data(repeating: 0x61, count: 16)
        let members = SyncBench.sharing(count, bytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData(members), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the second sync did not complete")
        }
        try await bench.store.flush(.ordered)
        let holder = members[0].transferID
        await source.script(holder, [.hold, .stage(bytes)])
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        switch shape {
        case .group:
            guard case .success = await engine.registerGroup(members.map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("the prefetch group was refused")
            }
        case .groups:
            for entry in members {
                guard case .success = await engine.registerGroup([entry.identifier], lane: .prefetch) else {
                    throw SyncBenchError.incomplete("a one-member group was refused")
                }
            }
        case .users:
            for entry in members {
                let id = entry.identifier
                callers.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
            }
        }
        let wanted = shape == .group ? 1 : count
        var spins = 0
        while !Task.isCancelled {
            let now = await Self.holding(engine, holder)
            if now.ids == count, now.interests == wanted, now.running {
                break
            }
            spins += 1
            if spins > 5_000_000 {
                throw SyncBenchError.incomplete("setup: the job never held every id: \(now)")
            }
            await Task.yield()
        }
        let before = await Self.holding(engine, holder)
        run.interestsBefore = before.interests
        run.heldBefore = before.ids
        run.turn = await Self.answerTurn(engine, holder, Set(members.map(\.identifier)))
        let after = await Self.holding(engine, holder)
        run.interestsAfter = after.interests
        run.heldAfter = after.ids
        run.waitersAnswered = await Self.fromStore(engine)
        await engine.shutdown()
        for caller in callers {
            _ = await caller.value
        }
        run.load = "\(loadBefore) -> \(SyncBench.loadAverages())"
        return run
    }

    @Test("PROBE-C21-APM: answerPresentMembers' turn at 10,000 present ids", .timeLimit(.minutes(10)), arguments: Shape.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func answerPresentMembersTurns(_ shape: Shape) async throws {
        _ = try await Self.run(shape, count: 1_000)
        var runs: [Run] = []
        for _ in 0..<3 {
            runs.append(try await Self.run(shape, count: 10_000))
        }
        let turns = runs.map(\.turn)
        print("PROBE-C21-APM \(shape) at 10,000: the answer turn (bind and answerPresentMembers) \(turns) ms, best \(turns.min() ?? .infinity) ms (budget 10.0 ms best); runs \(runs)")
        for run in runs {
            #expect(run.heldBefore == 10_000 && run.interestsAfter == 0 && run.heldAfter == 0, "\(shape): every id answered from the store: \(run)")
        }
    }
}
