/// The heap a decoded manifest occupies, bounded from counts before anything is built (R-MAN-3, ADR draft A-8).
///
/// The survey pass of `ManifestDecoder.decode` counts every string and array the build pass will materialise;
/// these functions turn the counts into bytes with Swift's native layouts on 64-bit Apple platforms (stable ABI):
/// a string of more than 15 UTF-8 bytes is a heap object with a 32-byte header, its bytes and a terminating NUL
/// (smaller strings live inline); an array is a 32-byte header plus its elements; a dictionary or set is one
/// allocation holding a header, an occupancy bitmap of whole words and a power-of-two table at most three quarters
/// full. Every allocation is rounded up to the most heap the allocator's in-use figure can count for it
/// (`allocated(_:)`), the reuse of larger cached blocks included. The build pass reserves exactly the counted
/// capacities, so no growth copy adds to the peak. The estimate is therefore an upper bound of the heap the decode
/// adds, as `malloc_zone_statistics` counts it, whatever the process freed before.
enum ManifestFootprint {
    /// The most the estimate may reach: 3.75 times the payload, with no floor. R-MAN-3 allows four times the
    /// payload; the estimate already bounds the worst the allocator can do, and the remaining 6.25 % is kept for what
    /// a process-wide measurement adds to a decode (another thread's allocations while it runs). Without a floor, a
    /// payload of a few bytes is held to the same ratio: one minimal entry (82 bytes) needs 192 bytes, while a
    /// payload of invalid elements keeps only the diagnostics the bound leaves room for (`diagnosticCapacity`).
    static func limit(payloadBytes: Int) -> Int {
        payloadBytes / 4 * 15 + payloadBytes % 4 * 15 / 4
    }

    /// The heap bytes of one native string of `utf8Count` bytes.
    static func string(utf8Count: Int) -> Int {
        utf8Count <= 15 ? 0 : ManifestFootprint.allocated(32 + utf8Count + 1)
    }

    /// The heap bytes of an array of `count` elements of `stride` bytes, reserved exactly.
    static func array(count: Int, stride: Int) -> Int {
        count <= 0 ? 0 : ManifestFootprint.allocated(32 + count * stride)
    }

    /// The heap bytes of a native dictionary or set reserved for `count` elements of `stride` bytes (key plus value):
    /// a header of at most 64 bytes, an occupancy bitmap of whole 64-bit words and the buckets, in one allocation
    /// (fix round 3: the bitmap was counted in bits, so a table of fewer than 64 buckets was estimated one word
    /// short; four buckets of `AssetID` and `Int` request 168 bytes, a 192-byte block, not 160).
    static func table(count: Int, stride: Int) -> Int {
        guard count > 0 else {
            return 0
        }
        var buckets = 2
        while buckets * 3 / 4 < count {
            buckets *= 2
        }
        return ManifestFootprint.allocated(64 + (buckets + 63) / 64 * 8 + buckets * stride)
    }

    /// The identifier index of `ValidatedManifest` for `count` accepted entries: none up to
    /// `ValidatedManifest.linearLookupLimit` entries, which are found by a linear scan, else a dictionary of
    /// `AssetID` to position.
    static func index(count: Int) -> Int {
        guard count > ValidatedManifest.linearLookupLimit else {
            return 0
        }
        return ManifestFootprint.table(count: count, stride: MemoryLayout<AssetID>.stride + MemoryLayout<Int>.stride)
    }

    /// The largest request the allocator is known to serve at exactly its good size: 2 MiB. A larger request may be
    /// served from a cached free block of up to twice its size, which the in-use figure then counts whole.
    static let largeRequestThreshold = 2 * 1_024 * 1_024

