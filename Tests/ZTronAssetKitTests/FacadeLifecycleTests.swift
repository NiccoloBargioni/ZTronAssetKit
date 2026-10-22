import Foundation
import Synchronization
import Testing
@testable import ZTronAssetKit
import ZTronAssetStorage
import ZTronAssetSync
import ZTronAssetTestSupport

/// An `AppVersionSource` that counts its reads (the live one reads `Bundle.main`, so a read stands for a `Bundle`
/// access).
@available(macOS 15.0, iOS 18.0, *)
final class CountingAppVersionSource: AppVersionSource {
    private let reads = Mutex(0)

    var count: Int {
        self.reads.withLock { $0 }
    }

    func currentAppVersion() async -> String {
        self.reads.withLock { $0 += 1 }
        return "1.0+1"
    }
}

/// A `RemoteSourceFactory` that counts the sources it builds (the live one builds a `URLSession`).
@available(macOS 15.0, iOS 18.0, *)
final class CountingSourceFactory: RemoteSourceFactory {
    private let base: FakeRemoteSourceFactory
    private let builds = Mutex(0)

    init(source: FakeRemoteSource) {
        self.base = FakeRemoteSourceFactory(source: source)
    }

    var count: Int {
        self.builds.withLock { $0 }
    }

    func makeRemoteSource(configuration: RemoteConfiguration, staging: any StagingSink, log: LogRoute) async throws(AssetError) -> any RemoteSource {
        self.builds.withLock { $0 += 1 }
        return try await self.base.makeRemoteSource(configuration: configuration, staging: staging, log: log)
    }
}

