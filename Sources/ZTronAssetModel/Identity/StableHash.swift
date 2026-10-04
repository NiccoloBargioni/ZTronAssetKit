/// FNV-1a 64-bit: a hash that is identical in every process and on every platform.
///
/// Swift's `Hasher` is seeded per process, so anything that must be reproducible from a printed seed — keyed
/// backoff jitter (ADR-024, sync-2 S2-16) and deterministic test schedules — hashes with this instead.
/// It is not a cryptographic hash and is never used for content identity.
public enum StableHash {
    /// The FNV-1a 64-bit offset basis.
    public static let offsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325

    /// The FNV-1a 64-bit prime.
    public static let prime: UInt64 = 0x0000_0100_0000_01B3

    /// Hashes a byte sequence, continuing from `seed` (the offset basis by default).
    public static func fnv1a64<Bytes: Sequence>(_ bytes: Bytes, seed: UInt64 = StableHash.offsetBasis) -> UInt64
    where Bytes.Element == UInt8 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* StableHash.prime
        }
        return hash
    }

    /// Hashes the UTF-8 bytes of `text`.
    public static func fnv1a64(_ text: String) -> UInt64 {
        StableHash.fnv1a64(text.utf8)
    }
}
