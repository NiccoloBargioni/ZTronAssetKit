import Foundation
import Testing
@testable import ZTronAssetKit
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The canary app key (R-SEC-1): it must never surface anywhere a value can be printed or recorded.
let canaryKey = "CANARY-7f3e-key-do-not-leak"

/// A remote configuration that carries the canary key (the fake factory ignores it, so nothing is fetched).
let canaryRemote = RemoteConfiguration(
    http: HTTPSourceConfiguration(
        baseURL: URL(string: "https://cdn.example.com/assets/")!,
        appKey: AppKey(canaryKey)
    )
)

@Suite("Facade observability")
struct ObservabilityTests {
    /// Syncs `ok` and fails `missing` with a 404, so the error ring and the metrics have something to show.
    @available(macOS 15.0, iOS 18.0, *)
    private static func syncedWithOneFailure(_ harness: KitHarness) async throws -> (ok: ManifestEntry, missing: ManifestEntry) {
        let okBytes = KitFixture.bytes(41)
        let missingBytes = KitFixture.bytes(42)
        let ok = KitFixture.entry("ok", okBytes)
        let missing = KitFixture.entry("missing", missingBytes)
        await harness.serveManifest([ok, missing])
        await harness.source.script(ok.transferID, [.stage(okBytes)])
        await harness.source.script(missing.transferID, [.fail(.permanentMissing(httpStatus: 404))])
        try await harness.startAndSettle()
        return (ok, missing)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-OBS-3: diagnosticReport is valid JSON with state counts and the last errors and never the canary key", .timeLimit(.minutes(1)))
    func diagnosticReportIsJSON() async throws {
        let harness = KitHarness.make(remote: canaryRemote)
        let client = harness.client
        let (_, missing) = try await ObservabilityTests.syncedWithOneFailure(harness)
        let data = try await client.diagnosticReport()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains(canaryKey), "the report carries the canary key")
        let object = try JSONSerialization.jsonObject(with: data)
        let top = try #require(object as? [String: Any], "the report is a JSON object")
        for key in ["moduleVersion", "indexSchemaVersion", "indexGeneration", "appVersion", "configuration", "engineCounts", "recentErrors", "metrics", "storage"] {
            #expect(top[key] != nil, "missing \(key)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReport.self, from: data)
        #expect(report.indexSchemaVersion == Int(StoreLayout.indexSchemaVersion))
        #expect(report.appVersion == "1.0+1")
        #expect(report.indexGeneration > 0)
        let lastSynced = try await client.lastSyncedAt()
        #expect((report.stamp == nil) == (lastSynced == nil), "the report's stamp is the store's")
        #expect(report.engineCounts["lifecycle.running"] == 1)
        #expect(report.engineCounts["ownedTasks"] != nil && report.engineCounts["subscribers"] != nil)
        #expect(report.recentErrors.contains { $0.id == missing.identifier && $0.failureClass == .notFound }, "the 404 is among the last errors")
        #expect(report.configuration["remote.http.appKey"] == "<redacted>")
        #expect(report.configuration["remote.http.baseURL"] == "https://cdn.example.com/assets/")
        #expect(report.metrics.transferRequests >= 2)
        #expect(report.storage.bytesByState.present > 0)
        await client.shutdown()
    }

    /// L4-R9: the engine's diagnostics answer while its store cannot open; the report then carries empty storage
    /// figures and the degraded lifecycle instead of failing.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-OBS-3: diagnosticReport answers while the store cannot be opened, with the degraded lifecycle and empty storage figures", .timeLimit(.minutes(1)))
    func diagnosticReportWhileDegraded() async throws {
        let harness = KitHarness.make()
        harness.fileSystem.addFault(FaultRule(operation: .acquireExclusiveLock, occurrence: .every, error: .wouldBlock))
        let client = harness.client
        await #expect(throws: AssetError.storageUnavailable(.locked)) {
            try await harness.withClock { () throws(AssetError) in
                try await client.start()
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReport.self, from: try await client.diagnosticReport())
        #expect(report.engineCounts["lifecycle.degraded"] == 1)
        #expect(report.storage.budgetBytes == 0 && report.storage.bytesByState.present == 0 && report.storage.lastCleanupAt == nil)
        // The ring holds the store's failed open (a storage failure naming no asset), so support sees why the client
        // is degraded.
        #expect(
            report.recentErrors.contains { $0.failureClass == .storage && $0.id == nil && $0.detail.hasPrefix("store open failed") },
            "the lock failure is in the ring of recent errors: \(report.recentErrors)"
        )
        await client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-OBS-2: metrics count bytes, requests, retries and failures by class, hits, misses, evictions and GC bytes", .timeLimit(.minutes(1)))
    func metricsCount() async throws {
        let storage = StoragePolicy(budget: .bytes(700), minimumResidency: 0)
        let harness = KitHarness.make(storage: storage)
        let client = harness.client
        let payloads = (0..<4).map { KitFixture.bytes(50 + UInt64($0), count: 300) }
        let entries = payloads.enumerated().map { KitFixture.entry("od\($0.offset)", $0.element, policy: .onDemand) }
        let missing = KitFixture.entry("gone", KitFixture.bytes(60), policy: .onDemand)
        await harness.serveManifest(entries + [missing])
        // od0 succeeds after one transient failure (a retry); od1…od3 succeed; gone is a 404.
        await harness.source.script(entries[0].transferID, [.fail(.transient(.serverError(httpStatus: 503), retryAfter: nil)), .stage(payloads[0])])
        for index in 1..<4 {
            await harness.source.script(entries[index].transferID, [.stage(payloads[index])])
        }
        await harness.source.script(missing.transferID, [.fail(.permanentMissing(httpStatus: 404))])
        try await harness.startAndSettle()
        for entry in entries {
            // Three 300-byte assets exceed the 700-byte budget: resolving them one by one evicts the least recent.
            _ = try await harness.withClock { () throws(AssetError) -> URL in
                try await client.resolve(entry.identifier)
            }
        }
        await #expect(throws: AssetError.notFound) {
            try await harness.withClock { () throws(AssetError) -> URL in
                try await client.resolve(missing.identifier)
            }
        }
        let (hit, miss) = await MainActor.run { (client.lookup(entries[3].identifier), client.lookup("not-in-the-catalog")) }
        #expect(hit != nil && miss == nil)
        // An orphan blob older than the orphan grace: maintenance's GC dooms it and counts its bytes.
        let orphan = KitFixture.bytes(70, count: 250)
        try plantOrphan(orphan, in: harness.fileSystem)
        // One clock move past the orphan grace, made in an engine turn that finds no clock fence (an in-flight manifest
        // fetch's deadline or a probe's watchdog), as the harness's drivers move it (L4-R17; L5-R14 (f)).
        let engine = await harness.engine()
        let time = harness.time
        let grace = storage.orphanGrace + 1
        while true {
            let moved = await engine.kitRead { engine -> Bool in
                guard KitHarness.clockFence(engine) == nil else {
                    return false
                }
                time.advance(by: grace)
                return true
            }
            if moved || Task.isCancelled {
                break
            }
            await engine.awaitCondition { KitHarness.clockFence($0) == nil }
        }
        _ = try await harness.withClock { () throws(AssetError) -> MaintenanceReport in
            try await client.performMaintenance(timeBudget: 60)
        }
        let metrics = try await client.metrics()
        #expect(metrics.bytesDownloaded >= 4 * 300, "bytes: \(metrics.bytesDownloaded)")
        #expect(metrics.manifestRequests >= 1)
        #expect(metrics.transferRequests >= 6, "od0 twice, od1…od3 and gone: \(metrics.transferRequests)")
        #expect(metrics.retries.serverError >= 1, "the 503 was retried: \(metrics.retries)")
        #expect(metrics.failures.notFound >= 1, "the 404 failed as notFound: \(metrics.failures)")
        #expect(metrics.lookupHits == 1 && metrics.lookupMisses == 1)
        #expect(metrics.evictions >= 1 && metrics.evictedBytes >= 300, "evictions: \(metrics.evictions), \(metrics.evictedBytes)")
        #expect(metrics.gcBytes >= 250, "GC bytes: \(metrics.gcBytes)")
        await client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SEC-1: the canary key appears in no description, dump, Mirror, error, event, metric or captured log line", .timeLimit(.minutes(1)))
    func canaryNeverLeaks() async throws {
        let harness = KitHarness.make(remote: canaryRemote)
        let client = harness.client
        let probe = EventProbe(stream: try await harness.withClock { () throws(AssetError) in
            try await client.subscribe()
        })
        _ = try await ObservabilityTests.syncedWithOneFailure(harness)
        var errors: [AssetError] = []
        do {
            _ = try await harness.withClock { () throws(AssetError) -> URL in
                try await client.resolve("missing")
            }
        } catch {
            errors.append(error)
        }
        let metrics = try await client.metrics()
        let report = try await client.diagnosticReport()
        let storage = try await client.storageReport()
        await client.shutdown()
        _ = await probe.next { $0 == .clientShutDown }
        let events = await probe.received
        await probe.stop()

        var texts: [String] = []
        func capture(_ value: Any) {
            texts.append(String(describing: value))
            texts.append(String(reflecting: value))
            var dumped = ""
            dump(value, to: &dumped)
            texts.append(dumped)
            texts.append(Mirror(reflecting: value).children.map { "\($0.label ?? ""): \($0.value)" }.joined(separator: "\n"))
        }
        capture(client)
        capture(client.configuration)
        capture(client.configuration.remote)
        capture(errors)
        capture(events)
        capture(metrics)
        capture(storage)
        texts.append(String(decoding: report, as: UTF8.self))
        texts.append(contentsOf: harness.tap.lines.map { "\($0.subsystem) \($0.category) \($0.message)" })
        #expect(!errors.isEmpty && !events.isEmpty && !harness.tap.lines.isEmpty, "setup: errors, events and log lines were produced")
        let leaks = texts.filter { $0.contains(canaryKey) }
        #expect(leaks.isEmpty, "the canary key leaked into \(leaks.count) of \(texts.count) renderings")
    }
}

/// Writes `bytes` as an unreferenced blob of the store root on the fake volume (an orphan, R-CLN-2).
@available(macOS 15.0, iOS 18.0, *)
func plantOrphan(_ bytes: Data, in fileSystem: FakeFileSystem) throws {
    let lock = try #require(fileSystem.operations.last { $0.kind == .acquireExclusiveLock }?.url)
    let root = lock.deletingLastPathComponent()
    var base = root
    var layout: StoreLayout?
    while base.pathComponents.count > 1 {
        base = base.deletingLastPathComponent()
        if StoreLayout(base: base).root.standardizedFileURL == root.standardizedFileURL {
            layout = StoreLayout(base: base)
            break
        }
    }
    let found = try #require(layout, "the store root's layout")
    let key = BlobKey(hash: ContentHash.sha256(of: bytes), ext: try #require(AssetFileExtension("png")))
    let url = found.blobURL(key)
    var missing: [URL] = []
    var directory = url.deletingLastPathComponent()
    while try fileSystem.itemInfo(at: directory) == nil {
        missing.append(directory)
        directory = directory.deletingLastPathComponent()
    }
    for directory in missing.reversed() {
        try fileSystem.createDirectory(at: directory)
    }
    try fileSystem.write(bytes, to: url, mode: .truncate)
}
