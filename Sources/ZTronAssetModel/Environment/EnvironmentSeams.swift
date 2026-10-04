import Foundation

/// The prior art's `UserDefaults` sync stamp, behind a seam (R-STO-2, R-STO-11, H-10).
///
/// Migration reads the legacy key once and removes it only after a durable "done" commit. Tests use
/// `FakeLegacyDefaults` and never touch real defaults: writing them would write outside this repository (owner
/// directive). The live conformer (`ZTronAssetStorage.LiveLegacyDefaults`) is called only inside units, because
/// the first access may do I/O.
public protocol LegacyDefaults: Sendable {
    /// The string stored under `key`, if any.
    func string(forKey key: String) -> String?
    /// Removes `key`; idempotent.
    func removeValue(forKey key: String)
}

/// The running app's version in the prior art's format, `"<CFBundleShortVersionString>+<CFBundleVersion>"`
/// (RECON §5), read off the main thread inside `start()` (R-SYN-9, P-12).
public protocol AppVersionSource: Sendable {
    /// The current app version.
    func currentAppVersion() async -> String
}

/// The four log categories of R-OBS-1 (subsystem `com.ztron.assetkit`).
public enum LogCategory: String, Sendable, Hashable, CaseIterable, Codable {
    /// `AssetStore`, cleanup, migration.
    case store
    /// The engine and the facade.
    case sync
    /// URLSession, redirects, reachability.
    case transport
    /// The Apple-hosted tier.
    case apple
}

/// Severity of a log line.
public enum LogLevel: Int, Sendable, Hashable, Comparable, CaseIterable, Codable {
    /// Verbose diagnostics.
    case debug = 0
    /// Normal events.
    case info = 1
    /// Unexpected but handled.
    case error = 2
    /// A broken invariant or an unusable configuration.
    case fault = 3

    /// Orders by severity.
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One rendered log line, exactly as the privacy rules allow it to appear (identifiers hashed, no secret).
///
/// It carries the subsystem, so an R-OBS-1 test asserts on the tapped line exactly what `os.Logger` received.
public struct LogLine: Sendable, Hashable {
    /// The `os.Logger` subsystem: always `AssetLog.subsystem` for lines the module emits.
    public var subsystem: String
    /// The category.
    public var category: LogCategory
    /// The severity.
    public var level: LogLevel
    /// The rendered message.
    public var message: String

    /// Creates a line under the module's subsystem (`AssetLog.subsystem`) unless another one is given.
    public init(subsystem: String = AssetLog.subsystem, category: LogCategory, level: LogLevel, message: String) {
        self.subsystem = subsystem
        self.category = category
        self.level = level
        self.message = message
    }
}

/// An optional observer that receives every rendered log line next to the environment's `LogSink` (R-OBS-1,
/// R-SEC-1, ADR-047).
///
/// Tests assert on it (canary key absent, identifiers hashed) while their `TapOnlyLogSink` keeps the unified log
/// untouched; `.live()` leaves it `nil`. `record` must not block.
public protocol LogTap: Sendable {
    /// Receives one rendered line.
    func record(_ line: LogLine)
}

/// How hard the system is asking for memory back (R-CLN-11).
public enum MemoryPressureLevel: Int, Sendable, Hashable, Comparable, CaseIterable {
    /// A memory warning.
    case warning = 1
    /// Critical pressure.
    case critical = 2

    /// Orders by severity.
    public static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A derived, in-memory cache the carousel registers for purging (decoded images, R-CLN-11, MAY), through
/// `AssetClient.register(_:)`. The client holds it weakly.
public protocol PurgeableCache: AnyObject, Sendable {
    /// Drops what can be rebuilt; called on the main actor.
    @MainActor func purge(level: MemoryPressureLevel)
}

/// Memory-pressure events, event-driven like `DeviceConditionsSource` (R-CLN-11, MAY).
///
/// The UIKit conformer (`didReceiveMemoryWarningNotification`) lives outside the module (R-CAR-9); RECON §4 found
/// no ad-hoc carousel caches, so `AssetEnvironment.memoryPressure` is optional. The engine observes it through one
/// owned task that exists only while at least one `PurgeableCache` is registered (R-SYN-14 stays measurable with
/// none registered).
public protocol MemoryPressureSource: Sendable {
    /// Starts an observation; terminating the stream stops it.
    func pressureEvents() async -> AsyncStream<MemoryPressureLevel>
}
