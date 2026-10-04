/// The heap a decoded manifest occupies, estimated from counts before anything is built (R-MAN-3, ADR draft A-8).
///
/// The survey pass of `ManifestDecoder.decode` counts every string and array the build pass will materialise;
/// these functions turn the counts into bytes with Swift's native layouts on 64-bit Apple platforms (stable ABI):
/// a string of more than 15 UTF-8 bytes is a heap object with a 32-byte header, its bytes and a terminating NUL
/// (smaller strings live inline); an array is a 32-byte header plus its elements; a dictionary is a power-of-two
/// table at most three quarters full. Every allocation is rounded up to the 16-byte malloc quantum. The build pass
/// reserves exactly the counted capacities, so no growth copy adds to the peak.
enum ManifestFootprint {
    /// The most the estimate may reach: three times the payload, 75 % of R-MAN-3's bound, never below
    /// `floorBytes`. The model matches the decoder's allocations byte for byte when measured alone; inside a busy
    /// test process the allocator's in-use figure reads up to 27 % more (size classes above 128 bytes, other
    /// threads), and the 25 % headroom covers that (ADR draft A-8). The floor exists because the fixed costs of a
    /// one-entry manifest are several times its few dozen bytes.
    static func limit(payloadBytes: Int) -> Int {
        max(3 * payloadBytes, ManifestFootprint.floorBytes)
    }

    /// The smallest limit: 64 KiB.
    static let floorBytes = 64 * 1_024

    /// The heap bytes of one native string of `utf8Count` bytes.
    static func string(utf8Count: Int) -> Int {
        utf8Count <= 15 ? 0 : ManifestFootprint.rounded(32 + utf8Count + 1)
    }

    /// The heap bytes of an array of `count` elements of `stride` bytes, reserved exactly.
    static func array(count: Int, stride: Int) -> Int {
        count == 0 ? 0 : ManifestFootprint.rounded(32 + count * stride)
    }

    /// The heap bytes of the identifier index (`[AssetID: Int]`) reserved for `count` entries.
    static func index(count: Int) -> Int {
        guard count > 0 else {
            return 0
        }
        var buckets = 1
        while buckets * 3 / 4 < count {
            buckets *= 2
        }
        let perBucket = MemoryLayout<AssetID>.stride + MemoryLayout<Int>.stride
        return ManifestFootprint.rounded(64 + buckets / 8 + buckets * perBucket)
    }

    private static func rounded(_ bytes: Int) -> Int {
        (bytes + 15) & ~15
    }
}

/// What the survey pass counted: enough to reserve every buffer exactly and to estimate the peak heap.
struct ManifestSurvey {
    /// Entries that pass every per-entry rule (duplicates are found only by the build pass).
    var acceptedCount = 0
    /// Entries quarantined by a per-entry rule.
    var quarantinedCount = 0
    /// Heap bytes of every string and string array the build pass materialises, quarantined drafts included.
    var materializedBytes = 0
    /// The longest escaped string the build pass decodes: its decoded copy is a transient next to the string.
    var largestEscapedString = 0

    /// The estimated peak heap of the build pass.
    var estimatedBytes: Int {
        self.materializedBytes
            + ManifestFootprint.array(count: self.acceptedCount, stride: MemoryLayout<ManifestEntry>.stride)
            + ManifestFootprint.index(count: self.acceptedCount)
            + ManifestFootprint.array(count: self.quarantinedCount, stride: MemoryLayout<QuarantinedEntry>.stride)
            + ManifestFootprint.index(count: self.quarantinedCount)
            + ManifestFootprint.array(count: self.largestEscapedString, stride: 1)
    }
}
