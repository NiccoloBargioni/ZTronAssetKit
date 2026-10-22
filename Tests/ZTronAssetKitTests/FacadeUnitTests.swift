import Foundation
import Testing
@testable import ZTronAssetKit
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

@Suite("Facade units")
struct FacadeUnitTests {
    @Test("R-SEC-1: the diagnostic configuration summary redacts the key and strips credentials, query and fragment from URLs")
    func summaryRedacts() throws {
        let url = try #require(URL(string: "https://user:\(canaryKey)@cdn.example.com:8443/assets/?token=\(canaryKey)#frag"))
        var configuration = AssetClientConfiguration(
            remote: RemoteConfiguration(
                http: HTTPSourceConfiguration(
                    baseURL: url,
                    manifestPath: "v2/manifest.json?token=\(canaryKey)#frag",
                    appKey: AppKey(canaryKey),
                    additionalAllowedHosts: ["b.example.com", "a.example.com"],
                    background: .enabled(BackgroundTransferOptions(namespace: "tests", maxTasks: 4))
                ),
                appleHosted: AppleTierConfiguration(catalogPackID: "Catalog", retention: .keepPacks),
                awsOnly: true
            )
        )
        configuration.prefetchRadius = 3
        let summary = DiagnosticReportBuilder.summary(of: configuration)
        #expect(summary["remote.http.baseURL"] == "https://cdn.example.com:8443/assets/")
        #expect(summary["remote.http.manifestPath"] == "v2/manifest.json", "the manifest path loses its query and fragment")
        #expect(summary["remote.http.appKey"] == "<redacted>")
        #expect(summary["remote.http.additionalAllowedHosts"] == "a.example.com,b.example.com")
        #expect(summary["remote.http.background"] == "enabled")
        #expect(summary["remote.http.background.namespace"] == "tests")
        #expect(summary["remote.http.background.maxTasks"] == "4")
        #expect(summary["remote.appleHosted.catalogPackID"] == "Catalog")
        #expect(summary["remote.appleHosted.retention"] == "keepPacks")
        #expect(summary["remote.awsOnly"] == "true")
        #expect(summary["prefetchRadius"] == "3")
        #expect(summary.values.allSatisfy { !$0.contains(canaryKey) }, "the canary key leaked into the summary")

        let bare = DiagnosticReportBuilder.summary(of: AssetClientConfiguration(remote: RemoteConfiguration()))
        #expect(bare["remote.http"] == "none" && bare["remote.appleHosted"] == "none")
        let keyless = DiagnosticReportBuilder.summary(of: AssetClientConfiguration(remote: RemoteConfiguration(http: HTTPSourceConfiguration(baseURL: url))))
        #expect(keyless["remote.http.appKey"] == "none" && keyless["remote.http.background"] == "disabled")
    }

