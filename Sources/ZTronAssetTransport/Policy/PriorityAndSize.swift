import Foundation
import ZTronAssetModel

extension AssetPriority {
    /// The `URLSessionTask.priority` of each lane (R-NET-10, ARCHITECTURE §7.5): `highPriority` (0.75) for
    /// user-initiated, `defaultPriority` (0.5) for prefetch, `lowPriority` (0.25) for bulk. A hint to URLSession;
    /// the engine's lanes are authoritative (H-4).
    public var urlSessionTaskPriority: Float {
        switch self {
        case .userInitiated:
            return URLSessionTask.highPriority
        case .prefetch:
            return URLSessionTask.defaultPriority
        case .bulk:
            return URLSessionTask.lowPriority
        }
    }
}

/// What the size guard decides for one chunk (R-NET-7).
public enum SizeVerdict: Sendable, Hashable {
    /// Keep receiving.
    case proceed
    /// More than the hard cap was announced or written: abort with `integrity(.oversize)`.
    case abortOversize
    /// More than the manifest's `byteSize` was written: abort with `integrity(.sizeMismatch)` without waiting for
    /// the rest (transport-1 TR1-8: `Content-Length` is unknown under compression, `byteSize` is not).
    case abortExceedsExpected
}

/// The pure size guard every received chunk passes through (R-NET-7, transport-1 TR1-8).
///
/// `written` is the partial file's size after the append (data tasks, ADR-019), `announced` the decoded length
/// the response announced (−1 or `nil` when unknown, which is always the case under a `Content-Encoding`),
/// `expected` the manifest's `byteSize`, `limit` the cap. The announced size gets a small slack
/// (`limit / 1024 + 64`) for an origin that reports an encoded length; the cap plus its slack saturates at the
/// bounds of `Int64`, because `limit` is public configuration (`Int64.max` may mean "unlimited") and Swift traps on
/// overflow (review round 3).
public enum SizeGuard {
    /// The verdict for the bytes seen so far.
    public static func verdict(written: Int64, announced: Int64?, expected: Int64?, limit: Int64) -> SizeVerdict {
        if written > limit {
            return .abortOversize
        }
        if let announced, announced >= 0, announced > Saturating.add(limit, limit / 1_024 + 64) {
            return .abortOversize
        }
        if let expected, written > expected {
            return .abortExceedsExpected
        }
        return .proceed
    }

    /// The cap a job is built with: a negative configured cap allows nothing, read as 0, so every figure compared
    /// with or derived from it stays in range.
    static func clampedLimit(_ limit: Int64) -> Int64 {
        max(limit, 0)
    }
}

extension TransferJob {
    /// The size a background task may be created for (R-NET-7): the manifest's `byteSize` when it is known, not
    /// negative and within the cap; `nil` otherwise, and the transfer runs in the foreground, whose size guard aborts
    /// while streaming. The OS downloads a background task whole, so only the staged size can be checked against it.
    /// A negative size would also be written into a task tag that `BackgroundTaskTag(decoding:)` refuses, so no
    /// callback could route the OS task and the next launch would cancel it as foreign (close-out probe VDC-H2). The
    /// bounds are compared one by one, never as a range, so a negative cap cannot trap. One rule for the source's
    /// routing and both coordinator entry points.
    var backgroundByteSize: Int64? {
        guard let expected = self.expectedBytes, expected >= 0, expected <= self.maxBytes else {
            return nil
        }
        return expected
    }
}
