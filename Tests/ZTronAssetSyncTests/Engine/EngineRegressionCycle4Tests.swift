import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Regressions the verifiers of close-out cycle 3 found in WP-F (cycle 4 of the level-4 close-out). Each failed before
/// its fix (`docs/adr-drafts/f.md`, F-24).
@Suite("Engine regressions, close-out cycle 4")
struct EngineRegressionCycle4Tests {
    /// What the second, committing `apply` applies after the first threw.
    enum SecondManifest: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// The same `v2` (both ensures fetched it).
        case same
        /// A later `v3`, which also lists the on-demand `b` (and still not `z`).
        case later

        var testDescription: String {
            self.rawValue
        }
    }

    // MARK: Announcements that do not depend on what the store's report saw (L4-R7, L4-R10; PROBE-C3-7)

    /// PROBE-C3-7: two `ensureAvailable` calls each apply `v2`, which drops `z`. The first `apply` prunes `z` in the
    /// store's memory and then fails its index commit (ADR-050); the second, waiting for the store's apply gate
    /// meanwhile, re-applies `v2` against that memory, so its report prunes nothing, and it commits. The engine followed
    /// the second report and announced nothing for `z`; the catch-up owed by the first then read a view equal to the
    /// copy, so `assetRemoved(z, .pruned)` never arrived although `z` left the store and the engine's copy. The same
    /// holds when the second ensure applies a later manifest that does not list `z` either.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-12: a prune an apply wrote before it threw is announced when a concurrent apply of the same manifest commits",
        .timeLimit(.minutes(1)),
        arguments: SecondManifest.allCases
    )
    func pruneOfFailedApplyAnnouncedByConcurrentApply(_ second: SecondManifest) async throws {
        let bulk = NextUnitGate()
        let harness = EngineHarness.make(bulk: bulk)
        let engine = harness.engine
        let aBytes = EngineFixture.bytes(9_701)
        let zBytes = EngineFixture.bytes(9_702)
        let a = EngineFixture.entry("a", aBytes)
        let z = EngineFixture.entry("z", zBytes)
        await harness.serve([(a, aBytes), (z, zBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        let probe = EventProbe(stream: try await engine.subscribe().get())
        // v2 drops z; the first ensure fetches it, the second v2 again or v3. The first index commit after this point fails.
        let v2 = EngineFixture.manifestData([a])
        let next = second == .same ? v2 : EngineFixture.manifestData([a, EngineHarness.onDemand("b", EngineFixture.bytes(9_703))])
        await harness.source.scriptManifest([
            .fetched(v2, etag: EngineFixture.etag("v2")),
            .fetched(next, etag: EngineFixture.etag(second == .same ? "v2" : "v3"))
        ])
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .io))
        // The first ensure's `apply` holds in the store's planning unit (after the ensure's manifest decode), inside the
        // store's apply gate.
        await bulk.holdNext(skipping: 1)
        let first = Task { await engine.ensureAvailable(scope: .identifiers(["a"])) }
        await bulk.waitForHold()
        // The second ensure fetches its manifest and begins its own `apply`, which waits for the first (both count as
        // catch-ups from the moment they begin, whether they wait at the store's gate or for the engine's turn).
        let secondEnsure = Task { await engine.ensureAvailable(scope: .identifiers(["a"])) }
        await engine.awaitCondition { $0.state.manifestCatchUps == 2 }
        await bulk.release()
        let firstResult = await first.value
        let secondResult = await secondEnsure.value
        guard case .failure(.storageUnavailable) = firstResult else {
            Issue.record("setup: the first apply's failed index commit fails its ensure: \(firstResult)")
            await probe.stop()
            await engine.shutdown()
            return
        }
        #expect((try? secondResult.get())?.present == 1, "setup: the second apply commits: \(secondResult)")
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.catchUpAfterFailedApply }
        let storeManifest = try await harness.view().appliedManifest
        #expect(storeManifest.entry(for: "z") == nil, "setup: the store pruned z")
        #expect(await engine.readForTests { $0.state.applied.digest } == storeManifest.digest, "the engine's copy follows the store")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
        _ = await probe.next { $0 == .clientShutDown }
        let received = await probe.received
        await probe.stop()
        let prunes = received.filter { $0 == .assetRemoved("z", .pruned) }.count
        #expect(prunes == 1, "\(second): z's prune is announced exactly once: \(received)")
    }
}
