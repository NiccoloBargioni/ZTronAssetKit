import Foundation
import Testing
import ZTronAssetKit
import ZTronAssetTestSupport

/// The test clock of the shim tests: a `ManualTimeSource` that moves itself to any sleep's deadline lying within
/// `horizon` of now, and leaves later deadlines to the test.
///
/// `KitHarness` drives the manual clock while an operation runs and stops short of the engine's clock fence (an
/// in-flight manifest fetch's deadline), which it reads through `@testable` engine state. This target imports only
/// the public API of `ZTronAssetKit` and `ZTronAssetTestSupport` (ADR-033), so it cannot read that fence. Moving the
/// clock at the moment a sleep is registered needs no fence: the harness sets `manifestFetchDeadline` far beyond any
/// distance the auto-moves can add up to in a test, so only the short store windows (the commit window, a commit
/// retry, a trailing progress emission) are passed automatically. Nothing sleeps for real and no wall clock is read:
/// every instant is the manual clock's. A sleep may return late under the `TimeSource` contract ("callers re-read
/// `monotonicNow()`", REENTRANCY RE-S16), which is all an overlapping move can cause.
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
    /// stop a nanosecond short (ADR-053, L4-R24 (2)), which would leave this sleep registered for good.
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

/// Prior-art manifests and payloads for the shim tests.
enum CompatFixture {
    /// Deterministic payload bytes.
    static func bytes(_ seed: UInt64, count: Int = 256) -> Data {
        GeneratedPayload.bytes(seed: seed, offset: 0, length: count)
    }

    /// A prior-art manifest entry for `bytes`: content-addressed remote path, real SHA-256 checksum.
    static func asset(
        _ identifier: String,
        _ bytes: Data,
        ext: String = "png",
        directories: [String] = ["Black Ops 7", "Rex Infernus"],
        fileName: String? = nil
    ) -> CDNAsset {
        let checksum = ContentHash.sha256(of: bytes).hex
        return CDNAsset(
            identifier: identifier,
            fileExtension: ext,
            remotePath: "media/\(checksum.prefix(16))/\(identifier).\(ext)",
            localPathComponents: directories,
            localFileName: fileName,
            byteSize: bytes.count,
            checksum: checksum
        )
    }

    /// The wire bytes of a prior-art manifest: the bare array of `CDNAsset` objects (RECON §5, R-MAN-1).
    static func manifestData(_ assets: [CDNAsset]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding plain value types cannot fail.
        return (try? encoder.encode(assets)) ?? Data("[]".utf8)
    }

    /// A strong entity tag.
    static func etag(_ tag: String) -> ETag? {
        ETag(rawValue: "\"\(tag)\"")
    }

    /// The asset id of a prior-art entry.
    static func id(_ asset: CDNAsset) -> AssetID {
        AssetID(asset.identifier)
    }

    /// The transfer the client starts for a prior-art entry.
    static func transfer(_ asset: CDNAsset) -> TransferID {
        asset.manifestEntry.transferID
    }

