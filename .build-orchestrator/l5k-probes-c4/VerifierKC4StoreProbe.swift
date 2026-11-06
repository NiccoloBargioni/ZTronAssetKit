import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetStorage
import ZTronAssetTestSupport

// Verifier probes, WP-K close-out cycle 4, correctness lens. Scratch copy only; never committed.

/// A sink that can hold installs at the await (REENTRANCY R6) and forwards to `inner` once released, so a probe can
/// read what the readers see (`inner.installed`).
actor VKC4HoldingSink: SnapshotSink {
    let inner: ScriptedSnapshotSink
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(inner: ScriptedSnapshotSink) {
        self.inner = inner
    }

    func setHolding(_ holding: Bool) {
        self.holding = holding
        if !holding {
            let released = self.held
            self.held = []
            for continuation in released {
                continuation.resume()
            }
        }
    }

    var heldCount: Int {
        self.held.count
    }

    func install(_ snapshot: AssetSnapshot) async -> InstallAck {
        if self.holding {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.held.append(continuation)
            }
        }
        return await self.inner.install(snapshot)
    }
}

@Suite("Verifier K-C4 store probes", .serialized)
struct VerifierKC4StoreProbe {
    /// P20-STALE: `performMigrateLegacy` decides `last` (queue and claims empty) before its publication's await and uses
    /// it after. A batch whose last claimed file is an adopt-on-demand's publishes at `.bulk` with the install window
    /// open, so the publication installs at once and suspends on the sink; the adopt-on-demand ends meanwhile (unclaims
    /// the file, publishes at `.bulk` inside the now closed window: `installDue`). The batch then returns early with
    /// nothing remaining and not finished: RE-S29's back-off signal, which L5K-R20's own comment says must not happen.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("P20-STALE: the batch's stale `last` after an install that suspended", .timeLimit(.minutes(1)))
    func p20StaleLast() async throws {
        let time = ManualTimeSource()
        let tree = try LegacyFixture.fixtureFiles()
        let bulk = SteppedBlockingExecutor(holding: false)
        let metadata = SteppedBlockingExecutor(holding: false)
        let defaults = FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "1.4+77"])
        let inner = ScriptedSnapshotSink()
        let sink = VKC4HoldingSink(inner: inner)
        let harness = CoreHarness.cleanup(
            disk: try LegacyFixture.disk(tree),
            legacy: CleanupFixture.legacyPolicy,
            defaults: defaults,
            installInterval: 0.1,
            time: time,
            metadata: metadata,
            bulk: bulk,
            sink: inner,
            sinkOverride: sink
        )
        _ = try await harness.store.open()
        let queue = await harness.state.migration.queue
        let file = try #require(queue.last)
        let id = try #require(file.ids.first)
        // An adopt-on-demand (a bulk-lane job's pre-transfer read) takes the next file; its hash unit is held.
        await bulk.setHolding(true)
        let onDemand = Task { () async throws -> AssetLocation? in
            try await harness.store.adoptLegacyNow(id, urgency: .bulk)
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        let onDemandHash = Set(await bulk.heldUnits)
        // The install window is open when the batch publishes (the clock passed open's install).
        time.advance(by: 1)
        await sink.setHolding(true)
        let batch = Task { () async throws -> LegacyMigrationProgress in
            try await harness.store.migrateLegacy(maxFiles: 64)
        }
        while await sink.heldCount == 0 {
            for unit in await bulk.heldUnits where !onDemandHash.contains(unit) {
                await bulk.release(unit)
            }
            try Task.checkCancellation()
            await Task.yield()
        }
        let atHold = await harness.state.migration
        // The adopt-on-demand ends while the batch's install is held at the sink.
        await bulk.setHolding(false)
        let answer = try await onDemand.value
        let afterOnDemand = await harness.state.migration
        let installDueAfterOnDemand = await harness.state.core.snapshots.installDue
        await sink.setHolding(false)
        let progress = try await batch.value
        let phase = await harness.state.migration.phase
        print("KC4-PROBE P20-STALE queue=\(queue.count) atHold(queue=\(atHold.queue.count) claimed=\(atHold.claimed.count) onDemand=\(atHold.onDemand.count)) answer=\(answer != nil) afterOnDemand(queue=\(afterOnDemand.queue.count) claimed=\(afterOnDemand.claimed.count)) installDue=\(installDueAfterOnDemand) progress=\(progress) phase=\(phase)")
        #expect(atHold.queue.isEmpty && atHold.claimed == [file], "premise: the batch published with only the adopt-on-demand's file claimed")
        #expect(answer != nil, "premise: the adopt-on-demand adopted its file")
        #expect(installDueAfterOnDemand, "premise: the adopt-on-demand's bulk publication left an install due")
        #expect(progress.finished || progress.remaining > 0, "P20-STALE: migrateLegacy returned `remaining == 0 && !finished` (RE-S29's back-off signal) after its batch: \(progress)")
    }
}
