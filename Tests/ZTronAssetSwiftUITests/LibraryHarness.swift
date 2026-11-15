import Combine
import Foundation
import Synchronization
import Testing
@testable import ZTronAssetSwiftUI
import ZTronAssetTestSupport

/// The test clock of the library tests: a `ManualTimeSource` that moves itself to any sleep's deadline lying within
/// `horizon` of now, and leaves later deadlines to the test.
///
/// The same clock as the compatibility tests' (`Tests/ZTronAssetCompatibilityTests/CompatHarness.swift`), copied
/// because a test target cannot import another one: this target reaches the engine only through the library's public
/// API, so it cannot read the engine's clock fence the way `KitHarness` does. The harness sets
/// `manifestFetchDeadline` far beyond anything the automatic moves add up to, so only the store's short windows are
/// passed without the test. Nothing sleeps for real and no wall clock is read (C4).
@available(macOS 15.0, iOS 18.0, *)
final class AutoAdvancingClock: TimeSource {
    /// The clock tests advance explicitly for anything beyond `horizon`.
    let manual: ManualTimeSource
    /// The longest sleep passed without the test (seconds).
    let horizon: TimeInterval

    init(manual: ManualTimeSource, horizon: TimeInterval = 1) {
        self.manual = manual
        self.horizon = horizon
    }

    func now() -> Date {
        self.manual.now()
    }

    func monotonicNow() -> MonotonicInstant {
        self.manual.monotonicNow()
    }

    func uptimeNow() -> MonotonicInstant {
        self.manual.uptimeNow()
    }

    func sleep(until deadline: MonotonicInstant) async throws(CancellationError) {
        if deadline.seconds(since: self.manual.monotonicNow()) <= self.horizon {
            self.reach(deadline)
        }
        try await self.manual.sleep(until: deadline)
    }

    /// Moves the manual clock to `deadline` exactly: `ManualTimeSource.advance(to:)` goes through a `Double` and can
    /// stop a nanosecond short, which would leave this sleep registered for good.
    private func reach(_ deadline: MonotonicInstant) {
        for _ in 0..<4 {
            let now = self.manual.monotonicNow()
            guard now < deadline else {
                return
            }
            self.manual.advance(by: Double(deadline.nanoseconds - now.nanoseconds + 1) / 1_000_000_000)
        }
    }
}

/// Manifests and payloads for the library tests.
enum LibraryFixture {
    /// The origin every chain of these tests names. No request ever leaves: the harness's environment builds a
    /// `FakeRemoteSource` whatever the configuration says.
    static let origin = URL(fileURLWithPath: "/origin", isDirectory: true)

    /// Deterministic payload bytes.
    static func bytes(_ seed: UInt64, count: Int = 300) -> Data {
        GeneratedPayload.bytes(seed: seed, offset: 0, length: count)
    }

    /// A manifest entry for `bytes`.
    static func entry(
        _ id: String,
        _ bytes: Data,
        tags: [String] = [],
        ext: String = "png",
        policy: AssetPolicy = .standard
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
}

/// A `BundleLookup` over a fixed table that records, per enumeration, whether it ran on the main thread.
@available(macOS 15.0, iOS 18.0, *)
final class FakeBundleLookup: BundleLookup {
    private let table: [BundleResourceKey: URL]
    private let calls = Mutex<[(extensions: Set<String>, onMain: Bool)]>([])

    init(_ table: [BundleResourceKey: URL]) {
        self.table = table
    }

    /// The extensions each enumeration asked for.
    var enumerations: [Set<String>] {
        self.calls.withLock { $0.map(\.extensions) }
    }

    /// Whether any enumeration ran on the main thread.
    var ranOnMain: Bool {
        self.calls.withLock { $0.contains { $0.onMain } }
    }

