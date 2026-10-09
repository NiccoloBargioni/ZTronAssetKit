import Foundation
import Testing
@testable import ZTronAssetAppleHosted
import ZTronAssetModel
import ZTronAssetTestSupport

/// R-APL-2: pack progress as byte values of one asset (D-12).
@Suite("Apple tier: progress")
struct PackProgressTests {
    @available(macOS 26.0, iOS 26.0, *)
    @Test("R-APL-2: pack download progress reaches the engine as byte values scaled to the asset size", .timeLimit(.minutes(1)))
    func progressIsScaledToTheAsset() async throws {
        let asset = PackAsset("ZTronMedia/videos/intro.mp4", String(repeating: "v", count: 400))
        let fixture = AppleTierFixture(remote: [Packs.media: [asset.path: asset.bytes]])
        let packProgress = [
            PackProgress(completed: 0, total: 1_000),
            PackProgress(completed: 250, total: 1_000),
            PackProgress(completed: 255, total: 1_000),
            PackProgress(completed: 500, total: 1_000),
            PackProgress(completed: 500, total: 1_000),
            PackProgress(completed: 1_000, total: 1_000),
        ]
        fixture.backend.scriptEnsure(Packs.media, [.install(progress: packProgress)])
        let request = asset.request()
        let updates = await collect(await fixture.source.transfer(request))
        #expect(
            updates == [
                .progress(received: 0, expected: 400),
                .progress(received: 100, expected: 400),
                .progress(received: 200, expected: 400),
                .progress(received: 400, expected: 400),
                .staged(StagedFile(name: request.partialName, byteCount: 400, resumed: false, httpStatus: nil, etag: nil)),
            ]
        )
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test("R-APL-2: every waiter on one pack sees the pack's progress in its own asset's bytes", .timeLimit(.minutes(1)))
    func everyWaiterScalesToItsOwnAsset() async throws {
        let small = PackAsset("ZTronMedia/a.png", String(repeating: "s", count: 200))
        let large = PackAsset("ZTronMedia/b.png", String(repeating: "l", count: 1_000))
        let fixture = AppleTierFixture(remote: [Packs.media: [small.path: small.bytes, large.path: large.bytes]])
        fixture.backend.scriptEnsure(Packs.media, [.hold])
        let first = await fixture.source.transfer(small.request())
        let second = await fixture.source.transfer(large.request())
        await fixture.source.packs.waitForWaiters(on: Packs.media, count: 2)
        fixture.backend.releaseEnsure(Packs.media, with: .install(progress: [PackProgress(completed: 1, total: 2)]))
        let smallUpdates = await collect(first)
        let largeUpdates = await collect(second)
        #expect(smallUpdates.first == .progress(received: 100, expected: 200))
        #expect(largeUpdates.first == .progress(received: 500, expected: 1_000))
        await fixture.source.invalidate()
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test("R-APL-2: a pack download that outlived its waiters never reports into a newer download's waiters", .timeLimit(.minutes(1)))
    func staleFlightNeverReachesANewerWaiter() async throws {
        let abandoned = PackAsset("ZTronMedia/a.png", String(repeating: "a", count: 400))
        let current = PackAsset("ZTronMedia/b.png", String(repeating: "b", count: 400))
        let fixture = AppleTierFixture(remote: [Packs.media: [abandoned.path: abandoned.bytes, current.path: current.bytes]])
        // The first download ignores its cancellation, as an OS await may (APPLE-API-VERIFICATION §5).
        fixture.backend.scriptEnsure(Packs.media, [.holdIgnoringCancellation, .hold])
        let first = await fixture.source.transfer(abandoned.request())
        await fixture.source.packs.waitForWaiters(on: Packs.media, count: 1)
        first.cancel()
        #expect(await collect(first) == [.failed(.cancelled(.byClient))])

        let request = current.request()
        let second = await fixture.source.transfer(request)
        await fixture.backend.waitFor(.ensure(Packs.media), count: 2)
        await fixture.source.packs.waitForWaiters(on: Packs.media, count: 1)
        fixture.backend.releaseEnsure(
            Packs.media,
            with: .fail(.packNotFound, progress: [PackProgress(completed: 1, total: 4)]),
            oldestOnly: true
        )
        await fixture.source.packs.waitForStaleCompletions(1)
        fixture.backend.releaseEnsure(Packs.media, with: .install(progress: [PackProgress(completed: 3, total: 4)]))
        #expect(
            await collect(second) == [
                .progress(received: 300, expected: 400),
                .staged(StagedFile(name: request.partialName, byteCount: 400, resumed: false, httpStatus: nil, etag: nil)),
            ]
        )
        await fixture.source.invalidate()
    }

