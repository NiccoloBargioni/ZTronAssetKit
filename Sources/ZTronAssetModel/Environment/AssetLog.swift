import os

/// The module's logging (R-OBS-1): subsystem `com.ztron.assetkit`, one `os.Logger` and one `OSSignposter` per
/// category (`store`, `sync`, `transport`, `apple`).
///
/// It lives in the Model, below every target, so Storage, Sync, Transport and AppleHosted log under their own
/// category without restating the subsystem, and one helper writes every line to `os.Logger` **and** to the
/// environment's optional `LogTap`, which R-OBS-1 and R-SEC-1 tests assert on. Immutable configuration only
/// (`static let` of a `String`; loggers are created per call, which is cheap), so no global mutable state.
///
/// Privacy (ADR-043): a line is rendered by the caller with identifiers passed through `hashed(_:)` and never a
/// secret (`AppKey` redacts itself anyway), then logged as one `.public` string, so the tapped line is exactly what
/// the unified log receives. Signpost intervals: `plan`, `transfer`, `verify`, `commit`, `gc`, `eviction`.
public enum AssetLog {
    /// The subsystem of every logger and signposter.
    public static let subsystem = "com.ztron.assetkit"

    /// The `os.Logger` of a category.
    public static func logger(_ category: LogCategory) -> Logger {
        Logger(subsystem: AssetLog.subsystem, category: category.rawValue)
    }

    /// The `OSSignposter` of a category (intervals: plan, transfer, verify, commit, gc, eviction).
    public static func signposter(_ category: LogCategory) -> OSSignposter {
        OSSignposter(subsystem: AssetLog.subsystem, category: category.rawValue)
    }

    /// An identifier as it may appear in a log line: `id#` plus 16 hex digits of its stable FNV-1a hash, never the
    /// identifier itself (R-OBS-1 "identifiers hashed"; stable across processes, so support can correlate lines).
    public static func hashed(_ id: AssetID) -> String {
        let hex = String(StableHash.fnv1a64(id.rawValue), radix: 16)
        return "id#" + String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    /// Writes one rendered line to its category's `os.Logger` (as a single `.public` string: the caller rendered
    /// identifiers with `hashed(_:)` and interpolated no secret) and to `tap`. Never blocks beyond `os_log`.
    public static func emit(_ line: LogLine, tap: (any LogTap)?) {
        let logger = Logger(subsystem: line.subsystem, category: line.category.rawValue)
        logger.log(level: line.level.osLogType, "\(line.message, privacy: .public)")
        tap?.record(line)
    }

    /// Renders and emits a line under the module's subsystem.
    public static func log(_ category: LogCategory, _ level: LogLevel, _ message: String, tap: (any LogTap)?) {
        AssetLog.emit(LogLine(category: category, level: level, message: message), tap: tap)
    }
}

extension LogLevel {
    /// The unified-logging type of this level.
    public var osLogType: OSLogType {
        switch self {
        case .debug:
            return .debug
        case .info:
            return .info
        case .error:
            return .error
        case .fault:
            return .fault
        }
    }
}