    func resources(withExtensions extensions: Set<String>) -> [BundleResourceKey: URL] {
        let onMain = Thread.isMainThread
        self.calls.withLock { $0.append((extensions, onMain)) }
        return self.table.filter { extensions.contains($0.key.fileExtension) }
    }
}

/// A `BundleLookup` whose enumerations block at a gate until the test opens it and announce their arrival on a
/// stream: what holds a start at its bundle indexing while the rest of the client runs. The same shape as the engine
/// tests' `MigrationPlannerGate`.
///
/// A held enumeration blocks its thread, so a harness that uses the gate runs its bulk units on
/// `DetachedBlockingExecutor`: no thread of the cooperative pool is blocked and no other unit waits behind it.
@available(macOS 15.0, iOS 18.0, *)
final class GatedBundleLookup: BundleLookup {
    private let table: [BundleResourceKey: URL]
    private let semaphore = DispatchSemaphore(value: 0)
    private let arrivals: AsyncStream<Void>
    private let arrived: AsyncStream<Void>.Continuation

    init(_ table: [BundleResourceKey: URL]) {
        let (arrivals, arrived) = AsyncStream<Void>.makeStream()
        self.table = table
        self.arrivals = arrivals
        self.arrived = arrived
    }

    /// Suspends until an enumeration has reached the gate. One caller at a time.
    func waitForAnEnumeration() async {
        for await _ in self.arrivals {
            return
        }
    }

    /// Lets the held enumeration through, and every later one.
    func open() {
        self.semaphore.signal()
    }

    func resources(withExtensions extensions: Set<String>) -> [BundleResourceKey: URL] {
        self.arrived.yield()
        self.semaphore.wait()
        // Hands the opening on, so the gate stays open.
        self.semaphore.signal()
        return self.table.filter { extensions.contains($0.key.fileExtension) }
    }
}

/// A `BlockingExecutor` that runs each unit on a Dispatch thread of its own, for `GatedBundleLookup`.
struct DetachedBlockingExecutor: BlockingExecutor {
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: work())
            }
        }
    }
}

/// A purgeable cache that reports each purge on a stream, so a test waits for it without polling.
@MainActor
final class SignallingCache: PurgeableCache {
    private(set) var levels: [MemoryPressureLevel] = []
    private let signal: AsyncStream<MemoryPressureLevel>.Continuation

    init(signal: AsyncStream<MemoryPressureLevel>.Continuation) {
        self.signal = signal
    }

    func purge(level: MemoryPressureLevel) {
        self.levels.append(level)
        self.signal.yield(level)
    }
}

/// An `AssetLibrary` built by the real chain (`Setup.library()`) over a real client, store and engine on
/// `FakeFileSystem`, the self-advancing manual clock, `FakeRemoteSource` and the fake conditions and memory-pressure
/// sources. Gated for the Mutex-backed fakes (ADR-051).
@available(macOS 15.0, iOS 18.0, *)
@MainActor
struct LibraryHarness {
    let time: ManualTimeSource
    let fileSystem: FakeFileSystem
    let source: FakeRemoteSource
    let conditions: FakeDeviceConditionsSource
    let pressure: FakeMemoryPressureSource
    let environment: AssetEnvironment
    let library: AssetLibrary

