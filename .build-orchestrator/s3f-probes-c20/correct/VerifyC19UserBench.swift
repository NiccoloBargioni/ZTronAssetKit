import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

/// Scratch release probe (s3f close-out verification, cycle 19, correctness lens). Never committed.
///
/// PROBE-C19C-USER-SHARED-C2: `BenchSync.sharedApplyTurns`' convergence shape with user-initiated waiters in place of
/// the prefetch group: `count` ids share H's 16 bytes and each has a user waiter of its own (one interest token per
/// id), so H's job holds `count` interests; O, 16 bytes for a user request, downloads (held). v3 maps every id to O's
/// content. `.supersede`: every id of H moves (H superseded, its interests dropped in place). `.keep`: one more id of
/// H's content, `keep`, with its own waiter, stays on H, so H is not superseded and each emptied interest is removed
/// through `removeInterest`. The heartbeat's longest wait over v3's sync and its whole follow, best of three.
@Suite("VerifyC19UserBench", .serialized)
struct VerifyC19UserBench {
    enum Shape: String, CaseIterable, Sendable {
        case supersede
        case keep
    }

    struct Run: CustomStringConvertible {
        var wait: Double = 0
        var before = 0
        var interestsBefore = 0
        var onO = 0
        var onH = 0
        var owedAfter = false