@Suite("Facade lifecycle")
struct FacadeLifecycleTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-1: init touches neither the file system nor Bundle and spawns no task", .timeLimit(.minutes(1)))
    func initDoesNothing() async throws {
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(time: time)
        let versions = CountingAppVersionSource()
        let source = FakeRemoteSource()
        let factory = CountingSourceFactory(source: source)
        let conditions = FakeDeviceConditionsSource()
        let pressure = FakeMemoryPressureSource()
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 1),
            conditions: conditions,
            remoteSources: factory,
            appVersion: versions,
            legacyDefaults: FakeLegacyDefaults(),
            memoryPressure: pressure
        )
        let client = AssetClient(configuration: AssetClientConfiguration(remote: RemoteConfiguration()), environment: environment)
        #expect(fileSystem.operations.isEmpty, "init made file-system calls: \(fileSystem.operations.map(\.kind))")
        #expect(versions.count == 0, "init read the app version (Bundle)")
        #expect(factory.count == 0, "init built a remote source (URLSession)")
        let state = await client.currentEngine().introspect()
        #expect(state.lifecycle == .created)
        #expect(state.ownedTasks == 0)
        #expect(state.armedTimers == 0)
        #expect(time.pendingSleepers == 0)
        #expect(await conditions.activeObservers == 0)
        #expect(await pressure.activeObservers == 0)
        await client.shutdown()
    }

    /// One fresh client per API: each call is the first the client sees, before `start()`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-1: every async API awaits start so a resolve before start succeeds", .timeLimit(.minutes(1)))
    func everyAPIAwaitsStart() async throws {
        let bytes = KitFixture.bytes(11)
        let entry = KitFixture.entry("a", bytes)
        let resolving = KitHarness.make()
        await resolving.serve([(entry, bytes)])
        let client = resolving.client
        let url = try await resolving.withClock {
            try await client.resolve(entry.identifier)
        }
        #expect(url.lastPathComponent.hasSuffix(".png"))
        #expect(await resolving.engine().introspect().lifecycle == .running, "resolve started the client")
        #expect(resolving.fileSystem.operations.contains { $0.kind == .rename }, "the asset was published into the store")
        await client.shutdown()

        let calls: [(String, @Sendable (AssetClient) async throws(AssetError) -> Void)] = [
            ("availability", { client throws(AssetError) in _ = try await client.availability(scope: .all) }),
            ("isSyncDue", { client throws(AssetError) in _ = try await client.isSyncDue() }),
            ("lastSyncedAt", { client throws(AssetError) in _ = try await client.lastSyncedAt() }),
            ("storageReport", { client throws(AssetError) in _ = try await client.storageReport() }),
            ("metrics", { client throws(AssetError) in _ = try await client.metrics() }),
            ("setRetentionScope", { client throws(AssetError) in try await client.setRetentionScope(.all) }),
            ("pin", { client throws(AssetError) in try await client.pin([]) }),
            ("unpin", { client throws(AssetError) in try await client.unpin([]) }),
            ("subscribe", { client throws(AssetError) in _ = try await client.subscribe() }),
        ]
        for (name, call) in calls {
            let harness = KitHarness.make()
            let client = harness.client
            do {
                try await harness.withClock {
                    try await call(client)
                }
            } catch {
                Issue.record("\(name) before start failed with \(error)")
            }
            let lifecycle = await harness.engine().introspect().lifecycle
            #expect(lifecycle == .running, "\(name) did not start the client: \(lifecycle)")
            await client.shutdown()
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: every API called after shutdown fails with shutDown", .timeLimit(.minutes(1)))
    func everyAPIAfterShutdownFails() async throws {
        let harness = KitHarness.make()
        let client = harness.client
        try await harness.startAndSettle()
        await client.shutdown()
        let id = AssetID("a")
        let throwing: [(String, @Sendable () async throws(AssetError) -> Void)] = [
            ("start", { () throws(AssetError) in try await client.start() }),
            ("resolve", { () throws(AssetError) in _ = try await client.resolve(id) }),
            ("availability", { () throws(AssetError) in _ = try await client.availability(scope: .all) }),
            ("ensureAvailable", { () throws(AssetError) in _ = try await client.ensureAvailable(scope: .all) }),
            ("subscribe", { () throws(AssetError) in _ = try await client.subscribe() }),
            ("isSyncDue", { () throws(AssetError) in _ = try await client.isSyncDue() }),
            ("lastSyncedAt", { () throws(AssetError) in _ = try await client.lastSyncedAt() }),
            ("setRetentionScope", { () throws(AssetError) in try await client.setRetentionScope(.all) }),
            ("pin", { () throws(AssetError) in try await client.pin([id]) }),
            ("unpin", { () throws(AssetError) in try await client.unpin([id]) }),
            ("storageReport", { () throws(AssetError) in _ = try await client.storageReport() }),
            ("purge", { () throws(AssetError) in _ = try await client.purge(.all) }),
            ("performMaintenance", { () throws(AssetError) in _ = try await client.performMaintenance(timeBudget: 1) }),
            ("reportUnreadable", { () throws(AssetError) in try await client.reportUnreadable(id) }),
            ("metrics", { () throws(AssetError) in _ = try await client.metrics() }),
            ("diagnosticReport", { () throws(AssetError) in _ = try await client.diagnosticReport() }),
        ]
        for (name, call) in throwing {
            do {
                try await call()
                Issue.record("\(name) succeeded after shutdown")
            } catch {
                #expect(error == .shutDown, "\(name) failed with \(error)")
            }
        }
        await #expect(throws: AssetError.shutDown) {
            try await client.withAsset(id) { url in url }
        }
        #expect(await client.sync(.force) == .failed(.shutDown))
        let handle = client.prefetch([id])
        await #expect(throws: AssetError.shutDown) {
            try await handle.awaitRegistration()
        }
        handle.cancel()
        var events: [AssetEvent] = []
        for await event in client.events {
            events.append(event)
        }
        #expect(events == [.clientShutDown])
        let cache = RecordingCache()
        let (completions, completion) = AsyncStream<Void>.makeStream()
        let (lookedUp, registerError, accepted) = await MainActor.run { () -> (AssetLocation?, AssetError?, Bool) in
            let location = client.lookup(id)
            var thrown: AssetError?
            do throws(AssetError) {
                try client.register(cache)
            } catch {
                thrown = error
            }
            client.unregister(cache)
            let accepted = client.handleBackgroundEvents(identifier: "com.ztron.assetkit.bg.test.v1") {
                completion.yield()
                completion.finish()
            }
            return (location, thrown, accepted)
        }
        #expect(lookedUp == nil)
        #expect(registerError == .shutDown)
        #expect(accepted)
        var calls = 0
        for await _ in completions {
            calls += 1
        }
        #expect(calls == 1, "UIKit's handler is completed once, at once after shutdown")
        let engine = await harness.engine()
        await client.shutdown()
        #expect(await engine.introspect().lifecycle == .shutDown)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-ENV-6: every public async API of AssetClient except withAsset, sync and shutdown throws AssetError typed", .timeLimit(.minutes(1)))
    func asyncAPIsThrowTyped() async throws {
        let harness = KitHarness.make()
        let client = harness.client
        await client.shutdown()
        // Each binding compiles only if the API's error type is exactly AssetError (typed throws).
        let start: () async throws(AssetError) -> Void = client.start
        let resolve: (AssetID, AssetPriority) async throws(AssetError) -> URL = client.resolve
        let availability: (AssetScope) async throws(AssetError) -> AvailabilityReport = client.availability
        let ensure: (AssetScope) async throws(AssetError) -> AvailabilityReport = client.ensureAvailable
        let subscribe: () async throws(AssetError) -> AsyncStream<AssetEvent> = client.subscribe
        let due: () async throws(AssetError) -> Bool = client.isSyncDue
        let synced: () async throws(AssetError) -> Date? = client.lastSyncedAt
        let scope: (AssetScope) async throws(AssetError) -> Void = client.setRetentionScope
        let pin: (Set<AssetID>) async throws(AssetError) -> Void = client.pin
        let unpin: (Set<AssetID>) async throws(AssetError) -> Void = client.unpin
        let report: () async throws(AssetError) -> StorageReport = client.storageReport
        let purge: (PurgeRequest) async throws(AssetError) -> PurgeResult = client.purge
        let maintain: (TimeInterval) async throws(AssetError) -> MaintenanceReport = client.performMaintenance
        let unreadable: (AssetID) async throws(AssetError) -> Void = client.reportUnreadable
        let metrics: () async throws(AssetError) -> MetricsSnapshot = client.metrics
        let diagnostics: () async throws(AssetError) -> Data = client.diagnosticReport
        var caught: [AssetError] = []
        func record(_ body: () async throws(AssetError) -> Void) async {
            do {
                try await body()
            } catch {
                // `error` is statically an AssetError here: no cast, no default.
                caught.append(error)
            }
        }
        await record { () throws(AssetError) in try await start() }
        await record { () throws(AssetError) in _ = try await resolve("a", .userInitiated) }
        await record { () throws(AssetError) in _ = try await availability(.all) }
        await record { () throws(AssetError) in _ = try await ensure(.all) }
        await record { () throws(AssetError) in _ = try await subscribe() }
        await record { () throws(AssetError) in _ = try await due() }
        await record { () throws(AssetError) in _ = try await synced() }
        await record { () throws(AssetError) in try await scope(.all) }
        await record { () throws(AssetError) in try await pin([]) }
        await record { () throws(AssetError) in try await unpin([]) }
        await record { () throws(AssetError) in _ = try await report() }
        await record { () throws(AssetError) in _ = try await purge(.all) }
        await record { () throws(AssetError) in _ = try await maintain(1) }
        await record { () throws(AssetError) in try await unreadable("a") }
        await record { () throws(AssetError) in _ = try await metrics() }
        await record { () throws(AssetError) in _ = try await diagnostics() }
        #expect(caught == Array(repeating: AssetError.shutDown, count: 16))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-7: resolve throws a typed AssetError that callers switch over exhaustively", .timeLimit(.minutes(1)))
    func resolveThrowsTyped() async throws {
        let harness = KitHarness.make()
        let bytes = KitFixture.bytes(21)
        await harness.serve([(KitFixture.entry("listed", bytes), bytes)])
        let client = harness.client
        let outcome: String
        do throws(AssetError) {
            _ = try await harness.withClock { () throws(AssetError) -> URL in
                try await client.resolve("never-listed")
            }
            outcome = "resolved"
        } catch {
            // Exhaustive without `default`: a new case would not compile (R-CAR-7's closed taxonomy).
            switch error {
            case .offline:
                outcome = "offline"
            case .authRejected:
                outcome = "authRejected"
            case .notFound:
                outcome = "notFound"
            case .insufficientSpace:
                outcome = "insufficientSpace"
            case .integrityFailure:
                outcome = "integrityFailure"
            case .serverUnavailable:
                outcome = "serverUnavailable"
            case .cancelled:
                outcome = "cancelled"
            case .storageUnavailable:
                outcome = "storageUnavailable"
            case .shutDown:
                outcome = "shutDown"
            }
        }
        #expect(outcome == "notFound", "an identifier unknown to a freshly fetched manifest is notFound")
        await client.shutdown()
    }
}

/// A purgeable cache that records the levels it was purged at.
@MainActor
final class RecordingCache: PurgeableCache {
    private(set) var levels: [MemoryPressureLevel] = []

    func purge(level: MemoryPressureLevel) {
        self.levels.append(level)
    }
}
