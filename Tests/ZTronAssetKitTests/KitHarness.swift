import Foundation
import Synchronization
import Testing
@testable import ZTronAssetKit
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Manifest and payload builders for facade tests (WP-G).
enum KitFixture {
    /// Deterministic payload bytes.
    static func bytes(_ seed: UInt64, count: Int = 300) -> Data {
        GeneratedPayload.bytes(seed: seed, offset: 0, length: count)
    }

    /// An entry for `bytes`.
    static func entry(
        _ id: String,
        _ bytes: Data,
        policy: AssetPolicy = .standard,
        tags: [String] = [],
        ext: String = "png"
    ) -> ManifestEntry {
        ManifestEntry(
            identifier: AssetID(id),
            fileExtension: ext,
            remotePath: "media/\(id).\(ext)",
            localPathComponents: ["dir"],
            byteSize: Int64(bytes.count),
            checksum: ContentHash.sha256(of: bytes),
            tags: tags,
            policy: policy
        )
    }

    /// The wire bytes of a manifest (the prior art's bare array, R-MAN-1).
    static func manifestData(_ entries: [ManifestEntry]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding plain value types cannot fail.
        return (try? encoder.encode(entries)) ?? Data("[]".utf8)
    }

    /// A strong ETag for `tag`.
    static func etag(_ tag: String) -> ETag? {
        ETag(rawValue: "\"\(tag)\"")
    }
}

/// An `AssetClient` over a real store and engine on `FakeFileSystem`, `ManualTimeSource`, `FakeRemoteSource` and
/// the fake conditions and memory-pressure sources (ARCHITECTURE §14: "Kit: a real client over fakes"). Gated for
/// the Mutex-backed fakes (ADR-051).
@available(macOS 15.0, iOS 18.0, *)
struct KitHarness {
    let time: ManualTimeSource
    let fileSystem: FakeFileSystem
    let source: FakeRemoteSource
    let conditions: FakeDeviceConditionsSource
    let pressure: FakeMemoryPressureSource
    let tap: RecordingLogTap
    let environment: AssetEnvironment
    let configuration: AssetClientConfiguration
    let client: AssetClient

