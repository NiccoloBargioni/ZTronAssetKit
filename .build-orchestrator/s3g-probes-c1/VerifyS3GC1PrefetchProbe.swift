import Foundation
import Testing
@testable import ZTronAssetKit
import ZTronAssetModel

/// Verifier probe (s3g close-out cycle 1, correctness lens): the clamped `PrefetchWindow.targets` against a brute-force
/// reference (the pre-fix walk with the radius capped at the carousel's size, which yields the same window), over
/// carousels with repeated ids, every `current`, and radii from `Int.min` to `Int.max`.
@Suite("Verify S3G C1 prefetch probe")
struct VerifyS3GC1PrefetchProbe {
    static func reference(ids: [AssetID], current: Int, radius: Int) -> [PrefetchTarget] {
        guard ids.indices.contains(current) else {
            return []
        }
        var result: [PrefetchTarget] = [PrefetchTarget(id: ids[current], priority: .userInitiated, distance: 0)]
        var seen: Set<AssetID> = [ids[current]]
        let cap = min(max(radius, 0), ids.count)
        var distance = 1
        while distance <= cap {
            for index in [current + distance, current - distance] where ids.indices.contains(index) {
                let id = ids[index]
                if seen.insert(id).inserted {
                    result.append(PrefetchTarget(id: id, priority: .prefetch, distance: distance))
                }
            }
            distance += 1
        }
        return result
    }

    @Test("probe: clamped window equals the reference for every current and radius, repeated ids included")
    func clampedEqualsReference() {
        var generator = EventContinuityModelTests.SplitMix(state: 0xC1)
        let radii = [Int.min, -1, 0, 1, 2, 3, 7, 49, 50, 51, 99, 100, 101, 1_000_000, Int.max - 1, Int.max]
        var compared = 0
        for count in [0, 1, 2, 3, 10, 51, 100] {
            for distinct in [1, 3, max(count, 1)] {
                let ids = (0..<count).map { _ in AssetID("p\(generator.below(distinct))") }
                for current in -2...(count + 2) {
                    for radius in radii {
                        let got = PrefetchWindow.targets(ids: ids, current: current, radius: radius)
                        let want = VerifyS3GC1PrefetchProbe.reference(ids: ids, current: current, radius: radius)
                        #expect(got == want, "count \(count), distinct \(distinct), current \(current), radius \(radius)")
                        compared += 1
                    }
                }
            }
        }
        #expect(compared > 1_000)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("probe: Int.max over a 200,000-page carousel at both ends returns every page once")
    @MainActor
    func hugeCarouselIntMax() {
        let ids = (0..<200_000).map { AssetID("p\($0)") }
        for current in [0, 100_000, ids.count - 1] {
            let clock = ContinuousClock()
            let start = clock.now
            let window = PrefetchWindow.targets(ids: ids, current: current, radius: .max)
            let elapsed = clock.now - start
            print("probe: 200,000 pages, current \(current), radius Int.max: \(window.count) targets in \(elapsed)")
            #expect(window.count == ids.count)
            #expect(window.last?.distance == max(current, ids.count - 1 - current))
        }
    }
}
