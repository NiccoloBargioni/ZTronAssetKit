import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

/// PROBE-C21-HOLDERS (Stage 3 close-out cycle 21, a scratch probe in `.build-s3f/c21/apm`, not committed): item B's
/// residual 5 ("An id with many holders moves whole in one turn", under "Step 4"), measured at the close. One id of H's
/// content is held by 10,000 interests, a user waiter each or a one-member prefetch group each; O, 16 bytes for a user
/// request, downloads, held. v3 maps the id to O's content, so H's visit moves the one id with every holder (`move`'s
/// sort of its 10,000 (id, holder) pairs). The heartbeat times the apply's sync and its whole follow, as
/// `partialMoveTurns` does, best of three after a warm-up at 1,000.
extension ProbeC21APM {
    /// One run of `holders(count:users:)`.
    struct HoldersRun: CustomStringConvertible {
        var wait = 0.0
        var heldBefore = ""
        var onO = ""
        var onH = ""
        var load = ""

        var description: String {
            "wait \(String(format: "%.3f", self.wait)) ms; H before \(self.heldBefore); O after \(self.onO); H after \(self.onH); load \(self.load)"
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func holders(count: Int, users: Bool) async throws -> HoldersRun {
        var run = HoldersRun()
        let loadBefore = SyncBench.loadAverages()
        let bench = try await SyncBench.followBench()
        let engine = bench.engine
        let source = bench.source
        let oBytes = Data(repeating: 0x6F, count: 16)
        let hBytes = Data(repeating: 0x68, count: 16)
        let o = SyncBench.entry("o", oBytes, policy: .onDemand)
        let m = SyncBench.entry("m", hBytes, policy: .onDemand)
        await source.scriptManifest([.fetched(SyncBench.manifestData([m, o]), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the second sync did not complete")
        }
        try await bench.store.flush(.ordered)
        let holder = m.transferID
        await source.script(o.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        await source.script(holder, [.hold, .stage(hBytes)])
        let oWaiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        while !Task.isCancelled, !(await SyncBench.isRunning(engine, o.transferID)) {
            await Task.yield()
        }
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for _ in 0..<count {
            if users {
                callers.append(Task { await engine.awaitAsset(m.identifier, lane: .userInitiated) })
            } else {
                guard case .success = await engine.registerGroup([m.identifier], lane: .prefetch) else {
                    throw SyncBenchError.incomplete("a one-member group was refused")
                }
            }
        }
        var spins = 0
        while !Task.isCancelled {
            let now = await SyncBench.userHolding(engine, holder)
            if now.ids == 1, now.interests == count, await SyncBench.isRunning(engine, holder) {
                run.heldBefore = "\(now)"
                break
            }
            spins += 1
            if spins > 5_000_000 {
                throw SyncBenchError.incomplete("setup: H never held the id by every interest: \(now)")
            }
            await Task.yield()
        }
        let v3 = [SyncBench.entry("m", oBytes, policy: .onDemand), o]
        await SyncBench.raiseOwnedTaskPriority(engine)
        run.wait = try await SyncBench.timedApply(bench, v3, tag: "v3-holders-\(users)-\(count)")
        run.onO = "\(await SyncBench.userHolding(engine, o.transferID))"
        run.onH = "\(await SyncBench.userHolding(engine, holder))"
        await engine.shutdown()
        for caller in callers {
            _ = await caller.value
        }
        _ = await oWaiter.value
        run.load = "\(loadBefore) -> \(SyncBench.loadAverages())"
        return run
    }

    /// With `PROBE_C21_HOLDERS_SMOKE` set, one run at 100 holders checks the setup and nothing is timed.
    @Test("PROBE-C21-HOLDERS: one id held by 10,000 interests moves in the follow", .timeLimit(.minutes(10)), arguments: [true, false])
    @available(macOS 15.0, iOS 18.0, *)
    func manyHoldersMoveTurns(_ users: Bool) async throws {
        let smoke = ProcessInfo.processInfo.environment["PROBE_C21_HOLDERS_SMOKE"] != nil
        let count = smoke ? 100 : 10_000
        if !smoke {
            _ = try await Self.holders(count: 1_000, users: users)
        }
        var runs: [HoldersRun] = []
        for _ in 0..<(smoke ? 1 : 3) {
            runs.append(try await Self.holders(count: count, users: users))
        }
        let waits = runs.map(\.wait)
        print("PROBE-C21-HOLDERS users=\(users) one id, \(count) holders: heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms (budget 10.0 ms best); runs \(runs)")
        for run in runs {
            #expect(run.onO.hasPrefix("(ids: 2, interests: \(count + 1),"), "users=\(users): O holds the id by every holder: \(run)")
            #expect(run.onH.hasPrefix("(ids: 0, interests: 0,"), "users=\(users): the id left H with every holder: \(run)")
        }
    }
}
