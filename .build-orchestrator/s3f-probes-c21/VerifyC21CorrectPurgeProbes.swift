import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetSync

/// Scratch release probes (s3f close-out verification, cycle 21, correctness lens). Never committed.
///
/// PROBE-C21C-PURGE-QUEUED: a purge's own engine turn (`performPurge`: `dropBindings`, `settleRun`, `withdrawPurged`,
/// whose walk sorts every job and removes every non-user interest in a purged id in that one turn) under SPEC §6's
/// 10,000 prefetch members: `SyncBench.handleReleaseWait`'s shape (three run and hold, the others wait in the queue),
/// with `purge(.all)` in place of the release. No BenchSync case times this turn (the only purge case,
/// `purgeWhileOwedTurns`, has no job left by its purge). Variants: a member per content (10,000 jobs), and every
/// member sharing one content (one job of 10,000 ids, one interest).
@Suite("VerifyC21CorrectPurge", .serialized)
struct VerifyC21CorrectPurge {
    static func load() -> String {
        var loads = [Double](repeating: 0, count: 3)
        let n = getloadavg(&loads, 3)
        return n == 3 ? String(format: "{ %.2f %.2f %.2f }", loads[0], loads[1], loads[2]) : "?"
    }

    static func firstJobIDs(_ engine: isolated SyncEngine) -> Int {
        engine.state.jobs.values.first?.assets.count ?? 0
    }

    static func jobsAndIDs(_ engine: isolated SyncEngine) -> (jobs: Int, ids: Int) {
        (engine.state.jobs.count, engine.state.jobs.values.reduce(0) { $0 + $1.assets.count })
    }

    struct Run: CustomStringConvertible {
        var wait = 0.0
        var jobsBefore = 0
        var idsBefore = 0
        var jobsAfter = -1
        var violations: [String] = []
        var outcome = ""

        var description: String {
            "longest actor wait \(String(format: "%.2f", self.wait)) ms; jobs \(self.jobsBefore) (ids \(self.idsBefore)) -> \(self.jobsAfter); purge \(self.outcome); violations \(self.violations.prefix(2))"
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func purgeWait(members count: Int, shared: Bool) async throws -> Run {
        let bench = try await SyncBench.scaleBench(members: count, room: nil)
        let engine = bench.engine
        var ids = bench.entries.map(\.identifier)
        if shared {
            // One content for every member: a second manifest maps them all to the first member's bytes.
            let bytes = GeneratedPayload.bytes(seed: 0x11_000, offset: 0, length: bench.size)
            let entries = SyncBench.sharing(count, bytes)
            ids = entries.map(\.identifier)
            await bench.source.scriptManifest([.fetched(SyncBench.manifestData(entries), etag: ETag(rawValue: "\"v2\""))])
            guard await engine.sync(.force).isComplete else {
                throw SyncBenchError.incomplete("the shared manifest's sync did not complete")
            }
        }
        guard case .success = await engine.registerGroup(ids, lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        let expectedJobs = shared ? 1 : count
        while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: expectedJobs)) {
            await Task.yield()
        }
        if shared {
            while !Task.isCancelled, await Self.firstJobIDs(engine) < count {
                await Task.yield()
            }
        }
        await engine.waitForAllHandles()
        var run = Run()
        (run.jobsBefore, run.idsBefore) = await Self.jobsAndIDs(engine)
        var outcome = ""
        run.wait = try await SyncBench.longestWait(on: engine) {
            let result = await engine.purge(.all)
            outcome = "\(result)".prefix(60).description
            while !Task.isCancelled, !(await SyncBench.noJobs(engine)) {
                await Task.yield()
            }
        }
        run.outcome = outcome
        run.jobsAfter = await Self.jobsAndIDs(engine).jobs
        run.violations = await engine.invariantViolations()
        await engine.shutdown()
        return run
    }

