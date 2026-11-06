import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// f2-R1 (Stage 3 close-out cycle 23, ruling S3-R28 item 2): A-T-SD's committed shape at `9aa337c`
/// (`shutdownClearsTheJoinsBehindAVerdict(.followVisitedFirst)`: seed 2_022_781, `.timeout`, `.users`, 10 members,
/// `holdRetry: false`), with O's unheld retry forced to serve before the shutdown, then DBT:781 and DBT:786 asserted
/// unchanged. Red by construction. Records O's state and request count after the set-up and after v4. Never committed.
extension EngineFollowBarrierTests {
    static func probeC23Describe(_ result: Result<AssetLocation, AssetError>) -> String {
        switch result {
        case .success(let location):
            return "ok(\(location.byteSize) B)"
        case .failure(let error):
            return "failed(\(error))"
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C23-F2R1", .timeLimit(.minutes(5)))
    func probeC23F2R1() async throws {
        for round in 1...2 {
            let count = 10
            let b = try await self.deferBucketSetUp(.followVisitedFirst, seed: 2_022_781, ending: .timeout, wanters: .users, members: count)
            let engine = b.s.engine
            let oT = b.o.transferID
            let afterSetUp = await engine.readForTests { e in e.state.jobs[oT].map { "\($0.state) interests \($0.interests.count)" } ?? "gone" }
            let requestsAfterSetUp = await b.s.harness.source.starts.filter { $0.id == oT }.count
            try await self.deferBucketApplyV4(b, .followVisitedFirst)
            let afterV4 = await engine.readForTests { e in e.state.jobs[oT].map { "\($0.state) interests \($0.interests.count)" } ?? "gone" }
            let requestsAfterV4 = await b.s.harness.source.starts.filter { $0.id == oT }.count
            // The serve forced first (S3-R28 item 2, f2-R1).
            await EngineRegressionCycle6Tests.driving([b.s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[oT] == nil }
            }
            await engine.shutdown()
            let oWaiter = try #require(b.oWaiter)
            let oAnswer = await oWaiter.value
            var answers: [Result<AssetLocation, AssetError>] = []
            for caller in b.callers {
                answers.append(await caller.value)
            }
            let requestsAtEnd = await b.s.harness.source.starts.filter { $0.id == oT }.count
            print("PROBE-C23-F2R1 round \(round): after the set-up O \(afterSetUp), O requests \(requestsAfterSetUp); after v4 O \(afterV4), O requests \(requestsAfterV4); at the end O requests \(requestsAtEnd); zz-o \(Self.probeC23Describe(oAnswer)); members \(Set(answers.map(Self.probeC23Describe))) x\(answers.count)")
            // DBT:781 and DBT:786, unchanged.
            #expect(oAnswer == .failure(.shutDown), "zz-o's waiter is answered shutDown")
            #expect(answers.allSatisfy { $0 == .failure(.shutDown) }, "every member's waiter is answered shutDown: \(answers)")
            await b.probe.stop()
        }
    }
}
