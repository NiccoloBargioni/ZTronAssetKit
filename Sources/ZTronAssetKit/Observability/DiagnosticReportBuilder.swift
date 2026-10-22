import Foundation
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetSync

/// Builds `diagnosticReport()`'s JSON (R-OBS-3; WP-G, `docs/adr-drafts/g.md` G-4). Pure functions over values the
/// engine and the store already answered, so the report is testable without a client.
///
/// Secrets (R-SEC-1): the configuration is summarised field by field, never dumped, so a new field cannot leak by
/// accident; the app key is reported only as present or absent, and URLs lose any user, password, query and
/// fragment. `AppKey` is not `Codable`, so the encoder could not write it even by mistake.
enum DiagnosticReportBuilder {
    /// The module's version string (no build tool writes one; bumped with the package's releases).
    static let moduleVersion = "1.0.0"

    /// The report for one engine's diagnostics, with the metrics and storage figures that could be read; a degraded
    /// store answers neither, and empty figures stand in (L4-R9: diagnostics still answer).
    static func report(
        configuration: AssetClientConfiguration,
        diagnostics: EngineDiagnostics,
        metrics: MetricsSnapshot,
        storage: StorageReport?
    ) -> DiagnosticReport {
        DiagnosticReport(
            moduleVersion: DiagnosticReportBuilder.moduleVersion,
            indexSchemaVersion: Int(StoreLayout.indexSchemaVersion),
            indexGeneration: diagnostics.indexGeneration,
            appVersion: diagnostics.appVersion ?? "unknown",
            configuration: DiagnosticReportBuilder.summary(of: configuration),
            engineCounts: DiagnosticReportBuilder.counts(of: diagnostics),
            stamp: diagnostics.stamp,
            recentErrors: diagnostics.recentErrors,
            metrics: metrics,
            storage: storage ?? DiagnosticReportBuilder.emptyStorageReport
        )
    }

    /// Sorted, indented JSON; non-finite numbers are written as strings, so encoding cannot fail on a value.
    static func encode(_ report: DiagnosticReport) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
        // Every member is a plain Codable value type with finite or string-converted numbers: encoding cannot throw.
        return (try? encoder.encode(report)) ?? Data("{}".utf8)
    }

    /// The configuration minus secrets, one entry per field.
    static func summary(of configuration: AssetClientConfiguration) -> [String: String] {
        var summary: [String: String] = [
            "location": String(describing: configuration.location),
            "storage": String(describing: configuration.storage),
            "legacy": String(describing: configuration.legacy),
            "network": String(describing: configuration.network),
            "power": String(describing: configuration.power),
            "refresh": String(describing: configuration.refresh),
            "tuning": String(describing: configuration.tuning),
            "tuning.clamped": String(describing: configuration.tuning.clamped().tuning),
            "limits": String(describing: configuration.limits),
            "prefetchRadius": String(configuration.prefetchRadius),
            "retentionScope": String(describing: configuration.retentionScope),
            "remote.awsOnly": String(configuration.remote.awsOnly),
        ]
        if let http = configuration.remote.http {
            summary["remote.http.baseURL"] = DiagnosticReportBuilder.sanitized(http.baseURL)
            summary["remote.http.manifestPath"] = http.manifestPath
            summary["remote.http.appKey"] = http.appKey == nil ? "none" : "<redacted>"
            summary["remote.http.keyHeaderName"] = http.keyHeaderName
            summary["remote.http.additionalAllowedHosts"] = http.additionalAllowedHosts.sorted().joined(separator: ",")
            summary["remote.http.maxConnectionsPerHost"] = String(http.maxConnectionsPerHost)
            summary["remote.http.requestTimeout"] = String(http.requestTimeout)
            switch http.background {
            case .disabled:
                summary["remote.http.background"] = "disabled"
            case .enabled(let options):
                summary["remote.http.background"] = "enabled"
                summary["remote.http.background.namespace"] = options.namespace
                summary["remote.http.background.discretionary"] = String(options.discretionary)
                summary["remote.http.background.maxTasks"] = String(options.maxTasks)
                summary["remote.http.background.keyRedirectExposure"] = String(describing: options.keyRedirectExposure)
            }
        } else {
            summary["remote.http"] = "none"
        }
        if let apple = configuration.remote.appleHosted {
            summary["remote.appleHosted.catalogPackID"] = apple.catalogPackID
            summary["remote.appleHosted.catalogPath"] = apple.catalogPath
            summary["remote.appleHosted.retention"] = String(describing: apple.retention)
            summary["remote.appleHosted.updateCheckOnManifestFetch"] = String(apple.updateCheckOnManifestFetch)
        } else {
            summary["remote.appleHosted"] = "none"
        }
        return summary
    }

    /// Scheme, host, port and path only: no user, password, query or fragment.
    static func sanitized(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<unparseable>"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<unparseable>"
    }

    /// The engine's counters by name: lifecycle, jobs by state, queued work by lane, tasks, timers, subscribers.
    static func counts(of diagnostics: EngineDiagnostics) -> [String: Int] {
        let state = diagnostics.introspection
        var counts: [String: Int] = [
            "lifecycle.\(DiagnosticReportBuilder.name(of: state.lifecycle))": 1,
            "running": state.running,
            "preempting": state.preempting,
            "waiters": state.waiters,
            "interests": state.interests,
            "groups": state.groups,
            "armedTimers": state.armedTimers,
            "scheduledDeadlines": state.scheduledDeadlines,
            "ownedTasks": state.ownedTasks,
            "subscribers": state.subscribers,
            "bufferedEvents": state.bufferedEvents,
            "watcherActive": state.watcherActive ? 1 : 0,
            "memoryPressureObserverActive": state.memoryPressureObserverActive ? 1 : 0,
            "recentErrors": diagnostics.recentErrors.count,
        ]
        for (kind, count) in state.jobsByState {
            counts["jobs.\(kind)"] = count
        }
        for (lane, count) in state.queued {
            counts["queued.\(lane)"] = count
        }
        if let epoch = diagnostics.launchEpoch {
            counts["launchEpoch"] = Int(clamping: epoch)
        }
        return counts
    }

    private static func name(of lifecycle: EngineLifecycle) -> String {
        switch lifecycle {
        case .created:
            return "created"
        case .starting:
            return "starting"
        case .running:
            return "running"
        case .degraded:
            return "degraded"
        case .shuttingDown:
            return "shuttingDown"
        case .shutDown:
            return "shutDown"
        }
    }

    /// The storage figures of a store that could not answer.
    static let emptyStorageReport = StorageReport(
        bytesByKind: [:],
        bytesByState: ResidencyBytes(present: 0, stale: 0, pendingDeletion: 0),
        pinnedBytes: 0,
        essentialBytes: 0,
        evictableBytes: 0,
        stagingBytes: 0,
        orphanBytes: 0,
        sourceCopyBytes: 0,
        budgetBytes: 0,
        freeBytesImportant: 0,
        freeBytesOpportunistic: 0,
        unverifiedCount: 0,
        lastCleanupAt: nil
    )
}
