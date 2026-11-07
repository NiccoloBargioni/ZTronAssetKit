import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch probes (s3f close-out verification, cycle 23, correctness lens, HEAD d88bdb1). Never committed.
///
/// PROBE-C23C-ATSD-PROGRESS: cycle 22's correct #3 (the flake in `shutdownClearsTheJoinsBehindAVerdict`) re-checked on
/// HEAD. The committed shape (seed 2_022_781, `.timeout`, `.users`, 10 members) is set up with `holdRetry` false (the
/// old shape) and true (03c4e59's fix). After v4, before the shutdown, the probe lets the engine make every step it can:
/// `hops` actor round trips with yields, then optionally `advances` moves of the manual clock by 60 s, each followed by
/// hops. It then reads O, shuts down and reads every answer. With `holdRetry` false and the clock moved, the old flake's
/// serve-first interleaving must be reachable (the probe's power); with `holdRetry` true no answer may be a success.
extension EngineFollowBarrierTests {
    static func c23Describe(_ result: Result<AssetLocation, AssetError>) -> String {
        switch result {
        case .success(let location):
            return "ok(\(location.byteSize) B)"
        case .failure(let error):
            return "failed(\(error))"
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func c23Progress(_ engine: SyncEngine, hops: Int) async {
        for _ in 0..<hops {
            await engine.readForTests { _ in }
            await Task.yield()
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    func c23ATSDRound(_ visit: LaneDropVisit, holdRetry: Bool, advances: Int, round: Int) async throws -> (served: Int, shutDown: Int, other: Int, line: String) {
        let count = 10
        let b = try await self.deferBucketSetUp(visit, seed: 2_022_781, ending: .timeout, wanters: .users, members: count, holdRetry: holdRetry)
        let engine = b.s.engine
        let oT = b.o.transferID
        try await self.deferBucketApplyV4(b, visit)
        let afterV4 = await engine.readForTests { e in e.state.jobs[oT].map { "\($0.state) interests \($0.interests.count)" } ?? "gone" }
        await Self.c23Progress(engine, hops: 300)
        for _ in 0..<advances {
            b.s.time.advance(by: 60)
            await Self.c23Progress(engine, hops: 40)
        }
        let beforeShutdown = await engine.readForTests { e in e.state.jobs[oT].map { "\($0.state) interests \($0.interests.count)" } ?? "gone" }
        let starts = await b.s.harness.source.starts.filter { $0.id == oT }.count
        await engine.shutdown()
        let oWaiter = try #require(b.oWaiter)
        var answers = [Self.c23Describe(await oWaiter.value)]
        for caller in b.callers {
            answers.append(Self.c23Describe(await caller.value))
        }
        let violations = await engine.invariantViolations()
        await b.probe.stop()
        let served = answers.filter { $0.hasPrefix("ok(") }.count
        let shutDown = answers.filter { $0 == "failed(shutDown)" }.count
        let line = "PROBE-C23C-ATSD-PROGRESS \(visit) holdRetry=\(holdRetry) advances=\(advances) round \(round): after v4 O \(afterV4); before the shutdown O \(beforeShutdown), O requests \(starts); answers \(Dictionary(answers.map { ($0, 1) }, uniquingKeysWith: +)); violations \(violations.prefix(2))"
        print(line)
        return (served, shutDown, answers.count - served - shutDown, line)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C23C-ATSD-PROGRESS", .timeLimit(.minutes(10)))
    func probeC23ATSDProgress() async throws {
        var powerServed = 0
        for round in 1...2 {
            let old = try await self.c23ATSDRound(.followVisitedFirst, holdRetry: false, advances: 20, round: round)
            powerServed += old.served
        }
        #expect(powerServed > 0, "the probe's power: with the old shape and the clock moved, the retry serves before the shutdown")
        for visit in LaneDropVisit.allCases {
            for advances in [0, 20] {
                for round in 1...5 {
                    let held = try await self.c23ATSDRound(visit, holdRetry: true, advances: advances, round: round)
                    #expect(held.served == 0 && held.shutDown == 11, "the fixed shape: every answer shutDown: \(held.line)")
                }
            }
        }
    }
}
