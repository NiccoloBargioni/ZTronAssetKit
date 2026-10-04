/// The heap a decoded manifest occupies, estimated from counts before anything is built (R-MAN-3, ADR draft A-8).
///
/// The survey pass of `ManifestDecoder.decode` counts every string and array the build pass will materialise;
/// these functions turn the counts into bytes with Swift's native layouts on 64-bit Apple platforms (stable ABI):
/// a string of more than 15 UTF-8 bytes is a heap object with a 32-byte header, its bytes and a terminating NUL
/// (smaller strings live inline); an array is a 32-byte header plus its elements; a dictionary or set is one
/// allocation holding a power-of-two table at most three quarters full. Every allocation is rounded up to the block
/// Apple's allocator serves it from (`allocated(_:)`). The build pass reserves exactly the counted capacities, so no
/// growth copy adds to the peak.
enum ManifestFootprint {
    /// The most the estimate may reach: three times the payload, 75 % of R-MAN-3's bound, never below
    /// `floorBytes`. The model bounds the blocks the decoder's requests are served from, as `malloc_good_size`
    /// reports them. Inside a process that freed large blocks before, the allocator's in-use figure can read more:
    /// a buffer of a few MiB may be served from a larger cached free block, which counts whole (measured in fix
    /// round 2: a freed block is reused for requests down to about two thirds of its size, so a 2.75 MiB entry array
    /// read as 3 MiB; memory the process already held, so its footprint does not grow), and other threads allocate
    /// meanwhile; the 25 % headroom is for that (ADR draft A-8). The floor exists because the fixed costs of a
    /// one-entry manifest are several times its few dozen bytes.
    static func limit(payloadBytes: Int) -> Int {
        max(3 * payloadBytes, ManifestFootprint.floorBytes)
    }

    /// The smallest limit: 64 KiB.
    static let floorBytes = 64 * 1_024

    /// The heap bytes of one native string of `utf8Count` bytes.
    static func string(utf8Count: Int) -> Int {
        utf8Count <= 15 ? 0 : ManifestFootprint.allocated(32 + utf8Count + 1)
    }

    /// The heap bytes of an array of `count` elements of `stride` bytes, reserved exactly.
    static func array(count: Int, stride: Int) -> Int {
        count == 0 ? 0 : ManifestFootprint.allocated(32 + count * stride)
    }

    /// The heap bytes of a native dictionary or set reserved for `count` elements of `stride` bytes (key plus value):
    /// a header, an occupancy bitmap and the buckets, in one allocation.
    static func table(count: Int, stride: Int) -> Int {
        guard count > 0 else {
            return 0
        }
        var buckets = 1
        while buckets * 3 / 4 < count {
            buckets *= 2
        }
        return ManifestFootprint.allocated(64 + buckets / 8 + buckets * stride)
    }

    /// The block Apple's allocators hand out for a request of `bytes`, rounded to the coarser of their two designs
    /// so that the estimate is an upper bound under either (ADR draft A-8):
    /// - the segregated-size-class allocator (the default on this host, macOS 27): 16-byte steps up to 128 bytes,
    ///   then four size classes per power of two (up to 256 in steps of 32, up to 512 in steps of 64, up to 1,024
    ///   in steps of 128, …), so a 544-byte array of 32 strings takes a 640-byte block;
    /// - the magazine allocator: 16-byte quanta up to 1,008 bytes (nano and tiny) and 512-byte quanta up to
    ///   15 KiB (small), so a 1,056-byte tag array takes a 1,536-byte block.
    ///
    /// Above 15 KiB both use page-granular or coarser blocks (16 KiB pages, medium 32 KiB quanta); every such
    /// request is rounded up to a multiple of 32 KiB. `R-MAN-3: the allocation estimate rounds every request at
    /// least as coarsely as this host's allocator` checks the bound against `malloc_good_size`.
    static func allocated(_ bytes: Int) -> Int {
        guard bytes > 128 else {
            return (bytes + 15) & ~15
        }
        guard bytes <= 15 * 1_024 else {
            return (bytes + 32_767) & ~32_767
        }
        // Four classes per power of two: the step is a quarter of the largest power of two below `bytes`.
        let step = (1 << (Int.bitWidth - 1 - (bytes - 1).leadingZeroBitCount)) / 4
        let sizeClass = (bytes + step - 1) / step * step
        let magazine = bytes <= 1_008 ? (bytes + 15) & ~15 : (bytes + 511) & ~511
        return max(sizeClass, magazine)
    }
}

/// What the survey pass counted: enough to reserve every buffer exactly and to estimate the peak heap.
struct ManifestSurvey {
    /// Entries that pass every per-entry rule and, under `.keepFirst`, do not repeat an accepted identifier.
    var acceptedCount = 0
    /// Elements the build quarantines: per-entry violations, elements that are not objects, and under `.keepFirst`
    /// repeats of an accepted identifier.
    var quarantinedCount = 0
    /// Quarantined entries whose identifier is valid, under `.reject` only: the build remembers them to reject a
    /// later repeat.
    var quarantinedIdentifierCount = 0
    /// Heap bytes of every string and string array the build pass materialises, quarantined drafts included.
    var materializedBytes = 0
    /// The longest escaped string the build pass decodes: its decoded copy is a transient next to the string.
    var largestEscapedString = 0

    /// The estimated peak heap of the build pass.
    var estimatedBytes: Int {
        self.materializedBytes
            + ManifestFootprint.array(count: self.acceptedCount, stride: MemoryLayout<ManifestEntry>.stride)
            + ManifestFootprint.table(count: self.acceptedCount, stride: MemoryLayout<AssetID>.stride + MemoryLayout<Int>.stride)
            + ManifestFootprint.array(count: self.quarantinedCount, stride: MemoryLayout<QuarantinedEntry>.stride)
            + ManifestFootprint.table(count: self.quarantinedIdentifierCount, stride: MemoryLayout<AssetID>.stride)
            + ManifestFootprint.array(count: self.largestEscapedString, stride: 1)
    }
}