    /// Builds a client; nothing is started. `fileSystem` lets a second client reopen the first one's disk.
    static func make(
        fileSystem existing: FakeFileSystem? = nil,
        time existingTime: ManualTimeSource? = nil,
        source: FakeRemoteSource = FakeRemoteSource(),
        factory: (any RemoteSourceFactory)? = nil,
        remote: RemoteConfiguration = RemoteConfiguration(),
        conditions: DeviceConditions = .unrestricted,
        tuning: SyncTuning = SyncTuning(),
        refresh: RefreshPolicy = .oncePerAppVersion,
        prefetchRadius: Int = 2,
        appVersion: String = "1.0+1",
        metadata: (any BlockingExecutor)? = nil,
        bulk: (any BlockingExecutor)? = nil,
        withMemoryPressure: Bool = true
    ) -> KitHarness {
        let time = existingTime ?? ManualTimeSource()
        let fileSystem = existing ?? FakeFileSystem(time: time)
        let conditionsSource = FakeDeviceConditionsSource(initial: conditions)
        let pressure = FakeMemoryPressureSource()
        let tap = RecordingLogTap()
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: metadata ?? InlineBlockingExecutor(),
            bulkExecutor: bulk ?? InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 0x6B17),
            conditions: conditionsSource,
            remoteSources: factory ?? FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(version: appVersion),
            legacyDefaults: FakeLegacyDefaults(),
            memoryPressure: withMemoryPressure ? pressure : nil,
            logTap: tap
        )
        let configuration = AssetClientConfiguration(
            remote: remote,
            legacy: LegacyMigrationPolicy(enabled: false),
            refresh: refresh,
            tuning: tuning,
            prefetchRadius: prefetchRadius
        )
        return KitHarness(
            time: time,
            fileSystem: fileSystem,
            source: source,
            conditions: conditionsSource,
            pressure: pressure,
            tap: tap,
            environment: environment,
            configuration: configuration,
            client: AssetClient(configuration: configuration, environment: environment)
        )
    }

    /// Scripts the next manifest fetch to return `entries` and every entry's transfer to stage its bytes.
    func serve(_ entries: [(ManifestEntry, Data)], etag: String = "v1") async {
        await self.source.scriptManifest([.fetched(KitFixture.manifestData(entries.map(\.0)), etag: KitFixture.etag(etag))])
        for (entry, bytes) in entries {
            await self.source.script(entry.transferID, [.stage(bytes)])
        }
    }

    /// Scripts the next manifest fetch only.
    func serveManifest(_ entries: [ManifestEntry], etag: String = "v1") async {
        await self.source.scriptManifest([.fetched(KitFixture.manifestData(entries), etag: KitFixture.etag(etag))])
    }

    /// The engine serving the client now.
    func engine() async -> SyncEngine {
        await self.client.currentEngine()
    }

    /// Starts the client while the clock is driven (the store's commit window and the launch run need it), then
    /// waits until the launch run settled: no run, no manifest fetch, no job.
    func startAndSettle() async throws {
        let client = self.client
        try await self.withClock {
            try await client.start()
        }
        try await self.drive(until: { $0.groups == 0 && $0.waiters == 0 && $0.running == 0 }) {
            $0.state.run == nil && $0.state.manifestFetch == nil
        }
    }

    /// Runs `operation` while a driver wakes every sleeper on the manual clock, never at or past the engine's clock
    /// fence (an in-flight manifest fetch's deadline or a probe's watchdog, which the fakes finish without the
    /// clock; the Sync tests' L4-R17 rule). The driver ends with the operation; its waits end on cancellation.
    func withClock<T: Sendable, E: Error>(_ operation: @Sendable () async throws(E) -> T) async throws(E) -> T {
        let time = self.time
        let client = self.client
        let driver = Task {
            while !Task.isCancelled {
                await time.waitForSleepers(atLeast: 1)
                guard !Task.isCancelled else {
                    return
                }
                let engine = await client.currentEngine()
                let fenced = await engine.kitRead { engine -> (fence: MonotonicInstant, sleepers: Int)? in
                    let sleepers = time.pendingSleepers
                    guard !Task.isCancelled, let deadline = time.nextDeadline else {
                        return nil
                    }
                    if let fence = KitHarness.clockFence(engine), deadline >= fence {
                        return (fence, sleepers)
                    }
                    time.advance(to: deadline)
                    return nil
                }
                guard let fenced, !Task.isCancelled else {
                    continue
                }
                let (fence, waiting) = fenced
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await engine.awaitCondition { KitHarness.clockFence($0) != fence }
                    }
                    group.addTask {
                        await time.waitForSleepers(atLeast: waiting + 1)
                    }
                    _ = await group.next()
                    group.cancelAll()
                }
            }
        }
        let value: T
        do throws(E) {
            value = try await operation()
        } catch {
            driver.cancel()
            await driver.value
            throw error
        }
        driver.cancel()
        await driver.value
        return value
    }

    /// Drives the clock until `predicate` holds on the engine's introspection (and `engineCondition` on its state):
    /// each step advances to the earliest sleeper unless it is at or past the clock fence, else waits for a change
    /// of the engine's counters or for one more sleeper. Bounded by `advances` clock moves; a drive cancelled by the
    /// time limit throws, so the overrun says where it stopped.
    func drive(
        advances: Int = 1_024,
        until predicate: @escaping @Sendable (EngineIntrospection) -> Bool,
        engineCondition: @escaping @Sendable (isolated SyncEngine) -> Bool = { _ in true }
    ) async throws {
        let engine = await self.engine()
        let time = self.time
        var advanced = 0
        while true {
            enum Step: Sendable {
                case done
                case advanced
                case wait(EngineIntrospection, fence: MonotonicInstant?, sleepers: Int)
            }
            let step = await engine.kitRead { engine -> Step in
                let state = engine.introspect()
                if predicate(state) && engineCondition(engine) {
                    return .done
                }
                let fence = KitHarness.clockFence(engine)
                let sleepers = time.pendingSleepers
                guard let deadline = time.nextDeadline, fence.map({ deadline < $0 }) ?? true else {
                    return .wait(state, fence: fence, sleepers: sleepers)
                }
                time.advance(to: deadline)
                return .advanced
            }
            switch step {
            case .done:
                return
            case .advanced:
                advanced += 1
                guard advanced <= advances else {
                    throw KitHarnessError.neverSettled(await engine.introspect())
                }
            case .wait(let state, let fence, let waiting):
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await engine.awaitCondition { engine in
                            let now = engine.introspect()
                            return now != state || (predicate(now) && engineCondition(engine)) || KitHarness.clockFence(engine) != fence
                        }
                    }
                    group.addTask {
                        await time.waitForSleepers(atLeast: waiting + 1)
                    }
                    _ = await group.next()
                    group.cancelAll()
                }
                if Task.isCancelled {
                    throw KitHarnessError.neverSettled(await engine.introspect())
                }
            }
        }
    }

    /// Runs `sync(.force)` through the client while the clock is driven.
    func syncDriven(_ mode: SyncMode = .force) async -> SyncOutcome {
        let client = self.client
        return await self.withClock {
            await client.sync(mode)
        }
    }

    /// The earliest deadline that would time out work the fakes finish without the clock (a copy of the Sync tests'
    /// `SyncEngine.clockFence()` seam, which this target does not link).
    static func clockFence(_ engine: isolated SyncEngine) -> MonotonicInstant? {
        var fence: MonotonicInstant?
        if let fetch = engine.state.manifestFetch, let at = engine.state.heap.deadline(for: .manifest(fetch.sequence)) {
            fence = at
        }
        for origin in engine.state.breakers.keys.sorted() {
            guard case .halfOpen(_, _, _?, let watchdog?)? = engine.state.breakers[origin]?.state else {
                continue
            }
            fence = min(fence ?? watchdog, watchdog)
        }
        return fence
    }
}

/// Harness failures.
enum KitHarnessError: Error {
    /// The clock budget ran out, or the test's time limit cancelled the drive, before the predicate held.
    case neverSettled(EngineIntrospection)
}

extension SyncEngine {
    /// Runs `read` in one engine turn (test seam of the facade tests).
    func kitRead<T: Sendable>(_ read: @Sendable (isolated SyncEngine) -> T) -> T {
        read(self)
    }
}

/// A `BundleLookup` over a fixed table that counts its calls and records whether each ran on the main thread.
@available(macOS 15.0, iOS 18.0, *)
final class FakeBundleLookup: BundleLookup {
    private let table: [BundleResourceKey: URL]
    private let calls = Mutex<[Bool]>([])

    init(_ table: [BundleResourceKey: URL]) {
        self.table = table
    }

    /// One entry per enumeration: whether it ran on the main thread.
    var enumerations: [Bool] {
        self.calls.withLock { $0 }
    }

    func resources(withExtensions extensions: Set<String>) -> [BundleResourceKey: URL] {
        let isMain = Thread.isMainThread
        self.calls.withLock { $0.append(isMain) }
        return self.table.filter { extensions.contains($0.key.fileExtension) }
    }
}