    /// The purge turn's synchronous parts (`performPurge` before its first await), each timed inside the actor.
    @available(macOS 15.0, iOS 18.0, *)
    static func purgeParts(_ engine: isolated SyncEngine) -> (drop: Double, settle: Double, withdraw: Double) {
        let clock = ContinuousClock()
        let t0 = clock.now
        engine.state.purgeEpoch += 1
        engine.dropBindings()
        let t1 = clock.now
        engine.settleRun(.cancelled)
        let t2 = clock.now
        engine.withdrawPurged(.all)
        let t3 = clock.now
        return (SyncBench.milliseconds(t1 - t0), SyncBench.milliseconds(t2 - t1), SyncBench.milliseconds(t3 - t2))
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func purgePartsRun(members count: Int, shared: Bool) async throws -> (drop: Double, settle: Double, withdraw: Double, jobsAfter: Int) {
        let bench = try await SyncBench.scaleBench(members: count, room: nil)
        let engine = bench.engine
        var ids = bench.entries.map(\.identifier)
        if shared {
            let bytes = GeneratedPayload.bytes(seed: 0x11_000, offset: 0, length: bench.size)
            let entries = SyncBench.sharing(count, bytes)
            ids = entries.map(\.identifier)
            await bench.source.scriptManifest([.fetched(SyncBench.manifestData(entries), etag: ETag(rawValue: "\"v2\""))])
            guard await engine.sync(.force).isComplete else {
                throw SyncBenchError.incomplete("the shared manifest's sync did not complete")
            }
        }
        guard case .success = await engine.registerGroup(ids, lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        let expectedJobs = shared ? 1 : count
        while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: expectedJobs)) {
            await Task.yield()
        }
        if shared {
            while !Task.isCancelled, await Self.firstJobIDs(engine) < count {
                await Task.yield()
            }
        }
        await engine.waitForAllHandles()
        let parts = await Self.purgeParts(engine)
        let after = await Self.jobsAndIDs(engine).jobs
        await engine.shutdown()
        return (parts.drop, parts.settle, parts.withdraw, after)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C21C-PURGE-PARTS", .timeLimit(.minutes(10)), arguments: [false, true])
    func purgePartsTurns(_ shared: Bool) async throws {
        _ = try await Self.purgePartsRun(members: 1_000, shared: shared)
        var withdraws: [Double] = []
        for index in 0..<3 {
            let before = Self.load()
            let run = try await Self.purgePartsRun(members: 10_000, shared: shared)
            print("PROBE-C21C-PURGE-PARTS shared=\(shared) 10,000 run \(index): dropBindings \(String(format: "%.2f", run.drop)) ms, settleRun \(String(format: "%.2f", run.settle)) ms, withdrawPurged \(String(format: "%.2f", run.withdraw)) ms; jobs after \(run.jobsAfter); load \(before) -> \(Self.load())")
            withdraws.append(run.withdraw)
        }
        print("PROBE-C21C-PURGE-PARTS shared=\(shared): withdrawPurged \(withdraws) ms, best \(withdraws.min() ?? -1) ms")
        #expect((withdraws.min() ?? .infinity) <= 10.0, "PROBE-C21C-PURGE-PARTS shared=\(shared): withdrawPurged alone at most C2's 10 ms: \(withdraws)")
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C21C-PURGE-QUEUED", .timeLimit(.minutes(10)), arguments: [false, true])
    func purgeQueuedTurns(_ shared: Bool) async throws {
        let warm = try await Self.purgeWait(members: 1_000, shared: shared)
        print("PROBE-C21C-PURGE-QUEUED shared=\(shared) warm-up 1,000: \(warm) load \(Self.load())")
        var runs: [Run] = []
        for index in 0..<3 {
            let before = Self.load()
            let run = try await Self.purgeWait(members: 10_000, shared: shared)
            print("PROBE-C21C-PURGE-QUEUED shared=\(shared) 10,000 run \(index): \(run) load \(before) -> \(Self.load())")
            runs.append(run)
        }
        let waits = runs.map(\.wait)
        print("PROBE-C21C-PURGE-QUEUED shared=\(shared): waits \(waits) ms, best \(waits.min() ?? -1) ms (c2Budget 10 ms)")
        for run in runs {
            #expect(run.violations.isEmpty, "invariants: \(run.violations.prefix(3))")
            #expect(run.jobsBefore == (shared ? 1 : 10_000) && run.idsBefore == 10_000 && run.jobsAfter == 0, "setup: \(run)")
        }
        #expect((waits.min() ?? .infinity) <= 10.0, "PROBE-C21C-PURGE-QUEUED shared=\(shared): best of 3 at most C2's 10 ms: \(waits)")
    }
}
