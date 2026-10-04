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

/// The six signpost intervals of R-OBS-1. Each operation that owns one wraps itself in
/// `LogRoute.interval(_:category:_:)` (ARCHITECTURE §13.5 item 2): plan (sync), transfer (transport, apple), verify
/// and commit (store), gc and eviction (store cleanup).
public enum LogIntervalName: String, Sendable, Hashable, CaseIterable, Codable {
    /// Planning a sync run.
    case plan
    /// One transfer from first byte to its terminal update.
    case transfer
    /// Verifying a staged file (size and streaming hash).
    case verify
    /// One index commit.
    case commit
    /// Garbage collection (orphans, staging).
    case gc
    /// Quota eviction.
    case eviction
}

/// One edge of a signpost interval as the `LogTap` sees it (R-OBS-1): the signpost itself goes to the sink's
/// signposter, which tests do not have, so this event is how a test asserts that an operation was wrapped.
public struct LogIntervalEvent: Sendable, Hashable {
    /// Whether the interval began or ended.
    public enum Phase: String, Sendable, Hashable, CaseIterable {
        /// `LogRoute.interval(_:category:_:)` was called.
        case began
        /// `LogInterval.end()` was called.
        case ended
    }

    /// The subsystem: `AssetLog.subsystem` for intervals the module emits.
    public var subsystem: String
    /// The category the interval is signposted under.
    public var category: LogCategory
    /// Which interval.
    public var name: LogIntervalName
    /// Which edge.
    public var phase: Phase
    /// The rendered detail given when the interval began (identifiers hashed, no secret); both edges carry it, so
    /// overlapping intervals of one name can be paired.
    public var message: String

    /// Creates an event under the module's subsystem unless another one is given.
    public init(
        subsystem: String = AssetLog.subsystem,
        category: LogCategory,
        name: LogIntervalName,
        phase: Phase,
        message: String = ""
    ) {
        self.subsystem = subsystem
        self.category = category
        self.name = name
        self.phase = phase
        self.message = message
    }

    /// The `.debug` line a tap that does not implement `recordInterval(_:)` receives:
    /// `interval <name> <began|ended>`, then `: <message>` when there is one.
    public var line: LogLine {
        let suffix = self.message.isEmpty ? "" : ": " + self.message
        let text = LogIntervalEvent.prefix + self.name.rawValue + " " + self.phase.rawValue + suffix
        return LogLine(subsystem: self.subsystem, category: self.category, level: .debug, message: text)
    }

    /// The event a rendered interval line stands for, or `nil` for any other line.
    ///
    /// The line is read as UTF-8 bytes, not as `Character`s: a message that starts with a combining mark forms one
    /// grapheme with the separator's space, which a character-wise parse would not split again.
    public init?(line: LogLine) {
        let utf8 = line.message.utf8
        guard line.level == .debug, utf8.starts(with: LogIntervalEvent.prefix.utf8) else {
            return nil
        }
        let rest = utf8.dropFirst(LogIntervalEvent.prefix.utf8.count)
        let headEnd = rest.firstIndex(of: UInt8(ascii: ":")) ?? rest.endIndex
        let head = rest[rest.startIndex..<headEnd]
        guard let space = head.firstIndex(of: UInt8(ascii: " ")),
            let name = LogIntervalName(rawValue: String(Substring(head[head.startIndex..<space]))),
            let phase = Phase(rawValue: String(Substring(head[head.index(after: space)...])))
        else {
            return nil
        }
        var message = ""
        if headEnd != rest.endIndex {
            let separatorEnd = rest.index(after: headEnd)
            guard separatorEnd != rest.endIndex, rest[separatorEnd] == UInt8(ascii: " ") else {
                return nil
            }
            message = String(Substring(rest[rest.index(after: separatorEnd)...]))
        }
        self.init(subsystem: line.subsystem, category: line.category, name: name, phase: phase, message: message)
    }

    private static let prefix = "interval "
}

extension LogTap {
    /// The default for taps that only record lines: the event as its rendered `.debug` line, so every tap sees
    /// both edges of every interval.
    public func recordInterval(_ event: LogIntervalEvent) {
        self.record(event.line)
    }
}

/// A signpost interval that has begun (R-OBS-1). End it exactly once, typically with `defer { interval.end() }`
/// right after `LogRoute.interval(_:category:_:)`; it may span awaits.
public struct LogInterval: Sendable {
    /// Which interval.
    public let name: LogIntervalName
    /// The category it is signposted under.
    public let category: LogCategory
    /// The detail it began with.
    public let message: String
    private let tap: (any LogTap)?
    private let signposter: OSSignposter?
    private let state: OSSignpostIntervalState?

    init(name: LogIntervalName, category: LogCategory, message: String, tap: (any LogTap)?, signposter: OSSignposter?) {
        self.name = name
        self.category = category
        self.message = message
        self.tap = tap
        self.signposter = signposter
        self.state = signposter.map { LogInterval.begin(name, on: $0, message: message) }
        tap?.recordInterval(LogIntervalEvent(category: category, name: name, phase: .began, message: message))
    }

    /// Whether the sink signposts this interval (`OSLogSink`); `false` under the test sink.
    public var isSignposted: Bool {
        self.state != nil
    }

    /// Ends the interval on the signposter and reports the ended edge to the tap.
    public func end() {
        if let signposter = self.signposter, let state = self.state {
            LogInterval.end(self.name, on: signposter, state: state)
        }
        self.tap?.recordInterval(LogIntervalEvent(category: self.category, name: self.name, phase: .ended, message: self.message))
    }

    /// Signpost names must be static strings, hence one literal per interval.
    private static func begin(_ name: LogIntervalName, on signposter: OSSignposter, message: String) -> OSSignpostIntervalState {
        let id = signposter.makeSignpostID()
        switch name {
        case .plan:
            return signposter.beginInterval("plan", id: id, "\(message, privacy: .public)")
        case .transfer:
            return signposter.beginInterval("transfer", id: id, "\(message, privacy: .public)")
        case .verify:
            return signposter.beginInterval("verify", id: id, "\(message, privacy: .public)")
        case .commit:
            return signposter.beginInterval("commit", id: id, "\(message, privacy: .public)")
        case .gc:
            return signposter.beginInterval("gc", id: id, "\(message, privacy: .public)")
        case .eviction:
            return signposter.beginInterval("eviction", id: id, "\(message, privacy: .public)")
        }
    }

    private static func end(_ name: LogIntervalName, on signposter: OSSignposter, state: OSSignpostIntervalState) {
        switch name {
        case .plan:
            signposter.endInterval("plan", state)
        case .transfer:
            signposter.endInterval("transfer", state)
        case .verify:
            signposter.endInterval("verify", state)
        case .commit:
            signposter.endInterval("commit", state)
        case .gc:
            signposter.endInterval("gc", state)
        case .eviction:
            signposter.endInterval("eviction", state)
        }
    }
}

extension LogRoute {
    /// Begins one of the six R-OBS-1 signpost intervals on the sink's signposter (none under `TapOnlyLogSink`) and
    /// reports its began edge to the tap; the returned value ends it (ARCHITECTURE §13.5 item 2). `message` is
    /// rendered like a log line: identifiers through `AssetLog.hashed(_:)`, never a secret.
    public func interval(_ name: LogIntervalName, category: LogCategory, _ message: String = "") -> LogInterval {
        LogInterval(name: name, category: category, message: message, tap: self.tap, signposter: self.sink.signposter(category))
    }
}