    @Test("R-OBS-3: the diagnostic counts name the lifecycle, jobs by state, queued work by lane and the launch epoch")
    func countsNameEverything() {
        let lifecycles: [(EngineLifecycle, String)] = [
            (.created, "created"), (.starting, "starting"), (.running, "running"),
            (.degraded(.locked), "degraded"), (.shuttingDown, "shuttingDown"), (.shutDown, "shutDown"),
        ]
        for (lifecycle, name) in lifecycles {
            let diagnostics = EngineDiagnostics(
                introspection: EngineIntrospection(
                    lifecycle: lifecycle,
                    jobsByState: [.downloading: 2, .queued: 5],
                    queued: [.prefetch: 5],
                    running: 2,
                    ownedTasks: 3,
                    watcherActive: true
                ),
                recentErrors: [],
                appVersion: nil,
                launchEpoch: 7,
                indexGeneration: 9,
                stamp: nil,
                retentionScope: .all
            )
            let counts = DiagnosticReportBuilder.counts(of: diagnostics)
            #expect(counts["lifecycle.\(name)"] == 1)
            #expect(counts["jobs.downloading"] == 2 && counts["jobs.queued"] == 5)
            #expect(counts["queued.prefetch"] == 5)
            #expect(counts["running"] == 2 && counts["ownedTasks"] == 3 && counts["watcherActive"] == 1)
            #expect(counts["launchEpoch"] == 7)
            let report = DiagnosticReportBuilder.report(
                configuration: AssetClientConfiguration(remote: RemoteConfiguration()),
                diagnostics: diagnostics,
                metrics: MetricsSnapshot(),
                storage: nil
            )
            #expect(report.appVersion == "unknown" && report.indexGeneration == 9)
            #expect(report.storage == DiagnosticReportBuilder.emptyStorageReport)
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: cancelling the consumer of the client's event stream releases its engine subscription", .timeLimit(.minutes(1)))
    func cancelledConsumerReleasesSubscription() async throws {
        let harness = KitHarness.make()
        try await harness.startAndSettle()
        let client = harness.client
        let engine = await harness.engine()
        let consumer = Task {
            var received = 0
            for await _ in client.events {
                received += 1
            }
            return received
        }
        // The first pull registers the subscription with the engine.
        await engine.waitUntil { $0.subscribers == 1 }
        consumer.cancel()
        _ = await consumer.value
        await engine.waitUntil { $0.subscribers == 0 }
        #expect(await engine.introspect().subscribers == 0)
        await client.shutdown()
    }

    /// The usual `for await event in client.events { … break }`: the consumer's task ends without being cancelled, so
    /// `AsyncStream(unfolding:onCancel:)` never calls `onCancel`; dropping the stream has to release the forwarder's
    /// pump and its engine subscription as well, or every abandoned stream would hold one of each until shutdown.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a consumer that breaks out of the client's event stream releases its engine subscription when the stream is dropped", .timeLimit(.minutes(1)))
    func droppedConsumerReleasesSubscription() async throws {
        let harness = KitHarness.make()
        try await harness.startAndSettle()
        let client = harness.client
        let engine = await harness.engine()
        for round in 0..<3 {
            // The first pull registers the subscription, whose replay of a started engine begins with
            // `snapshotChanged`: the consumer takes it and leaves the loop.
            let consumer = Task { () -> AssetEvent? in
                for await event in client.events {
                    return event
                }
                return nil
            }
            let taken = await consumer.value
            guard case .snapshotChanged = taken else {
                Issue.record("round \(round): the consumer took the subscription's replay, got \(String(describing: taken))")
                break
            }
            await engine.waitUntil { $0.subscribers == 0 }
            #expect(await engine.introspect().subscribers == 0, "round \(round): the dropped stream released its subscription")
        }
        await client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-4: a prefetch on a client whose store cannot open reports storageUnavailable and holds nothing", .timeLimit(.minutes(1)))
    func prefetchOnDegradedClient() async throws {
        let harness = KitHarness.make()
        harness.fileSystem.addFault(FaultRule(operation: .acquireExclusiveLock, occurrence: .every, error: .wouldBlock))
        let client = harness.client
        await #expect(throws: AssetError.storageUnavailable(.locked)) {
            try await harness.withClock { () throws(AssetError) in
                try await client.start()
            }
        }
        let handle = client.prefetch(["a"])
        await #expect(throws: AssetError.storageUnavailable(.locked)) {
            try await handle.awaitRegistration()
        }
        handle.cancel()
        #expect(await harness.engine().introspect().groups == 0)
        await client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-8: reportUnreadable through the facade withdraws the asset from lookup at once", .timeLimit(.minutes(1)))
    func reportUnreadableWithdraws() async throws {
        let bytes = KitFixture.bytes(171)
        let entry = KitFixture.entry("a", bytes)
        let harness = KitHarness.make()
        await harness.serve([(entry, bytes)])
        try await harness.startAndSettle()
        let client = harness.client
        #expect(await MainActor.run { client.lookup(entry.identifier) } != nil)
        try await harness.withClock { () throws(AssetError) in
            try await client.reportUnreadable(entry.identifier)
        }
        #expect(await MainActor.run { client.lookup(entry.identifier) } == nil, "the quarantined copy is no longer handed out")
        await client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-11: a cache that deallocates without unregistering stops the observer at the next pressure event", .timeLimit(.minutes(1)))
    func deallocatedCacheStopsObserver() async throws {
        let harness = KitHarness.make()
        try await harness.startAndSettle()
        let client = harness.client
        try await MainActor.run {
            let cache = RecordingCache()
            try client.register(cache)
        }
        try await harness.pressure.requireObservers(equalTo: 1)
        await harness.pressure.send(.warning)
        try await harness.pressure.requireObservers(equalTo: 0)
        let engine = await harness.engine()
        await engine.waitUntil { !$0.memoryPressureObserverActive }
        #expect(await engine.introspect().memoryPressureObserverActive == false)
        await client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-11: the lifecycle applies only the newest memory-pressure request, whatever order the requests arrive in", .timeLimit(.minutes(1)))
    func lifecycleOrdersPressureRequests() async throws {
        let harness = KitHarness.make()
        try await harness.startAndSettle()
        let lifecycle = harness.client.lifecycle
        await lifecycle.observeMemoryPressure(epoch: 2) { _ in }
        try await harness.pressure.requireObservers(equalTo: 1)
        // A stop made earlier (epoch 1) that arrives late changes nothing.
        await lifecycle.observeMemoryPressure(epoch: 1, handler: nil)
        #expect(await harness.engine().introspect().memoryPressureObserverActive)
        await lifecycle.observeMemoryPressure(epoch: 3, handler: nil)
        try await harness.pressure.requireObservers(equalTo: 0)
        await harness.client.shutdown()
        // After shutdown a request is ignored.
        await lifecycle.observeMemoryPressure(epoch: 4) { _ in }
        #expect(await harness.pressure.activeObservers == 0)
    }
}
