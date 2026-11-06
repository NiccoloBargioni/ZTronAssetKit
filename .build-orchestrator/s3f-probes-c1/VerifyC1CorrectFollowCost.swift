import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch measurement (s3f close-out verification, cycle 1): the cost of one follow turn after an apply under a
/// 10,000-member waiting prefetch group, when nothing moved, when 10 % of the ids changed content and when every id did.
@Suite("VerifyC1Correct follow cost")
struct VerifyC1CorrectFollowCost {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-V8: follow turn cost at 10,000 members", .timeLimit(.minutes(10)))
    func followCost() async throws {
        let count = 10_000
        let v1 = (0..<count).map { EngineHarness.onDemand(String(format: "m%05d", $0), EngineFixture.bytes(UInt64(20_000 + $0), count: 16)) }
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 2))
        try await EngineSingleFlightTests.applied(v1, harness: harness)
        let engine = harness.engine
        _ = try await engine.registerGroup(v1.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count }
        func changed(_ fraction: Int, salt: UInt64) -> [ManifestEntry] {
            v1.enumerated().map { index, entry in
                index % 100 < fraction
                    ? EngineHarness.onDemand(entry.identifier.rawValue, EngineFixture.bytes(salt + UInt64(index), count: 16))
                    : entry
            }
        }
        let same = try ValidatedManifest(entries: v1, digest: ContentHash.sha256(of: Data("same".utf8)))
        let tenth = try ValidatedManifest(entries: changed(10, salt: 900_000), digest: ContentHash.sha256(of: Data("tenth".utf8)))
        let all = try ValidatedManifest(entries: changed(100, salt: 1_900_000), digest: ContentHash.sha256(of: Data("all".utf8)))
        var lines: [String] = []
        for (name, manifest) in [("nothing moved", same), ("10% changed", tenth), ("every id changed", all)] {
            let result = await engine.readForTests { engine -> (Double, Int, Int) in
                let previous = engine.state.applied
                let clock = ContinuousClock()
                let start = clock.now
                engine.adoptApplied(manifest, etag: nil)
                engine.followApplied(from: previous)
                let elapsed = clock.now - start
                let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
                return (ms, engine.state.jobs.count, engine.invariantViolations().count)
            }
            lines.append("\(name): \(result.0) ms, jobs after \(result.1), violations \(result.2)")
        }
        print("PROBE-V8 follow turn at \(count): \(lines)")
        #expect(lines.count == 3)
        await engine.shutdown()
    }
}
