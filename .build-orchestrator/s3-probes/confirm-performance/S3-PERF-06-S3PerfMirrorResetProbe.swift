import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport

@testable import ZTronAssetKit

extension ZTronAssetKitBenchmarks.KitBenchmarks {
    /// S3-PERF probe: `SnapshotMirror.reset()` (run on the main actor by `AssetClient.shutdown()` and by the facade's
    /// `rootVanished` reopen) drops the installed snapshot **on the main actor**: when the mirror holds its last
    /// reference, the 10,000 entries (two ids, a URL and an extension each) are freed there. `install` hands the replaced
    /// snapshot back in `InstallAck.retired` so the store frees it off the main actor (sync-2 S2-12); `reset` does not.
    /// Medians of five against P-8's `ui_call_ms_max`, the install of the same snapshot's successor printed as the control.
    @Test("P-8: the mirror's reset at 10,000 assets keeps the main actor within ui_call_ms_max", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func mirrorResetOnMain() async throws {
        let budget = try #require(try QualityBudgets().value("P-8", "ui_call_ms_max"))
        var resets: [Double] = []
        var installs: [Double] = []
        for _ in 0..<5 {
            let mirror = SnapshotMirror(time: ManualTimeSource())
            let timings = await MainActor.run { () -> (install: Double, reset: Double) in
                _ = mirror.install(ZTronAssetKitBenchmarks.KitBenchmarks.snapshot(count: 10_000))
                let clock = ContinuousClock()
                var start = clock.now
                let ack = mirror.install(S3MirrorProbe.successor(count: 10_000))
                let install = ZTronAssetKitBenchmarks.KitBenchmarks.microseconds(clock.now - start) / 1_000
                withExtendedLifetime(ack) {}
                start = clock.now
                mirror.reset()
                let reset = ZTronAssetKitBenchmarks.KitBenchmarks.microseconds(clock.now - start) / 1_000
                return (install, reset)
            }
            installs.append(timings.install)
            resets.append(timings.reset)
        }
        let median = resets.sorted()[2]
        print("S3-PERF mirror reset of 10,000 entries on the main actor: median \(median) ms (runs \(resets)); install with retired hand-back: median \(installs.sorted()[2]) ms; budget \(budget) ms")
        #expect(median <= budget)
    }
}

/// Helpers of the S3-PERF mirror probe.
enum S3MirrorProbe {
    /// A snapshot of `count` entries keyed after `KitBenchmarks.snapshot(count:)`'s, one version later.
    static func successor(count: Int) -> AssetSnapshot {
        let base = ZTronAssetKitBenchmarks.KitBenchmarks.snapshot(count: count)
        return AssetSnapshot(key: SnapshotKey(epoch: 1, version: 2), indexGeneration: 2, entries: base.entries)
    }
}

extension ZTronAssetKitBenchmarks.KitBenchmarks {
    /// S3-PERF probe: `PrefetchWindow.targets` (run on the main actor by `PrefetchWindowController.update`, a UI-facing
    /// call) walks `distance` from 1 to the radius whatever the catalog's size, allocating a two-element array per step,
    /// so a radius larger than the carousel (a public `AssetClientConfiguration.prefetchRadius` or `radius:` argument,
    /// never clamped) costs the main actor O(radius): 10,000,000 here; `Int.max` never returns.
    @Test("P-8: the prefetch window over 10 pages stays within ui_call_ms_max whatever the radius", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func prefetchWindowRadius() async throws {
        let budget = try #require(try QualityBudgets().value("P-8", "ui_call_ms_max"))
        let pages = (0..<10).map { AssetID("page-\($0)") }
        let timings = await MainActor.run { () -> (small: Double, large: Double, count: Int) in
            let clock = ContinuousClock()
            var start = clock.now
            _ = PrefetchWindow.targets(ids: pages, current: 5, radius: 10)
            let small = ZTronAssetKitBenchmarks.KitBenchmarks.microseconds(clock.now - start) / 1_000
            start = clock.now
            let targets = PrefetchWindow.targets(ids: pages, current: 5, radius: 10_000_000)
            let large = ZTronAssetKitBenchmarks.KitBenchmarks.microseconds(clock.now - start) / 1_000
            return (small, large, targets.count)
        }
        print("S3-PERF prefetch window over 10 pages: radius 10 \(timings.small) ms, radius 10,000,000 \(timings.large) ms (\(timings.count) targets); budget \(budget) ms")
        #expect(timings.count == 10)
        #expect(timings.large <= budget)
    }
}