    /// The most heap Apple's allocators count for a request of `bytes` (ADR draft A-8):
    /// - up to 2 MiB, the block it is served from, rounded to the coarser of the two allocator designs so the
    ///   estimate bounds either. The segregated-size-class allocator (this host, macOS 27) uses 16-byte steps up to
    ///   128 bytes, then four size classes per power of two (up to 256 in steps of 32, up to 512 in steps of 64, …),
    ///   so a 544-byte array of 32 strings takes a 640-byte block; the magazine allocator uses 16-byte quanta up to
    ///   1,008 bytes and 512-byte quanta up to 15 KiB, so a 1,056-byte tag array takes 1,536 bytes; above 15 KiB
    ///   both are page-granular or coarser (16 KiB pages, 32 KiB medium quanta), rounded here to 32 KiB. A request
    ///   of at most 2 MiB measured exactly its `malloc_good_size` whatever was freed before (fix round 3);
    /// - above 2 MiB, twice the request rounded to 32 KiB: a freed block of B bytes is cached and serves any later
    ///   request of more than B / 2 bytes, counting B (fix round 3, measured in fresh processes for B from 2 MiB to
    ///   32 MiB; verifier round 3 saw a 14,400,032-byte entry array counted as 25,165,824 bytes).
    ///
    /// `R-MAN-3: the allocation estimate rounds every request at least as coarsely as this host's allocator` checks
    /// the bound against `malloc_good_size`; the fuzz test's limit cases make the allocator reuse blocks twice the
    /// size of the decoder's largest requests and measure the result.
    static func allocated(_ bytes: Int) -> Int {
        guard bytes > 128 else {
            return (bytes + 15) & ~15
        }
        guard bytes <= 15 * 1_024 else {
            let pages = (bytes + 32_767) & ~32_767
            return bytes > ManifestFootprint.largeRequestThreshold ? 2 * pages : pages
        }
        // Four classes per power of two: the step is a quarter of the largest power of two below `bytes`.
        let step = (1 << (Int.bitWidth - 1 - (bytes - 1).leadingZeroBitCount)) / 4
        let sizeClass = (bytes + step - 1) / step * step
        let magazine = bytes <= 1_008 ? (bytes + 15) & ~15 : (bytes + 511) & ~511
        return max(sizeClass, magazine)
    }

    /// How many quarantine diagnostics the build keeps, and how many bytes their identifier strings may take: the
    /// first `min(quarantinedCount, maxDiagnostics)`, fewer only when their array would not fit in the `room` the
    /// estimate leaves below the limit. So diagnostics never push a manifest over the allocation bound (orchestrator
    /// decision 2, fix round 3): a payload of a few hundred bytes of invalid elements keeps fewer diagnostics than
    /// `ManifestLimits.maxQuarantineDiagnostics`, never more heap than the bound.
    static func diagnosticCapacity(quarantinedCount: Int, maxDiagnostics: Int, room: Int) -> (count: Int, stringBytes: Int) {
        let stride = MemoryLayout<QuarantinedEntry>.stride
        var high = min(quarantinedCount, max(0, maxDiagnostics), max(0, room) / stride)
        var low = 0
        // The largest count whose array fits: `array(count:stride:)` grows with the count.
        while low < high {
            let middle = (low + high + 1) / 2
            if ManifestFootprint.array(count: middle, stride: stride) <= room {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return (low, room - ManifestFootprint.array(count: low, stride: stride))
    }
}

/// What the survey pass counted: enough to reserve every buffer exactly and to bound the build pass's heap.
struct ManifestSurvey {
    /// Entries that pass every per-entry rule and, under `.keepFirst`, do not repeat an accepted identifier.
    var acceptedCount = 0
    /// Elements the build quarantines: per-entry violations, elements that are not objects, and under `.keepFirst`
    /// repeats of an accepted identifier.
    var quarantinedCount = 0
    /// Heap bytes of the strings and string arrays of the accepted entries.
    var acceptedBytes = 0
    /// The largest transient allocation of the build pass, alive next to everything counted: the decoded copy of an
    /// escaped string (validated or materialised), or under `.keepFirst` the identifier string of an entry looked up
    /// and then quarantined.
    var transientBytes = 0
    /// The container stack's overflow, which both passes reserve once if a skipped value nests deeper than 64 levels
    /// (possible only when `maxNestingDepth` is raised above its default of 64).
    var stackBytes = 0

    /// The estimated peak heap of the build pass, its diagnostics aside (`ManifestFootprint.diagnosticCapacity`).
    var estimatedBytes: Int {
        self.acceptedBytes
            + ManifestFootprint.array(count: self.acceptedCount, stride: MemoryLayout<ManifestEntry>.stride)
            + ManifestFootprint.index(count: self.acceptedCount)
            + self.transientBytes
            + self.stackBytes
    }

    /// Records a transient allocation of `bytes`.
    mutating func noteTransient(_ bytes: Int) {
        self.transientBytes = max(self.transientBytes, bytes)
    }
}

/// What the build pass reserves and keeps: the survey's counts, and the diagnostics the allocation bound has room for.
struct ManifestBuildPlan {
    /// The survey's counts.
    var survey: ManifestSurvey
    /// How many diagnostics the build keeps at most (the quarantine array's capacity).
    var diagnosticCapacity: Int
    /// The heap the kept diagnostics' identifier strings may take; the first diagnostic whose identifier would not
    /// fit ends the kept prefix.
    var diagnosticStringBytes: Int
}
