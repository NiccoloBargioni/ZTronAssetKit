import Foundation

/// A point on the monotonic clock, in nanoseconds (H-8, ADR-024).
///
/// Used for every in-process deadline (backoff, breaker cooldown, `Retry-After`, aging, progress throttle,
/// deletion grace, maintenance budgets). Never persisted: it is meaningless in another process. `Clock` and
/// `Duration` are iOS 16+, so this is a plain value (APPLE-API-VERIFICATION §3.1).
public struct MonotonicInstant: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// Nanoseconds since an unspecified origin.
    public let nanoseconds: UInt64

    /// Creates an instant.
    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    /// The origin.
    public static let zero = MonotonicInstant(nanoseconds: 0)

    /// `self + seconds`, saturating at `UInt64.max`.
    ///
    /// `+infinity` and any delta beyond the remaining headroom saturate to the end of time, so an "infinite"
    /// `deletionGrace`, cooldown or backoff means *never*, never *now* (conservative for I-3). Zero, negative and
    /// NaN deltas return `self`. The headroom comparison runs in the integer domain, so a delta within a few
    /// microseconds of the limit can never round past it and trap.
    public func adding(seconds: TimeInterval) -> MonotonicInstant {
        guard !seconds.isNaN, seconds > 0 else {
            return self
        }
        let delta = seconds * 1_000_000_000
        // 1.8e19 < 2^64 ≈ 1.8447e19, so every finite value below the guard converts to UInt64 exactly-or-below.
        guard delta.isFinite, delta < 1.8e19 else {
            return MonotonicInstant(nanoseconds: UInt64.max)
        }
        let (sum, overflow) = self.nanoseconds.addingReportingOverflow(UInt64(delta))
        return MonotonicInstant(nanoseconds: overflow ? UInt64.max : sum)
    }

    /// Seconds from `earlier` to `self`; 0 when `earlier` is later.
    public func seconds(since earlier: MonotonicInstant) -> TimeInterval {
        guard self.nanoseconds > earlier.nanoseconds else {
            return 0
        }
        return Double(self.nanoseconds - earlier.nanoseconds) / 1_000_000_000
    }

    /// Orders by time.
    public static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    /// `"<n>ns"`.
    public var description: String {
        "\(self.nanoseconds)ns"
    }
}

/// The module's only clock (R-ENV-1, H-8). `Date()`, `DispatchTime.now()` and `Task.sleep` appear only in
/// `LiveTimeSource`; tests use `ManualTimeSource` and never sleep (Q-4).
public protocol TimeSource: Sendable {
    /// Wall-clock time: only for values that outlive the process (sync stamp, LRU access stamps, reports).
    /// May jump in either direction; consumers tolerate that.
    func now() -> Date
    /// The monotonic clock: never decreases within a process, keeps counting while the device sleeps.
    func monotonicNow() -> MonotonicInstant
    /// The awake clock: never decreases within a process and **stops while the device sleeps**. Used only to
    /// measure the deletion grace (ADR-017, store-2 S2-14), so a suspended app does not lose its grace window.
    func uptimeNow() -> MonotonicInstant
    /// Suspends until `deadline` (returns at once if it passed); throws promptly when the task is cancelled.
    /// May return early or late: callers re-read `monotonicNow()` afterwards (REENTRANCY RE-S16).
    func sleep(until deadline: MonotonicInstant) async throws(CancellationError)
}

/// The live clock: `Date()`, `CLOCK_MONOTONIC`, `CLOCK_UPTIME_RAW` and `Task.sleep(nanoseconds:)`.
public struct LiveTimeSource: TimeSource {
    /// Creates the live clock (stateless).
    public init() {}

    /// `Date()`.
    public func now() -> Date {
        Date()
    }

    /// `clock_gettime_nsec_np(CLOCK_MONOTONIC)`, which counts during device sleep on Darwin.
    public func monotonicNow() -> MonotonicInstant {
        MonotonicInstant(nanoseconds: clock_gettime_nsec_np(CLOCK_MONOTONIC))
    }

    /// `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`, which stops while the device sleeps.
    public func uptimeNow() -> MonotonicInstant {
        MonotonicInstant(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    /// `Task.sleep(nanoseconds:)` until the deadline; cancellation is rethrown as `CancellationError`.
    public func sleep(until deadline: MonotonicInstant) async throws(CancellationError) {
        let now = self.monotonicNow()
        guard deadline > now else {
            return
        }
        do {
            try await Task.sleep(nanoseconds: deadline.nanoseconds - now.nanoseconds)
        } catch {
            throw CancellationError()
        }
    }
}
