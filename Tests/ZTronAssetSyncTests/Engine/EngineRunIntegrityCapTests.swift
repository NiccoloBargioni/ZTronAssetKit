import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

extension EngineFailurePathTests {
    /// A run whose plan holds back a record failed at the integrity cap (`maxIntegrityAttempts` verifications failed, so
    /// the store keeps it `failed(.integrity)` until its entry changes) reports it as the run's integrity failure: the run
    /// ends `completeWithFailures`, never `.complete`, and writes no sync stamp, so the sync stays due (R-SYN-6, R-INT-3;
    /// `recordSkippedFailures`' integrity branch; Stage 3, S3-CONF-03: a mutant that drops that failure passed every
    /// other test).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run over an asset failed at the integrity cap ends completeWithFailures with an integrity failure for it", .timeLimit(.minutes(1)))
    func runReportsAssetFailedAtIntegrityCap() async throws {
        let harness = EngineHarness.make()
        let good = EngineFixture.bytes(4_302)
        let entry = EngineHarness.onDemand("corrupt", good)
        let wrong = EngineFixture.bytes(4_303)
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, Array(repeating: FakeTransferStep.stage(wrong), count: 6))
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let stampBefore = try await harness.view().stamp
        for _ in 0..<harness.configuration.storage.maxIntegrityAttempts + 2 {
            _ = await engine.awaitAsset("corrupt", lane: .userInitiated)
            await engine.awaitCondition { $0.state.jobs[entry.transferID] == nil }
            harness.time.advance(by: 700)
            await EngineFailurePathTests.settleDue(engine, time: harness.time)
        }
        guard case .failed(.integrity)? = try await harness.view().records["corrupt"]?.residency else {
            Issue.record("setup: expected the record failed until its entry changes")
            await engine.shutdown()
            return
        }
        let outcome = await engine.sync(.force)
        guard case .completeWithFailures(let report) = outcome else {
            Issue.record("a run over a failed asset ended \(outcome), not completeWithFailures")
            await engine.shutdown()
            return
        }
        #expect(report.failures.first { $0.id == "corrupt" }?.failureClass == .integrity)
        #expect(report.failures.first { $0.id == "corrupt" }?.error == .integrityFailure)
        #expect(report.failedCount == 1, "\(report.failures)")
        #expect(try await harness.view().stamp == stampBefore, "a run with a failed asset writes no sync stamp")
        await engine.shutdown()
    }
}
