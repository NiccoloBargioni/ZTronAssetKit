/// Saturating addition for the figures the transport receives from outside: a server's `Content-Length`, a
/// sidecar's resume offset read back from disk, and the size cap of public configuration (`maxAssetBytes`). Swift
/// traps on overflow in every build configuration, so a plain `+` on such a figure would let one response or one
/// configuration value end the process; saturating keeps an extreme value extreme (an announced length past
/// `Int64.max` still fails the size guard) and never traps (review round 3).
enum Saturating {
    /// `a + b`, clamped to `Int64.min…Int64.max`.
    static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard overflow else {
            return sum
        }
        // Overflow is possible only when both operands have the same sign, which is the direction of the bound.
        return b > 0 ? .max : .min
    }
}
