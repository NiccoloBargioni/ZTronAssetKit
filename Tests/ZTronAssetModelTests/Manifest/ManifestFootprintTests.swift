import Darwin
import Testing
@testable import ZTronAssetModel

extension ModelSuites {
    /// R-MAN-3's allocation estimate (ADR draft A-8) against the allocator it models. The decoder rejects a manifest
    /// whose estimate exceeds three times the payload, so the estimate must never be finer than the blocks the
    /// allocator really hands out: the model of fix round 1 rounded a 544-byte array to 544 bytes while this host's
    /// allocator serves 640, and accepted a payload estimated at 3.0x that measured 3.49x.
    @Suite("Manifest footprint")
    struct ManifestFootprintTests {
        /// Apple's allocator only: Thread Sanitizer replaces it, as the heap assertions of the fuzz test note.
        @Test(
            "R-MAN-3: the allocation estimate rounds every request at least as coarsely as this host's allocator",
            .enabled(if: !DecodeMeasurement.underThreadSanitizer)
        )
        func estimateBoundsTheAllocatorsBlocks() {
            var sizes = Array(1...65_536)
            sizes += Array(stride(from: 65_537, through: 4 << 20, by: 509))
            sizes += [8 << 20, (8 << 20) + 1, 14_400_032, 16 << 20, (16 << 20) + 1, 32 << 20, (32 << 20) + 1, 64 << 20]
            var finer: [(request: Int, estimated: Int, served: Int)] = []
            for size in sizes {
                let served = malloc_good_size(size)
                let estimated = ManifestFootprint.allocated(size)
                if estimated < served {
                    finer.append((size, estimated, served))
                }
            }
            #expect(finer.isEmpty, "\(finer.count) request sizes estimated below the block served, first: \(finer.prefix(8))")
            // The arrays the decoder sizes most often, just past a size-class boundary.
            #expect(ManifestFootprint.array(count: 32, stride: MemoryLayout<String>.stride) >= malloc_good_size(32 + 32 * 16))
            #expect(ManifestFootprint.array(count: 31, stride: MemoryLayout<String>.stride) >= malloc_good_size(32 + 31 * 16))
            // The coarser of Apple's two designs, the magazine allocator's included, which this host does not run:
            // 16-byte steps to 128 bytes, then four size classes per power of two (544 -> 640), 512-byte quanta from
            // 1,009 bytes to 15 KiB (1,056 -> 1,536), 32 KiB steps above.
            let model = [128, 129, 528, 544, 1_008, 1_009, 1_056, 2_100, 15_360, 15_361].map(ManifestFootprint.allocated)
            #expect(model == [128, 160, 640, 640, 1_024, 1_024, 1_536, 2_560, 16_384, 32_768])
            // Above 2 MiB a request may be served from a cached block of up to twice its size (fix round 3).
            #expect(ManifestFootprint.allocated(2 << 20) == 2 << 20)
            #expect(ManifestFootprint.allocated((2 << 20) + 1) == 2 * ((2 << 20) + 32_768))
            #expect(ManifestFootprint.allocated(14_400_032) == 2 * 14_417_920)
        }

        @available(macOS 15.0, *)
        @Test(
            "R-MAN-3: a request above 2 MiB is counted at least as large as the freed block the allocator reuses for it",
            .enabled(if: !DecodeMeasurement.underThreadSanitizer)
        )
        func estimateBoundsReusedBlocks() {
            // A freed block of B bytes is reused for a request of just over B / 2 (measured in fresh processes, ADR draft
            // A-8), the most it can add; whether this process reuses it here depends on its allocator state, so the check
            // is that the growth never exceeds the estimate, whichever block serves the request.
            for block in [3 << 20, 4 << 20, 8 << 20, 16 << 20, 29 << 20] {
                let request = block / 2 + 1
                var worst = 0
                for _ in 0..<3 {
                    let held = DecodeMeasurement.serveFromBlocksTwiceAsLarge([request])
                    let growth = DecodeMeasurement.retainedGrowth(runs: 1) { [UInt8](repeating: 1, count: request - 32) }
                    withExtendedLifetime(held) {}
                    worst = max(worst, growth)
                }
                print("R-MAN-3 reuse: a \(request)-byte request grew the heap by \(worst) B (\(Double(worst) / Double(request))x)")
                #expect(worst <= ManifestFootprint.allocated(request), "\(request): \(worst) > \(ManifestFootprint.allocated(request))")
            }
        }

        @Test(
            "R-MAN-3: the table estimate bounds the storage of a dictionary from AssetID to Int reserved for any count",
            .enabled(if: !DecodeMeasurement.underThreadSanitizer)
        )
        func tableEstimateBoundsDictionaries() {
            // Warm the dictionary type's runtime metadata, which is allocated once per process.
            var warm: [AssetID: Int] = [:]
            warm.reserveCapacity(1)
            withExtendedLifetime(warm) {}
            var under: [(count: Int, measured: Int, estimated: Int)] = []
            for count in Array(1...200) + [1_000, 10_000, 49_152, 49_153, 100_000] {
                let measured = DecodeMeasurement.retainedGrowth {
                    var table: [AssetID: Int] = [:]
                    table.reserveCapacity(count)
                    return table
                }
                let estimated = ManifestFootprint.table(count: count, stride: MemoryLayout<AssetID>.stride + MemoryLayout<Int>.stride)
                if measured > estimated {
                    under.append((count, measured, estimated))
                }
            }
            #expect(under.isEmpty, "\(under.count) counts estimated below their storage, first: \(under.prefix(8))")
            // The index is only built past the linear-lookup limit.
            #expect(ManifestFootprint.index(count: 8) == 0 && ManifestFootprint.index(count: 9) > 0)
        }
    }
}
