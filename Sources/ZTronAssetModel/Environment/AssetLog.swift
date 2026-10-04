import os

/// The module's logging (R-OBS-1): subsystem `com.ztron.assetkit`, one `os.Logger` and one `OSSignposter` per
/// category (`store`, `sync`, `transport`, `apple`).
///
/// It lives in the Model, below every target, so Storage, Sync, Transport and AppleHosted log under their own
/// category without restating the subsystem. Every line goes through a `LogSink` **and** the environment's optional
/// `LogTap` (ADR-047): `.live()` installs `OSLogSink`, the only code that writes to the unified log, and every test
/// environment uses `TapOnlyLogSink`, so a test never persists a line outside this repository (owner directive) while
/// the tap still sees exactly what the unified log would receive. Immutable configuration only (`static let` of a
/// `String`; loggers are created per call, which is cheap), so no global mutable state.
///
/// Privacy (ADR-043): a line is rendered by the caller with identifiers passed through `hashed(_:)` and never a
/// secret (`AppKey` redacts itself anyway), then logged as one `.public` string, so the tapped line is exactly what
/// the unified log receives. Signpost intervals (`plan`, `transfer`, `verify`, `commit`, `gc`, `eviction`) are taken
/// from `LogSink.signposter(_:)`, which is `nil` for the test sink.
public enum AssetLog {
    /// The subsystem of every logger and signposter.
    public static let subsystem = "com.ztron.assetkit"

    /// The `os.Logger` of a category. Only `OSLogSink` writes through it; production code logs through a
    /// `LogRoute`, so tests never reach the unified log (ADR-047).
    public static func logger(_ category: LogCategory) -> Logger {
        Logger(subsystem: AssetLog.subsystem, category: category.rawValue)
    }

    /// The `OSSignposter` of a category. Production code obtains it through `LogSink.signposter(_:)` (`nil` in
    /// tests), never directly (ADR-047).
    public static func signposter(_ category: LogCategory) -> OSSignposter {
        OSSignposter(subsystem: AssetLog.subsystem, category: category.rawValue)
    }

    /// An identifier as it may appear in a log line: `id#` plus 16 hex digits of its stable FNV-1a hash, never the
    /// identifier itself (R-OBS-1 "identifiers hashed"; stable across processes, so support can correlate lines).
    public static func hashed(_ id: AssetID) -> String {
        let hex = String(StableHash.fnv1a64(id.rawValue), radix: 16)
        return "id#" + String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    /// Writes one rendered line to `sink` (the unified log in `.live()`, nothing in tests) and to `tap`. The caller
    /// rendered identifiers with `hashed(_:)` and interpolated no secret. Never blocks beyond `os_log`.
    public static func emit(_ line: LogLine, sink: any LogSink, tap: (any LogTap)?) {
        sink.write(line)
        tap?.record(line)
    }

    /// Renders and emits a line under the module's subsystem.
    public static func log(
        _ category: LogCategory,
        _ level: LogLevel,
        _ message: String,
        sink: any LogSink,
        tap: (any LogTap)?
    ) {
        AssetLog.emit(LogLine(category: category, level: level, message: message), sink: sink, tap: tap)
    }
}

/// Where rendered log lines are written (R-OBS-1, ADR-047): the seam that keeps tests out of the unified log.
///
/// `.live()` installs `OSLogSink`; an environment built from explicit conformers defaults to `TapOnlyLogSink`, so a
/// test that forgets the sink still writes nothing outside this repository (owner directive). `write` runs on the
/// caller (actor, delegate queue), so it must not block beyond `os_log`.
public protocol LogSink: Sendable {
    /// Writes one rendered line.
    func write(_ line: LogLine)
    /// The signposter for a category's intervals, or `nil` when this sink emits no signposts (tests).
    func signposter(_ category: LogCategory) -> OSSignposter?
}

/// The live sink: the unified log, one `.public` string per line under the line's subsystem and category
/// (ADR-043). Named only by `AssetEnvironment.live()` (ADR-038).
public struct OSLogSink: LogSink {
    /// Creates the sink (stateless).
    public init() {}

    /// Logs the line at its level.
    public func write(_ line: LogLine) {
        let logger = Logger(subsystem: line.subsystem, category: line.category.rawValue)
        logger.log(level: line.level.osLogType, "\(line.message, privacy: .public)")
    }

    /// The category's signposter.
    public func signposter(_ category: LogCategory) -> OSSignposter? {
        AssetLog.signposter(category)
    }
}

/// The test sink: writes nothing, so lines reach only the environment's `LogTap` (ADR-047). The default of
/// `AssetEnvironment.init`, so every environment a test assembles keeps the unified log untouched.
public struct TapOnlyLogSink: LogSink {
    /// Creates the sink (stateless).
    public init() {}

    /// Drops the line: the tap (if any) already receives it through `AssetLog.emit`.
    public func write(_ line: LogLine) {}

    /// No signposts in tests.
    public func signposter(_ category: LogCategory) -> OSSignposter? {
        nil
    }
}

/// A sink and an optional tap as one value (ADR-047): how the environment's logging reaches the layers built from
/// it (`StoreEnvironment.log`, `RemoteSourceFactory.makeRemoteSource(configuration:staging:log:)`).
public struct LogRoute: Sendable {
    /// Where lines are written.
    public let sink: any LogSink
    /// Who also receives every line (tests); `nil` in `.live()`.
    public let tap: (any LogTap)?

    /// Creates a route.
    public init(sink: any LogSink, tap: (any LogTap)? = nil) {
        self.sink = sink
        self.tap = tap
    }

    /// A route whose lines reach only `tap` (tests).
    public static func tapOnly(_ tap: (any LogTap)?) -> LogRoute {
        LogRoute(sink: TapOnlyLogSink(), tap: tap)
    }

    /// Emits one rendered line to the sink and the tap.
    public func emit(_ line: LogLine) {
        AssetLog.emit(line, sink: self.sink, tap: self.tap)
    }

    /// Renders and emits a line under the module's subsystem.
    public func log(_ category: LogCategory, _ level: LogLevel, _ message: String) {
        self.emit(LogLine(category: category, level: level, message: message))
    }

    /// The sink's signposter for `category`, `nil` in tests.
    public func signposter(_ category: LogCategory) -> OSSignposter? {
        self.sink.signposter(category)
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
