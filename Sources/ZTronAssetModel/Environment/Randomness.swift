/// The module's only source of randomness (R-ENV-1, ADR-024): one 64-bit seed per environment.
///
/// Everything random is derived from the seed with pure functions keyed by *what* is drawn (asset, attempt,
/// trip), never by the order in which actors happen to draw (sync-2 S2-16). A failing test prints its seed and
/// replays exactly.
public protocol RandomSource: Sendable {
    /// The seed every derived value comes from.
    var seed: UInt64 { get }
}

/// The live source: a seed from `SystemRandomNumberGenerator`, drawn once at construction.
public struct SystemRandomSource: RandomSource {
    /// The drawn seed.
    public let seed: UInt64

    /// Draws a seed from the system generator.
    public init() {
        var generator = SystemRandomNumberGenerator()
        self.seed = generator.next()
    }
}

/// SplitMix64: a tiny, fast, well-mixed generator for derived streams (property tests, store identity).
public struct SplitMix64: RandomNumberGenerator, Sendable, Hashable {
    /// The current state.
    public private(set) var state: UInt64

    /// Starts a stream at `seed`.
    public init(seed: UInt64) {
        self.state = seed
    }

    /// The next 64 random bits.
    public mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        return SplitMix64.mix(self.state)
    }

    /// The SplitMix64 finaliser: a bijective mix of 64 bits.
    public static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Order-independent randomness: a pure function of (seed, key, counter) (sync-2 S2-16).
public enum KeyedRandom {
    /// 64 random bits for `key` and `counter` under `seed`.
    public static func next64(seed: UInt64, key: UInt64, counter: UInt64) -> UInt64 {
        SplitMix64.mix(SplitMix64.mix(seed ^ SplitMix64.mix(key)) ^ counter)
    }

    /// A value in `[0, 1)` for `key` and `counter` under `seed`.
    public static func unitInterval(seed: UInt64, key: UInt64, counter: UInt64) -> Double {
        Double(KeyedRandom.next64(seed: seed, key: key, counter: counter) >> 11) * 0x1.0p-53
    }
}
