// Target: Tests/ZTronAssetStorageTests/Core/ (passes on s3-base: the missing §7.3 scenario, committable as is)
import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// SPEC §7.3 "crash at every boundary during … checksum-change update · directory change · removal" (R-STO-5): a
/// durably synced v1 catalog, then one lifetime that applies v2 (one checksum change, one directory change, one
/// removal, one unchanged), publishes the changed bytes, commits, lets the deletion grace pass, reaps, flushes, closes.
@available(macOS 15.0, iOS 18.0, *)
enum CatalogUpdate {
    static let oldA = CoreFixture.bytes(910, count: 500)
    static let newA = CoreFixture.bytes(911, count: 520)
    static let bBytes = CoreFixture.bytes(912, count: 480)
    static let cBytes = CoreFixture.bytes(913, count: 460)
    static let dBytes = CoreFixture.bytes(914, count: 440)

    static let v1: [ManifestEntry] = [
        CoreFixture.entry("a", oldA),
        CoreFixture.entry("b", bBytes),
        CoreFixture.entry("c", cBytes),
        CoreFixture.entry("d", dBytes),
    ]

    static let v2: [ManifestEntry] = {
        var moved = CoreFixture.entry("b", bBytes)
        moved.localPathComponents = ["moved", "deeper"]
        moved.localFileName = "renamed"
        return [CoreFixture.entry("a", newA), moved, CoreFixture.entry("d", dBytes)]
    }()

    static let manifest1 = CoreFixture.manifest(v1, etagSeed: "v1")
    static let manifest2 = CoreFixture.manifest(v2, etagSeed: "v2")

    /// The durably committed v1 store every enumerated lifetime starts from.
    static func baseDisk() async throws -> DiskImage {
        let harness = CoreHarness.make()
        _ = try await harness.store.open()
        _ = try await harness.store.apply(manifest1, etag: nil, eviction: nil)
        for (index, entry) in v1.enumerated() {
            let bytes = [oldA, bBytes, cBytes, dBytes][index]
            try await harness.publish(bytes, [entry], sequence: UInt32(index + 1))
        }
        _ = await harness.store.runDueWork()
        try await harness.store.flush(.durable)
        await harness.store.close()
        return harness.fileSystem.survivingDisk()
    }

    struct Trace {
        var newAReturned = false
        var newACommitted = false
        var generation: UInt64 = 0
        /// The mutation index at which the deletion grace started to pass (no blob may be unlinked before it).
        var graceStart: Int?
    }

    static func run(_ harness: CoreHarness) async -> Trace {
        var trace = Trace()
        do {
            _ = try await harness.store.open()
            trace.generation = try await harness.store.apply(manifest2, etag: ETag(rawValue: "\"v2\""), eviction: nil).generation
            let staged = try await harness.stage(newA, for: v2[0], sequence: 7)
            _ = try await harness.store.publish(staged, binding: [v2[0].identifier], expecting: v2[0].contentIdentity, urgency: .bulk)
            trace.newAReturned = true
            if await harness.store.runDueWork().committed {
                trace.newACommitted = true
                trace.generation = await harness.state.core.committedGeneration
            }
            trace.graceStart = harness.fileSystem.operations.filter(\.kind.isMutation).count
            await harness.settleDeletions()
            try await harness.store.flush(.durable)
            trace.newACommitted = true
            trace.generation = await harness.state.core.committedGeneration
            await harness.store.close()
        } catch {
            // The crash: every later call fails.
        }
        return trace
    }

    /// Reopens, checks I-1, I-2, I-4, I-5, converges to v2 and returns the ids that had to be downloaded again.
    static func reopenAndConverge(_ disk: DiskImage, after trace: Trace, label: String) async -> Set<AssetID> {
        let harness = CoreHarness.make(disk: disk)
        do {
            _ = try await harness.store.open()
            let loaded = await harness.state.core.committedGeneration
            #expect(loaded >= trace.generation, "\(label): I-5, generation \(loaded) < returned \(trace.generation)")
            let violations = await CoreInvariants.violations(of: harness)
            #expect(violations.isEmpty, "\(label): \(violations)")
            _ = try await harness.store.apply(manifest2, etag: nil, eviction: nil)
            var downloaded: Set<AssetID> = []
            let expected: [AssetID: Data] = [AssetID("a"): newA, AssetID("b"): bBytes, AssetID("d"): dBytes]
            // A changed asset keeps serving its old bytes, stale, until its new content is published (R-INT-3).
            for entry in v2 where await harness.store.location(for: entry.identifier, extensions: [], recordingAccess: false).map(\.isStale) ?? true {
                let bytes = try #require(expected[entry.identifier])
                try await harness.publish(bytes, [entry], sequence: 40)
                downloaded.insert(entry.identifier)
            }
            _ = await harness.store.runDueWork()
            await harness.settleDeletions()
            try await harness.store.flush(.durable)
            for entry in v2 {
                let location = await harness.store.location(for: entry.identifier, extensions: [], recordingAccess: false)
                #expect(location.flatMap { harness.content($0.url) } == expected[entry.identifier], "\(label): \(entry.identifier.rawValue) did not converge")
            }
            #expect(await harness.store.location(for: AssetID("c"), extensions: [], recordingAccess: false) == nil, "\(label): the removed asset is still served")
            let after = await CoreInvariants.violations(of: harness)
            #expect(after.isEmpty, "\(label) after convergence: \(after)")
            await harness.store.close()
            return downloaded
        } catch {
            Issue.record("\(label): reopen or convergence failed with \(error)")
            return []
        }
    }
}

@Suite("S3 conformance probe: crash at every boundary of a catalog update (R-STO-5)")
struct S3ConformanceUpdateCrashTests {
    @Test(
        "R-STO-5: crash at every boundary during a checksum-change update, a directory change and a removal preserves I-1…I-5",
        .timeLimit(.minutes(1)),
        arguments: CrashMode.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func crashAtEveryBoundaryOfAnUpdate(mode: CrashMode) async throws {
        let base = try await CatalogUpdate.baseDisk()
        let clean = CoreHarness.make(disk: base)
        let cleanTrace = await CatalogUpdate.run(clean)
        #expect(cleanTrace.newACommitted)
        let total = clean.fileSystem.mutationCount
        #expect(total > 10)
        var crashes = 0
        for point in 0..<total {
            await Task.yield()
            let harness = CoreHarness.make(disk: base, crashBefore: point, mode: mode)
            let trace = await CatalogUpdate.run(harness)
            guard harness.fileSystem.crashed else {
                Issue.record("\(mode) at \(point): the crash point was never reached")
                continue
            }
            crashes += 1
            let label = "\(mode) at \(point)"
            // I-3 in the crashed lifetime: no blob is unlinked before the grace started to pass.
            let mutations = harness.fileSystem.operations.filter(\.kind.isMutation)
            let early = mutations.prefix(trace.graceStart ?? mutations.count)
            let unlinked = CoreInvariants.blobRemovals(Array(early), layout: harness.layout)
            #expect(unlinked.isEmpty, "\(label): \(unlinked)")
            let downloaded = await CatalogUpdate.reopenAndConverge(harness.fileSystem.survivingDisk(), after: trace, label: label)
            // A move and an unchanged entry never cost a download.
            #expect(!downloaded.contains(AssetID("b")) && !downloaded.contains(AssetID("d")), "\(label): re-downloaded \(downloaded)")
        }
        #expect(crashes == total)
        print("R-STO-5 update \(mode): \(total) crash points enumerated")
    }
}
