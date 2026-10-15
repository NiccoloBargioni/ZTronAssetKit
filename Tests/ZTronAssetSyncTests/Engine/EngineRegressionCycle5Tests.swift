import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Regressions the verifiers of close-out cycle 4 found in WP-F (cycle 5 of the level-4 close-out). Each failed before
/// its fix (`docs/adr-drafts/f.md`, F-25).
@Suite("Engine regressions, close-out cycle 5")
struct EngineRegressionCycle5Tests {
    /// What the ensure's `apply` applies after the run's.
    enum SecondManifest: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// The same `v2` the run applied.
        case same
        /// A later `v3`, which also lists the on-demand `b` (and still not `z`).
        case later

        var testDescription: String {
            self.rawValue
        }
    }

    // MARK: Two committed applies followed in the store's order (R-SYN-12, L4-R7, L4-R10; PROBE-C4-4)

    /// PROBE-C4-4: a run applies `v2` (drops `z`) and an `ensureAvailable` then applies `v2` again or `v3` (adds `b`).
    /// The store commits the run's `apply` first; the engine ran its side of the ensure's `apply` first (a
    /// higher-priority continuation overtaking a lower-priority one while the actor was busy; here the run's follow-up is
    /// held by a test seam until no other `apply` is at the store or waiting to be followed). Following the run's older
    /// report last took the engine's copy back to `v2` while the store held `v3`, announced `z` pruned a second time and
    /// announced `b` pruned although the store lists and serves it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-12: two committed applies are followed in the store's order, so a prune is announced once and a later apply's additions never",
        .timeLimit(.minutes(1)),
        arguments: SecondManifest.allCases
    )
    func appliesFollowedInStoreOrder(_ second: SecondManifest) async throws {
        let bulk = NextUnitGate()
        let harness = EngineHarness.make(bulk: bulk)
        let engine = harness.engine
        let aBytes = EngineFixture.bytes(9_801)
        let zBytes = EngineFixture.bytes(9_802)
        let a = EngineFixture.entry("a", aBytes)
        let z = EngineFixture.entry("z", zBytes)
        await harness.serve([(a, aBytes), (z, zBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        let probe = EventProbe(stream: try await engine.subscribe().get())
        let bBytes = EngineFixture.bytes(9_803)
        let b = EngineHarness.onDemand("b", bBytes)
        await harness.source.script(b.transferID, [.stage(bBytes)])
        let v2 = EngineFixture.manifestData([a])
        let next = second == .same ? v2 : EngineFixture.manifestData([a, b])
        await harness.source.scriptManifest([
            .fetched(v2, etag: EngineFixture.etag("v2")),
            .fetched(next, etag: EngineFixture.etag(second == .same ? "v2" : "v3"))
        ])
        // The run's `apply` holds in the store's planning unit (after the run's manifest decode).
        await bulk.holdNext(skipping: 1)
        let run = Task { await engine.sync(.force) }
        await bulk.waitForHold()
        // The ensure fetches the next manifest and begins its own `apply`.
        let ensure = Task { await engine.ensureAvailable(scope: .identifiers(["a"])) }
        await engine.awaitCondition { $0.state.manifestCatchUps == 2 }
        // The run's `apply` commits first; the engine's side of it waits until no other `apply` is at the store or
        // waiting to be followed.
        await engine.holdNextApplyFollow()
        await bulk.release()
        await engine.awaitCondition { $0.applyFollowHeld && $0.state.appliesInFlight == 1 }
        await engine.releaseApplyFollow()
        let outcome = await harness.withClock { await run.value }
        let ensured = await ensure.value
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.catchUpAfterFailedApply && $0.state.appliesInFlight == 0 }
        #expect(outcome.completeReport != nil, "setup: the run completes: \(outcome)")
        #expect((try? ensured.get())?.present == 1, "setup: the ensure's apply commits: \(ensured)")
        let storeManifest = try await harness.view().appliedManifest
        let copy = await engine.readForTests { $0.state.applied }
        #expect(copy.digest == storeManifest.digest, "\(second): the engine's copy \(copy.entries.map(\.identifier)) is the store's \(storeManifest.entries.map(\.identifier))")
        if second == .later {
            #expect(copy.entry(for: "b") != nil, "the engine's copy lists b, as the store does")
        }
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
        _ = await probe.next { $0 == .clientShutDown }
        let received = await probe.received
        await probe.stop()
        let zPrunes = received.filter { $0 == .assetRemoved("z", .pruned) }.count
        let bRemovals = received.filter {
            if case .assetRemoved("b", _) = $0 {
                return true
            }
            return false
        }.count
        #expect(zPrunes == 1, "\(second): z's prune is announced exactly once: \(received)")
        #expect(bRemovals == 0, "\(second): b, which the store lists, is never announced removed: \(received)")
    }
}