    /// The environment of fakes. `fileSystem` and `time` let a second library run on the first one's disk and clock;
    /// `bulk` is the bulk executor (hashing, the bundle enumeration): inline unless a test holds those units.
    static func environment(
        time: ManualTimeSource,
        fileSystem: FakeFileSystem,
        source: FakeRemoteSource,
        conditions: FakeDeviceConditionsSource,
        bulk: any BlockingExecutor = InlineBlockingExecutor()
    ) -> AssetEnvironment {
        AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: bulk,
            time: AutoAdvancingClock(manual: time),
            random: SeededRandom(seed: 0x5E_7A),
            conditions: conditions,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(version: "1.0+1"),
            legacyDefaults: FakeLegacyDefaults()
        )
    }

    /// The steps every harness chain carries: snapshots install at every publication (so `lookup` sees a run's
    /// assets when `sync` returns), a manifest fetch never reaches its deadline on the self-advancing clock, a
    /// failure is final within its run (a retry would wait for a script the test did not write), the deletion grace
    /// lies within the clock's horizon (a purge returns only once its bytes are reclaimed, which waits the grace
    /// out), and no legacy migration.
    static func chain(_ setup: AssetLibrary.Setup, environment: AssetEnvironment) -> AssetLibrary.Setup {
        setup
            .tuning(\.retry.maxAttemptsPerRun, 1)
            .tuning(\.interactiveRetry.maxAttemptsPerRun, 1)
            .tuning(\.manifestFetchDeadline, 1_000_000)
            .tuning(\.snapshotInstallInterval, 0)
            .storage(\.deletionGrace, 0.25)
            .legacy(\.enabled, false)
            .environment(environment)
    }

    /// Builds a library through the chain; nothing is started. `steps` adds the chain steps under test; `sharing`
    /// puts the library on another harness's volume and clock (one root admits one client, R-STO-9).
    static func make(
        sharing other: LibraryHarness? = nil,
        conditions: DeviceConditions = .unrestricted,
        bulk: any BlockingExecutor = InlineBlockingExecutor(),
        steps: (AssetLibrary.Setup) -> AssetLibrary.Setup = { $0 }
    ) -> LibraryHarness {
        let time = other?.time ?? ManualTimeSource()
        let fileSystem = other?.fileSystem ?? FakeFileSystem(time: time)
        let source = FakeRemoteSource()
        let conditionsSource = FakeDeviceConditionsSource(initial: conditions)
        let pressure = FakeMemoryPressureSource()
        let environment = LibraryHarness.environment(
            time: time,
            fileSystem: fileSystem,
            source: source,
            conditions: conditionsSource,
            bulk: bulk
        )
        let setup = LibraryHarness.chain(steps(AssetLibrary.origin(LibraryFixture.origin)), environment: environment)
            .memoryPressure(from: pressure)
        return LibraryHarness(
            time: time,
            fileSystem: fileSystem,
            source: source,
            conditions: conditionsSource,
            pressure: pressure,
            environment: environment,
            library: setup.library()
        )
    }

    /// Scripts the next manifest fetch to answer `entries` and every entry's transfer to stage its bytes.
    func serve(_ entries: [(ManifestEntry, Data)], etag: String = "v1") async {
        await self.serveManifest(entries.map(\.0), etag: etag)
        for (entry, bytes) in entries {
            await self.source.script(entry.transferID, [.stage(bytes)])
        }
    }

    /// Scripts the next manifest fetch only.
    func serveManifest(_ entries: [ManifestEntry], etag: String = "v1") async {
        await self.source.scriptManifest([.fetched(LibraryFixture.manifestData(entries), etag: ETag(rawValue: "\"\(etag)\""))])
    }

    /// Starts the library and returns once its launch run ended: `sync(.ifDue)` joins the launch run, or answers
    /// `notDue` once the run's stamp is written, and never starts a second run.
    func startAndSettle() async {
        await self.library.start()
        let outcome = await self.library.sync(.ifDue)
        switch outcome {
        case .complete, .notDue:
            return
        default:
            Issue.record("setup: the launch run did not complete: \(outcome)")
        }
    }
}

/// Suspends until `publisher` has published a value `predicate` accepts, and returns it; `nil` when the test's time
/// limit cancelled the wait first.
///
/// A `sink` has unlimited demand and the stream behind it is unbounded, so no value is dropped between two looks,
/// which `publisher.values` does not promise. Nothing polls and nothing sleeps.
@MainActor
func published<Value: Sendable>(
    _ publisher: Published<Value>.Publisher,
    where predicate: (Value) -> Bool
) async -> Value? {
    let (stream, continuation) = AsyncStream<Value>.makeStream()
    let observation = publisher.sink { continuation.yield($0) }
    defer {
        observation.cancel()
    }
    for await value in stream where predicate(value) {
        return value
    }
    return nil
}

/// Counts the changes an `ObservableObject` announces while it is alive.
@MainActor
final class ChangeCounter {
    private(set) var count = 0
    private var observation: AnyCancellable?

    init(_ library: AssetLibrary) {
        self.observation = library.objectWillChange.sink { [weak self] _ in
            self?.count += 1
        }
    }
}