        var description: String {
            "wait \(self.wait) ms; H held \(self.before) ids, \(self.interestsBefore) interests; after: O \(self.onO) ids, H \(self.onH) ids, owed \(self.owedAfter)"
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func counts(_ engine: isolated SyncEngine, _ transfer: TransferID) -> (ids: Int, interests: Int, waiters: Int) {
        (engine.state.jobs[transfer]?.assets.count ?? 0, engine.state.jobs[transfer]?.interests.count ?? 0, engine.state.waiters.count)
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func owed(_ engine: isolated SyncEngine) -> Bool {
        engine.followOwed
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func run(count: Int, shape: Shape) async throws -> Run {
        let bench = try await SyncBench.followBench()
        let engine = bench.engine
        let source = bench.source
        let oBytes = Data(repeating: 0x6F, count: 16)
        let hBytes = Data(repeating: 0x68, count: 16)
        let o = SyncBench.entry("o", oBytes, policy: .onDemand)
        let keep = SyncBench.entry("keep", hBytes, policy: .onDemand)
        let members = SyncBench.sharing(count, hBytes)
        let extra = shape == .keep ? [keep] : []
        await source.scriptManifest([.fetched(SyncBench.manifestData(members + [o] + extra), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the second sync did not complete")
        }
        try await bench.store.flush(.ordered)
        let holder = members[0].transferID
        await source.script(o.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        await source.script(holder, [.hold, .stage(hBytes)])
        let oWaiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        while !Task.isCancelled, !(await SyncBench.isRunning(engine, o.transferID)) {
            await Task.yield()
        }
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for entry in members + extra {
            callers.append(Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) })
        }
        let held = count + extra.count
        var spins = 0
        while !Task.isCancelled {
            let now = await VerifyC19UserBench.counts(engine, holder)
            if now.ids == held, now.interests == held, now.waiters == held + 1, await SyncBench.isRunning(engine, holder) {
                break
            }
            spins += 1
            if spins > 5_000_000 {
                throw SyncBenchError.incomplete("setup: H never held every waiter's id: \(now)")
            }
            await Task.yield()
        }
        var run = Run()
        let before = await VerifyC19UserBench.counts(engine, holder)
        run.before = before.ids
        run.interestsBefore = before.interests
        let v3 = SyncBench.sharing(count, oBytes) + [o] + extra
        await SyncBench.raiseOwnedTaskPriority(engine)
        run.wait = try await SyncBench.timedApply(bench, v3, tag: "v3-user-\(shape.rawValue)-\(count)")
        run.onO = await VerifyC19UserBench.counts(engine, o.transferID).ids
        run.onH = await VerifyC19UserBench.counts(engine, holder).ids
        run.owedAfter = await VerifyC19UserBench.owed(engine)
        await engine.shutdown()
        for caller in callers {
            _ = await caller.value
        }
        _ = await oWaiter.value
        return run
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func hold(_ engine: isolated SyncEngine) {
        engine.holdFollowFollowUps()
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func heldWaiting(_ engine: isolated SyncEngine) -> Bool {
        engine.state.followFollowUpWaiting
    }

    /// The same setup and v3, its follow's follow-ups held: the apply's own turns (up to the first held follow-up) under
    /// the heartbeat, then each held follow turn released and timed inside the actor, with the ids it moved off H.
    @available(macOS 15.0, iOS 18.0, *)
    static func turns(count: Int, shape: Shape) async throws -> (apply: Double, turns: [Double], moved: [Int]) {
        let bench = try await SyncBench.followBench()
        let engine = bench.engine
        let source = bench.source
        let oBytes = Data(repeating: 0x6F, count: 16)
        let hBytes = Data(repeating: 0x68, count: 16)
        let o = SyncBench.entry("o", oBytes, policy: .onDemand)
        let keep = SyncBench.entry("keep", hBytes, policy: .onDemand)
        let members = SyncBench.sharing(count, hBytes)
        let extra = shape == .keep ? [keep] : []
        await source.scriptManifest([.fetched(SyncBench.manifestData(members + [o] + extra), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the second sync did not complete")
        }
        try await bench.store.flush(.ordered)
        let holder = members[0].transferID
        await source.script(o.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        await source.script(holder, [.hold, .stage(hBytes)])
        let oWaiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        while !Task.isCancelled, !(await SyncBench.isRunning(engine, o.transferID)) {
            await Task.yield()
        }
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for entry in members + extra {
            callers.append(Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) })
        }
        let held = count + extra.count
        var spins = 0
        while !Task.isCancelled {
            let now = await VerifyC19UserBench.counts(engine, holder)
            if now.ids == held, now.interests == held, now.waiters == held + 1, await SyncBench.isRunning(engine, holder) {
                break
            }
            spins += 1
            if spins > 5_000_000 {
                throw SyncBenchError.incomplete("setup: H never held every waiter's id: \(now)")
            }
            await Task.yield()
        }
        let v3 = SyncBench.sharing(count, oBytes) + [o] + extra
        await source.scriptManifest([.fetched(SyncBench.manifestData(v3), etag: ETag(rawValue: "\"v3-turns-\(shape.rawValue)-\(count)\""))])
        await VerifyC19UserBench.hold(engine)
        await SyncBench.raiseOwnedTaskPriority(engine)
        var sync: Task<SyncOutcome, Never>?
        let apply = try await SyncBench.longestWait(on: engine) {
            sync = Task { await engine.sync(.force) }
            var spins = 0
            while !Task.isCancelled, !(await VerifyC19UserBench.heldWaiting(engine)) {
                spins += 1
                if spins > 5_000_000 {
                    throw SyncBenchError.incomplete("v3's follow never held a follow-up")
                }
                await Task.yield()
            }
        }
        var turns: [Double] = []
        var moved: [Int] = []
        var onH = await VerifyC19UserBench.counts(engine, holder).ids
        spins = 0
        while !Task.isCancelled, !(await SyncBench.followDrained(engine)) {
            if let turn = await SyncBench.releaseOneHeldTurn(engine) {
                turns.append(turn)
                let now = await VerifyC19UserBench.counts(engine, holder).ids
                moved.append(onH - now)
                onH = now
            } else {
                spins += 1
                if spins > 5_000_000 {
                    throw SyncBenchError.incomplete("the follow never drained")
                }
                await Task.yield()
            }
        }
        await engine.releaseFollowFollowUps()
        _ = await sync?.value
        await engine.shutdown()
        for caller in callers {
            _ = await caller.value
        }
        _ = await oWaiter.value
        return (apply, turns, moved)
    }

    @Test("PROBE-C19C-USER-SHARED-TURNS", .timeLimit(.minutes(10)), arguments: Shape.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func userSharedTurns(_ shape: Shape) async throws {
        _ = try await VerifyC19UserBench.turns(count: 1_000, shape: shape)
        let run = try await VerifyC19UserBench.turns(count: 10_000, shape: shape)
        let rounded = run.turns.map { ($0 * 100).rounded() / 100 }
        print("PROBE-C19C-USER-SHARED-TURNS \(shape) 10,000 user waiters: apply window \(run.apply) ms; \(run.turns.count) follow turns, longest \(run.turns.max() ?? 0) ms; per turn ms \(rounded); ids moved off H per turn \(run.moved)")
        #expect((run.turns.max() ?? 0) <= 10.0 && run.apply <= 10.0, "PROBE-C19C-USER-SHARED-TURNS: each follow turn and the apply's window at most C2's 10 ms: \(rounded), apply \(run.apply)")
    }

    @Test("PROBE-C19C-USER-SHARED-C2", .timeLimit(.minutes(10)), arguments: Shape.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func userShared(_ shape: Shape) async throws {
        let warm = try await VerifyC19UserBench.run(count: 1_000, shape: shape)
        print("PROBE-C19C-USER-SHARED-C2 warm-up \(shape) 1,000: \(warm)")
        var runs: [Run] = []
        for _ in 0..<3 {
            runs.append(try await VerifyC19UserBench.run(count: 10_000, shape: shape))
        }
        let waits = runs.map(\.wait)
        print("PROBE-C19C-USER-SHARED-C2 \(shape) 10,000 user waiters: longest actor wait \(waits) ms, best \(waits.min() ?? -1); runs \(runs)")
        for run in runs {
            #expect(run.before == 10_000 + (shape == .keep ? 1 : 0) && run.interestsBefore == run.before, "setup: H holds every waiter's id, one interest each: \(run)")
            #expect(run.onO == 10_001 && !run.owedAfter, "every id moved onto O's job: \(run)")
        }
        #expect((waits.min() ?? .infinity) <= 10.0, "PROBE-C19C-USER-SHARED-C2: the apply's follow holds the actor at most C2's 10 ms per turn: \(waits)")
    }
}