    /// A per-test directory inside this repository (never the system temp directory, owner directive), empty.
    static func directory(_ name: String, filePath: String = #filePath) throws -> URL {
        let directory = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build-tests", isDirectory: true)
            .appendingPathComponent("compatibility", isDirectory: true)
            .appendingPathComponent("\(name)-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// A `CDNProviding` whose manifest is scripted: the stand-in for an app's provider where a shim needs one as its
/// manifest source (`CDNSyncCoordinator.verifyFullyAvailable`) or as the prior-art initialisers' argument.
struct ScriptedCDNProvider: CDNProviding {
    /// What `fetchManifest()` answers.
    let manifest: Result<[CDNAsset], ScriptedProviderFailure>

    func fetchManifest() async throws -> [CDNAsset] {
        try self.manifest.get()
    }

    func downloadAsset(_ asset: CDNAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw ScriptedProviderFailure.unscripted
    }
}

/// The scripted provider's failures.
enum ScriptedProviderFailure: Error, Equatable {
    /// The manifest fetch failed.
    case manifestUnavailable
    /// A call the test did not script.
    case unscripted
}

/// An `AssetClient` over a real store and engine on `FakeFileSystem`, the self-advancing manual clock,
/// `FakeRemoteSource` and the fake conditions source: what the shims adapt in every test (ADR-054's WP-K note: a
/// real client over the fakes). Gated for the Mutex-backed fakes (ADR-051).
@available(macOS 15.0, iOS 18.0, *)
struct CompatHarness {
    let time: ManualTimeSource
    let clock: AutoAdvancingClock
    let fileSystem: FakeFileSystem
    let source: FakeRemoteSource
    let conditions: FakeDeviceConditionsSource
    let environment: AssetEnvironment
    let configuration: AssetClientConfiguration
    let client: AssetClient

    /// The harness's tuning: snapshots install at every publication (so `lookup` sees a run's assets when `sync`
    /// returns), a manifest fetch never reaches its deadline on the self-advancing clock, and a failure is final
    /// within its run (a retry would wait for a script the test did not write).
    static var tuning: SyncTuning {
        var retry = RetryPolicy.background
        retry.maxAttemptsPerRun = 1
        var interactive = RetryPolicy.interactive
        interactive.maxAttemptsPerRun = 1
        return SyncTuning(
            retry: retry,
            interactiveRetry: interactive,
            manifestFetchDeadline: 1_000_000,
            snapshotInstallInterval: 0
        )
    }

    /// The environment the harness's clients run in, built from its fakes.
    static func environment(
        time: AutoAdvancingClock,
        fileSystem: FakeFileSystem,
        source: FakeRemoteSource,
        conditions: FakeDeviceConditionsSource,
        appVersion: String
    ) -> AssetEnvironment {
        AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 0xC0_4E),
            conditions: conditions,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(version: appVersion),
            legacyDefaults: FakeLegacyDefaults()
        )
    }

    /// Builds a client; nothing is started.
    static func make(
        refresh: RefreshPolicy = .oncePerAppVersion,
        conditions: DeviceConditions = .unrestricted,
        appVersion: String = "1.0+1",
        tuning: SyncTuning = CompatHarness.tuning
    ) -> CompatHarness {
        let time = ManualTimeSource()
        let clock = AutoAdvancingClock(manual: time)
        let fileSystem = FakeFileSystem(time: time)
        let source = FakeRemoteSource()
        let conditionsSource = FakeDeviceConditionsSource(initial: conditions)
        let environment = CompatHarness.environment(
            time: clock,
            fileSystem: fileSystem,
            source: source,
            conditions: conditionsSource,
            appVersion: appVersion
        )
        let configuration = AssetClientConfiguration(
            remote: RemoteConfiguration(),
            legacy: LegacyMigrationPolicy(enabled: false),
            refresh: refresh,
            tuning: tuning
        )
        return CompatHarness(
            time: time,
            clock: clock,
            fileSystem: fileSystem,
            source: source,
            conditions: conditionsSource,
            environment: environment,
            configuration: configuration,
            client: AssetClient(configuration: configuration, environment: environment)
        )
    }

    /// Scripts the next manifest fetch to answer `assets` and every asset's transfer to stage its bytes.
    func serve(_ assets: [(CDNAsset, Data)], etag: String = "v1") async {
        await self.serveManifest(assets.map(\.0), etag: etag)
        for (asset, bytes) in assets {
            await self.source.script(CompatFixture.transfer(asset), [.stage(bytes)])
        }
    }

    /// Scripts the next manifest fetch only.
    func serveManifest(_ assets: [CDNAsset], etag: String = "v1") async {
        await self.source.scriptManifest([.fetched(CompatFixture.manifestData(assets), etag: CompatFixture.etag(etag))])
    }

    /// Starts the client and returns once its launch run ended. For launches whose run completes: `sync(.ifDue)`
    /// then joins the launch run, or answers `notDue` once the run's stamp is written, and never starts a second run.
    func settleLaunch() async throws {
        try await self.client.start()
        let outcome = await self.client.sync(.ifDue)
        switch outcome {
        case .complete, .notDue:
            return
        default:
            Issue.record("setup: the launch run did not complete: \(outcome)")
        }
    }

    /// The transfers started from now on: the source's start log after `baseline` entries.
    func starts(after baseline: Int) async -> [TransferID] {
        await self.source.starts.dropFirst(baseline).map(\.id)
    }

    /// A client of a later launch: the same configuration, volume, origin, clock and conditions, reporting
    /// `appVersion`. Nothing is started; shut the earlier client down first (one root admits one client, R-STO-9).
    func relaunch(appVersion: String) -> AssetClient {
        let environment = CompatHarness.environment(
            time: self.clock,
            fileSystem: self.fileSystem,
            source: self.source,
            conditions: self.conditions,
            appVersion: appVersion
        )
        return AssetClient(configuration: self.configuration, environment: environment)
    }
}

extension AssetClient {
    /// The client's identity: what the tests compare, so a failed expectation prints an identifier instead of the
    /// client's whole reflection.
    var identity: ObjectIdentifier {
        ObjectIdentifier(self)
    }
}