    @Test("R-APL-2: scaled progress is quantised, monotonic and never exceeds the asset size")
    func scalerProperties() {
        let seed: UInt64 = 0x5EED_A2
        var random = SplitMix64(seed: seed)
        for round in 0..<500 {
            let expected = Int64.random(in: 1...50_000_000, using: &random)
            let total = Int64.random(in: 1...5_000_000_000, using: &random)
            var scaler = PackProgressScaler(expectedBytes: expected)
            var reported: [Int64] = []
            var completed: Int64 = 0
            for _ in 0..<Int.random(in: 1...300, using: &random) {
                completed = min(total, completed + Int64.random(in: 0...(total / 50 + 1), using: &random))
                if let value = scaler.received(for: PackProgress(completed: completed, total: total)) {
                    reported.append(value)
                }
            }
            if let value = scaler.received(for: PackProgress(completed: total, total: total)) {
                reported.append(value)
            }
            let step = expected / 100 + (expected % 100 == 0 ? 0 : 1)
            #expect(reported.last == expected, "seed \(seed) round \(round)")
            #expect(reported.allSatisfy { (0...expected).contains($0) }, "seed \(seed) round \(round)")
            #expect(zip(reported, reported.dropFirst()).allSatisfy { $1 > $0 && ($1 - $0 >= step || $1 == expected) }, "seed \(seed) round \(round)")
            #expect(reported.count <= 101, "seed \(seed) round \(round)")
        }
    }

    @Test("R-APL-2: a pack download fed one unit at a time yields at most 101 values for an asset of any size")
    func smallAssetsStayWithinTheBound() {
        for expected: Int64 in [1, 2, 99, 100, 101, 150, 199, 250, 1_000, 10_001] {
            var scaler = PackProgressScaler(expectedBytes: expected)
            var reported: [Int64] = []
            for completed in 0...expected {
                if let value = scaler.received(for: PackProgress(completed: completed, total: expected)) {
                    reported.append(value)
                }
            }
            #expect(reported.count <= 101, "\(expected) bytes: \(reported.count) values")
            #expect(reported.first == 0 && reported.last == expected, "\(expected) bytes")
        }
    }

    @Test("R-APL-2: scaled progress is exact integer arithmetic and never traps for an asset size near Int64.max")
    func scalerArithmeticIsExact() {
        var exact = PackProgressScaler(expectedBytes: 100)
        #expect(exact.received(for: PackProgress(completed: 29, total: 100)) == 29, "0.29 × 100 is 28.999… in Double")
        let top = Int64.max
        var largest = PackProgressScaler(expectedBytes: top)
        #expect(largest.received(for: PackProgress(completed: 1, total: 2)) == top / 2)
        #expect(largest.received(for: PackProgress(completed: top, total: top)) == top)
        var nearTop = PackProgressScaler(expectedBytes: top - 511)
        #expect(nearTop.received(for: PackProgress(completed: 1, total: 1)) == top - 511, "Double rounds this to 2^63")
        var hugeTotal = PackProgressScaler(expectedBytes: top)
        #expect(hugeTotal.received(for: PackProgress(completed: top - 1, total: top)) == top - 1)
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test("R-APL-2: progress reported under another flight's id never reaches the current flight's waiters", .timeLimit(.minutes(1)))
    func progressOfAnotherFlightIsDropped() async throws {
        let backend = FakePackBackend(remote: [Packs.media: ["a.png": Data("a".utf8)]])
        backend.scriptEnsure(Packs.media, [.hold])
        let coordinator = PackAvailabilityCoordinator(backend: backend)
        let (stream, progress) = AsyncStream.makeStream(of: PackProgress.self)
        let waiter = Task {
            await coordinator.ensure(Packs.media, progress: progress)
        }
        await coordinator.waitForWaiters(on: Packs.media, count: 1)
        // A value an abandoned flight took from its stream just before it was cancelled (E-6): never this flight's.
        await coordinator.broadcast(PackProgress(completed: 1, total: 4), pack: Packs.media, flightID: .max)
        backend.releaseEnsure(Packs.media, with: .install(progress: [PackProgress(completed: 3, total: 4)]))
        #expect(await waiter.value == .available)
        progress.finish()
        var received: [PackProgress] = []
        for await value in stream {
            received.append(value)
        }
        #expect(received == [PackProgress(completed: 3, total: 4)], "only the current flight's progress")
        await coordinator.close()
    }

    @Test("R-APL-2: unknown totals and empty assets report no progress, and overshoot is clamped")
    func scalerEdges() {
        var unknownTotal = PackProgressScaler(expectedBytes: 100)
        #expect(unknownTotal.received(for: PackProgress(completed: 5, total: 0)) == nil)
        var empty = PackProgressScaler(expectedBytes: 0)
        #expect(empty.received(for: PackProgress(completed: 5, total: 10)) == nil)
        var overshoot = PackProgressScaler(expectedBytes: 100)
        #expect(overshoot.received(for: PackProgress(completed: -3, total: 10)) == 0)
        #expect(overshoot.received(for: PackProgress(completed: 30, total: 10)) == 100)
        #expect(overshoot.received(for: PackProgress(completed: 30, total: 10)) == nil)
    }

    @Test("R-APL-2: Foundation.Progress becomes a value at the backend boundary")
    func progressSnapshot() {
        let live = Progress(totalUnitCount: 2_048)
        live.completedUnitCount = 512
        let snapshot = PackProgress(snapshotOf: live)
        live.completedUnitCount = 2_048
        #expect(snapshot == PackProgress(completed: 512, total: 2_048))
        #expect(PackProgress(snapshotOf: live) == PackProgress(completed: 2_048, total: 2_048))
        #expect(PackProgress(snapshotOf: Progress(totalUnitCount: -1)) == PackProgress(completed: 0, total: 0))
        let overrun = Progress(totalUnitCount: 10)
        overrun.completedUnitCount = 25
        #expect(PackProgress(snapshotOf: overrun) == PackProgress(completed: 10, total: 10))
    }
}
