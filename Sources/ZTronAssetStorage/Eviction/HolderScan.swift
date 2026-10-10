import ZTronAssetModel

/// The holders of the blobs one actor turn re-validates, found by at most one scan of every record (C2; review of the L3
/// close-out cycle 4).
///
/// `holders(of:known:scan:)` re-reads the ids a selection saw in O(ids). Only when they no longer account for every
/// reference the blob table counts (an id bound to the blob after the selection, such as an alias or a renamed id, or the
/// provisional reference of a publication in flight) does it need the records themselves. A turn that re-validates many
/// blobs (an eviction chunk, `apply`'s eviction plan, a purge chunk, a quarantine) shares one `HolderScan`: the first blob
/// that needs the records scans them once for every blob of the turn, and the others read that result. One scan per blob
/// held the actor about 1.7 s for an eviction chunk of 1,000 candidates at 10,000 records, and 4.3 s for `apply`'s
/// eviction of a plan of half after a rename. The scan collects only the turn's blobs, so it costs one pass over the
/// records whatever their number (a full reference index also builds an entry per blob: 45 ms at `maxEntries`).
///
/// Valid for one actor turn in which records only lose references to these blobs: eviction, purge and quarantine take
/// records off them and bind none, so a holder the scan found is re-read before it is returned, and none can be missing.
struct HolderScan: Sendable {
    /// The blobs the turn re-validates; a set is built from them only when a scan is needed.
    private let blobs: [BlobKey]
    /// The blobs the scans of this turn covered.
    private var covered: Set<BlobKey> = []
    /// The records referencing each covered blob when it was scanned.
    private var found: [BlobKey: [AssetID]] = [:]

    /// A scan for a turn that re-validates `blobs`.
    init(blobs: [BlobKey]) {
        self.blobs = blobs
    }

    /// Whether a scan of this turn covered `key`.
    func covers(_ key: BlobKey) -> Bool {
        self.covered.contains(key)
    }

    /// Scans `records` once for the holders of every blob of the turn and of `key`; after a first scan, of `key` alone (a
    /// caller that re-validates a blob it did not name pays a scan of its own, still correct).
    mutating func scan(_ records: [AssetID: AssetRecord], for key: BlobKey) {
        var wanted: Set<BlobKey> = self.covered.isEmpty ? Set(self.blobs) : []
        wanted.insert(key)
        // By index, reading only each record's residency: iterating the pairs copies every record whole.
        var index = records.startIndex
        if wanted.count == 1 {
            // One blob (a quarantine, a verified blob): an equality test per record is cheaper than a hash.
            while index != records.endIndex {
                if records.values[index].referencedBlob == key {
                    self.found[key, default: []].append(records.keys[index])
                }
                records.formIndex(after: &index)
            }
        } else {
            // A record whose blob's bit is clear is skipped without hashing its key (a hash per record doubled the
            // scan: 12.8 ms instead of 7.9 at `maxEntries`).
            let filter = HolderScan.Prefilter(wanted)
            while index != records.endIndex {
                if let blob = records.values[index].referencedBlob, filter.mayContain(blob), wanted.contains(blob) {
                    self.found[blob, default: []].append(records.keys[index])
                }
                records.formIndex(after: &index)
            }
        }
        self.covered.formUnion(wanted)
    }

    /// The records the scan found referencing `key` (a covered blob); some may have lost the reference since.
    func holders(of key: BlobKey) -> [AssetID] {
        self.found[key] ?? []
    }

    /// One bit per slot of a blob's first hash word (uniform: SHA-256), at least 16 slots per wanted blob: a clear bit
    /// proves a blob is not wanted; a set one is checked against the set (about 6 % of the others pass).
    struct Prefilter: Sendable {
        /// The bits, 64 slots per word.
        private var words: [UInt64]
        /// The slot count minus one (a power of two).
        private let mask: UInt64

        /// A filter of `keys`.
        init(_ keys: Set<BlobKey>) {
            var slots = 1 << 12
            while slots < keys.count * 16 {
                slots <<= 1
            }
            self.mask = UInt64(slots - 1)
            self.words = Array(repeating: 0, count: slots / 64)
            for key in keys {
                let slot = key.hash.w0 & self.mask
                self.words[Int(slot >> 6)] |= 1 << (slot & 63)
            }
        }

        /// False only for a blob that is not among the keys.
        func mayContain(_ key: BlobKey) -> Bool {
            let slot = key.hash.w0 & self.mask
            return self.words[Int(slot >> 6)] & (1 << (slot & 63)) != 0
        }
    }
}
