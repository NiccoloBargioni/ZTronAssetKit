import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Verifier probes, Stage 3 WP-B close-out cycle 1 (correctness lens). Not for commit.
@Suite("VerifierS3BC1Probe")
struct VerifierS3BC1Probe {
    /// S3-SECU-01, own variant: two entries each declaring Int64.max bytes and one small one, all missing.
    @Test("probe SECU-01: availability with two Int64.max entries saturates", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func availabilityTwoMax() async throws {
        let limits = ManifestLimits(maxAssetBytes: .max)
        let json = """
            [{"identifier":"a","fileExtension":"png","remotePath":"media/a.png","localPathComponents":[],"byteSize":\(Int64.max)},
             {"identifier":"b","fileExtension":"png","remotePath":"media/b.png","localPathComponents":[],"byteSize":\(Int64.max)},
             {"identifier":"c","fileExtension":"png","remotePath":"media/c.png","localPathComponents":[],"byteSize":7}]
            """
        let manifest = try ManifestDecoder.decode(Data(json.utf8), options: ManifestDecodingOptions(limits: limits))
        #expect(manifest.entries.count == 3)
        let harness = CoreHarness.make(configuration: CoreFixture.configuration(limits: limits))
        _ = try await harness.store.open()
        _ = try await harness.store.apply(manifest, etag: nil, eviction: nil)
        let report = await harness.store.availability(of: .all)
        print("PROBE SECU-01 all: missing=\(report.missing) bytesMissing=\(report.bytesMissing)")
        #expect(report.missing == 3 && report.bytesMissing == .max)
        let pair = await harness.store.availability(of: .identifiers(["a", "c"]))
        print("PROBE SECU-01 a+c: missing=\(pair.missing) bytesMissing=\(pair.bytesMissing)")
        #expect(pair.missing == 2 && pair.bytesMissing == .max)
        let small = await harness.store.availability(of: .identifiers(["c"]))
        #expect(small.bytesMissing == 7)
        await harness.store.close()
    }

    /// OI-14 fix (fb99142), new regression hunt: an `apply` that swaps the contents of two present assets dooms one
    /// blob (counted as released) and rescues it in the next adoption, so nothing leaves usedBytes; an overlapping
    /// maintenance eviction must still free what a run alone frees (six assets, 600 bytes) and end at or below the
    /// hysteresis target (450 of a 500-byte budget).
    @Test("probe OI-14: a content swap during eviction's candidates unit frees nothing, so eviction still frees 600", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func swapWhileEvictionCandidatesRun() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = try await EvictionOverlapTests.harness(bulk: bulk)
        let before = try await harness.store.freeSpace()
        print("PROBE OI-14 before: used=\(before.usedBytes) pending=\(before.pendingReclaim) budget=\(before.budgetBytes)")
        await bulk.setHolding(true)
        let maintenance = Task {
            try await harness.store.evictIfNeeded()
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        let candidates = try #require(await bulk.heldUnits.first)
        let releasedBefore = await harness.state.eviction.releasedBytes
        var entries = EvictionOverlapTests.assets.map(\.entry)
        let k8 = entries[8].checksum
        entries[8].checksum = entries[9].checksum
        entries[9].checksum = k8
        let swapped = entries
        let report = try await CleanupSteps.run(bulk, keeping: [candidates]) {
            try await harness.store.apply(CoreFixture.manifest(swapped, etagSeed: "swapped"), etag: nil, eviction: nil)
        }.value
        let releasedAfter = await harness.state.eviction.releasedBytes
        let mid = try await harness.store.freeSpace()
        print("PROBE OI-14 apply: reused=\(report.reused.map(\.rawValue)) contentChanged=\(report.contentChanged.map(\.rawValue)) releasedBytes delta=\(releasedAfter - releasedBefore) used=\(mid.usedBytes) pending=\(mid.pendingReclaim)")
        await bulk.setHolding(false)
        let result = try await maintenance.value
        let evicted = await EvictionOverlapTests.evicted(harness)
        let after = try await harness.store.freeSpace()
        print("PROBE OI-14 result=\(result) evicted=\(evicted) used after=\(after.usedBytes) pending=\(after.pendingReclaim)")
        #expect(mid.usedBytes == before.usedBytes, "the swap leaves usedBytes unchanged")
        #expect(result == CleanupResult(bytesFreed: 600, filesRemoved: 6), "nothing left usedBytes, so the run must free what it measured")
        #expect(after.usedBytes <= 450, "R-CLN-4: down to the hysteresis target (90 % of 500)")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// Control: the same swap with no eviction overlapping, then a maintenance run alone.
    @Test("probe OI-14 control: swap then eviction alone", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func swapThenEviction() async throws {
        let harness = try await EvictionOverlapTests.harness()
        var entries = EvictionOverlapTests.assets.map(\.entry)
        let k8 = entries[8].checksum
        entries[8].checksum = entries[9].checksum
        entries[9].checksum = k8
        _ = try await harness.store.apply(CoreFixture.manifest(entries, etagSeed: "swapped"), etag: nil, eviction: nil)
        let result = try await harness.store.evictIfNeeded()
        let after = try await harness.store.freeSpace()
        print("PROBE OI-14 control result=\(result) used after=\(after.usedBytes)")
        #expect(after.usedBytes <= 450)
    }

    /// ReapQueue model: random admissions, random attempted prefixes, random state flips between batches. Every key
    /// is attempted at most once; an unattempted key leads the next batch when still admissible; the run ends.
    @Test("probe S3-PERF-04: ReapQueue random model", .timeLimit(.minutes(1)))
    func reapQueueModel() async throws {
        var rng = SplitMix(seed: 0x5EED)
        let keys = (0..<300).map { CoreFixture.key(CoreFixture.bytes(UInt64(20_000 + $0), count: 8)) }.sorted()
        for round in 0..<400 {
            if round % 50 == 0 {
                await Task.yield()
            }
            // 0 doomed (admissible), 1 blocked, 2 deleting, 3 gone.
            var state: [BlobKey: Int] = [:]
            for key in keys {
                state[key] = rng.next() % 4 == 0 ? 1 : 0
            }
            var attemptedOnce: Set<BlobKey> = []
            var queue = ReapQueue(keys)
            var batches = 0
            var pendingLead: BlobKey?
            while !queue.isEmpty {
                batches += 1
                #expect(batches < 10_000)
                if batches >= 10_000 {
                    return
                }
                let limit = Int(rng.next() % 64) + 1
                let batch = queue.nextBatch(limit: limit) { key in
                    guard state[key] == 0 else {
                        return false
                    }
                    state[key] = 2
                    return true
                }
                if let lead = pendingLead, state[lead] == 2 {
                    // The lead was admissible and admitted: it must be first.
                    #expect(batch.first == lead, "round \(round): an unattempted key did not lead the next batch")
                }
                pendingLead = nil
                guard !batch.isEmpty else {
                    break
                }
                let attempted = Int(rng.next() % UInt64(batch.count)) + 1
                for (position, key) in batch.enumerated() {
                    if position < attempted {
                        #expect(!attemptedOnce.contains(key), "round \(round): key attempted twice")
                        attemptedOnce.insert(key)
                        state[key] = rng.next() % 5 == 0 ? 1 : 3
                    } else {
                        state[key] = 0
                        if pendingLead == nil {
                            pendingLead = key
                        }
                    }
                }
                queue.consume(attempted: attempted)
                // Concurrent changes: some blocked keys become admissible, some admissible become blocked.
                for _ in 0..<3 {
                    let key = keys[Int(rng.next() % UInt64(keys.count))]
                    if state[key] == 1 {
                        state[key] = 0
                    } else if state[key] == 0, key != pendingLead {
                        state[key] = 1
                    }
                }
            }
            // Liveness: nothing left admissible after the cursor ran out, except keys re-admitted behind the cursor.
            #expect(state.values.allSatisfy { $0 != 2 }, "round \(round): a key left in deleting")
        }
    }
}

/// A small deterministic generator for the probe.
struct SplitMix {
    var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
