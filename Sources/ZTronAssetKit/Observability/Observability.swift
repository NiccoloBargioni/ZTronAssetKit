import Foundation
import ZTronAssetModel

/// `diagnosticReport()` (R-OBS-3): `Codable`, so it is valid JSON by construction; it holds no `AppKey`
/// (deliberately not `Codable`) and no URL with credentials (R-SEC-1).
///
/// Logging itself (`AssetLog`, R-OBS-1) lives in the Model so every target logs under its own category (ADR-043);
/// the facade re-exports it.
public struct DiagnosticReport: Sendable, Hashable, Codable {
    /// The module's version string.
    public var moduleVersion: String
    /// The index schema version.
    public var indexSchemaVersion: Int
    /// The committed index generation.
    public var indexGeneration: UInt64
    /// The app version.
    public var appVersion: String
    /// The configuration with secrets replaced by `"<redacted>"`.
    public var configuration: [String: String]
    /// Engine counters (jobs by state, tasks, timers, subscribers).
    public var engineCounts: [String: Int]
    /// The stamp, if any.
    public var stamp: SyncStamp?
    /// The last errors (at most 32): time, asset, class, internal description.
    public var recentErrors: [DiagnosticError]
    /// Metrics.
    public var metrics: MetricsSnapshot
    /// Storage.
    public var storage: StorageReport

    /// Creates a report.
    public init(
        moduleVersion: String,
        indexSchemaVersion: Int,
        indexGeneration: UInt64,
        appVersion: String,
        configuration: [String: String],
        engineCounts: [String: Int],
        stamp: SyncStamp?,
        recentErrors: [DiagnosticError],
        metrics: MetricsSnapshot,
        storage: StorageReport
    ) {
        self.moduleVersion = moduleVersion
        self.indexSchemaVersion = indexSchemaVersion
        self.indexGeneration = indexGeneration
        self.appVersion = appVersion
        self.configuration = configuration
        self.engineCounts = engineCounts
        self.stamp = stamp
        self.recentErrors = recentErrors
        self.metrics = metrics
        self.storage = storage
    }
}
