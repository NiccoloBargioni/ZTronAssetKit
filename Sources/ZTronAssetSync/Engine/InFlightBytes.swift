/// The headroom ledger's bytes in flight (sync-2 S2-09): the sizes of the jobs in downloading ∪ verifying ∪
/// committing, kept as a running total so the ledger answers in O(1) per gated job. Summing every job for each job it
/// gated made a pump that parks many jobs, and every free-space read that re-checks them, quadratic in the jobs: 9.8 s
/// and 4.7 s in one actor turn at SPEC §6's 10,000 (review of close-out cycle 7, C2).
///
/// The total is two words wide, so it never saturates on the way: a removal undoes its addition exactly, and the value
/// the ledger reads is `min(total, Int64.max)`, the figure the saturating sum of the same sizes gave.
struct InFlightBytes: Hashable {
    /// Carries out of `low`.
    private var high: UInt64 = 0
    /// The low word.
    private var low: UInt64 = 0

    /// Counts a job that entered flight with `bytes` (negative sizes count as 0, as in the ledger).
    mutating func add(_ bytes: Int64) {
        let (sum, carry) = self.low.addingReportingOverflow(UInt64(max(0, bytes)))
        self.low = sum
        if carry {
            self.high &+= 1
        }
    }

    /// Uncounts a job that left flight with the `bytes` it was counted with.
    mutating func remove(_ bytes: Int64) {
        let (difference, borrow) = self.low.subtractingReportingOverflow(UInt64(max(0, bytes)))
        self.low = difference
        if borrow {
            self.high &-= 1
        }
    }

    /// The total, clamped to `Int64.max`.
    var clamped: Int64 {
        self.clamped(excluding: 0)
    }

    /// The total without one job's `bytes` (a job the ledger gates is not in flight against itself), clamped.
    func clamped(excluding bytes: Int64) -> Int64 {
        var rest = self
        rest.remove(bytes)
        guard rest.high == 0, rest.low <= UInt64(Int64.max) else {
            return Int64.max
        }
        return Int64(rest.low)
    }
}

extension Job {
    /// The bytes this job holds in the headroom ledger: its entry's size while it downloads, verifies or commits (an
    /// unknown size counts as 0), `nil` otherwise. `entry` never changes after creation, so a job leaves flight with the
    /// bytes it entered with.
    var ledgerBytes: Int64? {
        switch self.state {
        case .downloading, .verifying, .committing:
            return max(0, self.entry.byteSize ?? 0)
        case .queued, .failed, .blocked:
            return nil
        }
    }
}
