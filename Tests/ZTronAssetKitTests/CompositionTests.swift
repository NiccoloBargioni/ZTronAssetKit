import Foundation
import Synchronization
import Testing
@testable import ZTronAssetKit
import ZTronAssetStorage
import ZTronAssetSync
import ZTronAssetTestSupport
import ZTronAssetTransport

/// A `RemoteSourceFactory` that notes, when it builds the source, whether the store had already taken its lock (the
/// store is opened before the remote side exists, T2-11).
@available(macOS 15.0, iOS 18.0, *)
final class OrderRecordingFactory: RemoteSourceFactory {
    private let base: FakeRemoteSourceFactory
    private let fileSystem: FakeFileSystem
    private let lockedAtBuild = Mutex<[Bool]>([])

    init(source: FakeRemoteSource, fileSystem: FakeFileSystem) {
        self.base = FakeRemoteSourceFactory(source: source)
        self.fileSystem = fileSystem
    }

    /// One entry per build: whether the store's lock was taken before it.
    var builds: [Bool] {
        self.lockedAtBuild.withLock { $0 }
    }

    func makeRemoteSource(configuration: RemoteConfiguration, staging: any StagingSink, log: LogRoute) async throws(AssetError) -> any RemoteSource {
        let locked = self.fileSystem.operations.contains { $0.kind == .acquireExclusiveLock && $0.failure == nil }
        self.lockedAtBuild.withLock { $0.append(locked) }
        return try await self.base.makeRemoteSource(configuration: configuration, staging: staging, log: log)
    }
}

@Suite("Composition root and background events")
struct CompositionTests {
    private static let identifier = "com.ztron.assetkit.bg.test.v1"

    /// The attestation half of the fallback (ADR-026 (c), transport.md §10.7): the background session exists only
    /// when the app attests, through `BackgroundTransferPolicy.enabled`, that it forwards the AppDelegate hook to
    /// `handleBackgroundEvents`. Without the attestation the composition root builds a source with no background
    /// session, and the engine routes every bulk transfer to the foreground. The run-time detection of a hook that was
    /// attested but not wired (transport.md F-26) is not detected: CCR-G1 was declined, the attestation is what
    /// "wired" means in Stage 2 (ruling L5-R5, ADR-054).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: background falls back to foreground when the background-events hook is not wired", .timeLimit(.minutes(1)))
    func foregroundWithoutHook() async throws {
        let remote = RemoteConfiguration(http: HTTPSourceConfiguration(baseURL: URL(string: "https://cdn.example.com/")!))
        let live = try await LiveRemoteSourceFactory().makeRemoteSource(configuration: remote, staging: FakeStagingSink(), log: .tapOnly(nil))
        #expect(!live.capabilities.supportsBackground, "no background session without the hook's attestation")
        await live.invalidate()

        let source = FakeRemoteSource(capabilities: live.capabilities)
        let harness = KitHarness.make(source: source)
        let bytes = KitFixture.bytes(91)
        let entry = KitFixture.entry("bulk", bytes)
        await harness.serve([(entry, bytes)])
        try await harness.startAndSettle()
        let bulk = await source.starts.filter { $0.priority == .bulk }
        #expect(!bulk.isEmpty, "setup: the launch run transferred at the bulk lane")
        #expect(bulk.allSatisfy { $0.route == .foreground }, "every bulk transfer ran in the foreground: \(bulk.map(\.route))")
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: handling background events before start opens the store first and runs no sync", .timeLimit(.minutes(1)))
    func backgroundEventsBeforeStart() async throws {
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(time: time)
        let bytes = KitFixture.bytes(92)
        let entry = KitFixture.entry("a", bytes)
        // A first launch syncs completely, so the relaunch for background events has no sync due.
        let first = KitHarness.make(fileSystem: fileSystem, time: time)
        await first.serve([(entry, bytes)])
        try await first.startAndSettle()
        await first.client.shutdown()

        let source = FakeRemoteSource()
        let factory = OrderRecordingFactory(source: source, fileSystem: fileSystem)
        let operationsBefore = fileSystem.operations.count
        let harness = KitHarness.make(fileSystem: fileSystem, time: time, source: source, factory: factory)
        let client = harness.client
        let (completions, completion) = AsyncStream<Void>.makeStream()
        let accepted = await MainActor.run {
            client.handleBackgroundEvents(identifier: CompositionTests.identifier) {
                completion.yield()
                completion.finish()
            }
        }
        #expect(accepted)
        let foreign = await MainActor.run {
            client.handleBackgroundEvents(identifier: "com.example.other") {}
        }
        #expect(!foreign, "an identifier that is not ours is declined")
        var calls = 0
        for await _ in completions {
            calls += 1
        }
        #expect(calls == 1, "UIKit's handler is completed once")
        #expect(fileSystem.operations.count > operationsBefore, "the store was opened")
        #expect(factory.builds == [true], "the remote side was built once, after the store took its lock")
        #expect(await source.backgroundEventIdentifiers == [CompositionTests.identifier])
        let engine = await harness.engine()
        #expect(await engine.introspect().lifecycle == .running)
        try await harness.drive(until: { $0.isIdleSilent })
        #expect(await source.manifestRequests.isEmpty, "no sync ran: none was due")
        #expect(await source.starts.isEmpty)
        await client.shutdown()
    }

    @Test("R-APL-5: the live composition root refuses a configuration with no remote tier as serverUnavailable", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func liveFactoryWithoutTier() async {
        await #expect(throws: AssetError.serverUnavailable(retryAfter: nil)) {
            try await LiveRemoteSourceFactory().makeRemoteSource(configuration: RemoteConfiguration(), staging: FakeStagingSink(), log: .tapOnly(nil))
        }
    }

    @Test("R-SYN-9: the live app version is read on its executor in the prior art's short+build format", .timeLimit(.minutes(1)))
    func liveAppVersion() async {
        let version = await LiveAppVersionSource(executor: InlineBlockingExecutor()).currentAppVersion()
        let parts = version.split(separator: "+", omittingEmptySubsequences: false)
        #expect(parts.count == 2 && parts.allSatisfy { !$0.isEmpty }, "\"<short>+<build>\": \(version)")
    }

    /// `init` over the live environment builds the conformers and the actors only; shutting the client down before
    /// it started opens nothing (P-12, R-CAR-1). The environment is the one `init` resolves when the app passes none,
    /// with the unified-log sink swapped for the tap-only one (ADR-047). The test relies on a shutdown in `created`
    /// never opening the store (no directory under Caches, no lock file) and never logging, and the tap shows that no
    /// line was emitted, so a change that made it log, which opening the store does, fails here rather than writing
    /// outside this repository unnoticed.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-1: the live environment builds an AssetClient without starting anything", .timeLimit(.minutes(1)))
    func liveClientStartsNothing() async {
        let configuration = AssetClientConfiguration(remote: RemoteConfiguration(), location: .caches)
        var environment = AssetClient.resolvedEnvironment(nil, for: configuration)
        #expect(environment.fileSystem is LiveFileSystem && environment.logSink is OSLogSink, "setup: the live conformers")
        let tap = RecordingLogTap()
        environment.logSink = TapOnlyLogSink()
        environment.logTap = tap
        let client = AssetClient(configuration: configuration, environment: environment)
        let state = await client.currentEngine().introspect()
        #expect(state.lifecycle == .created && state.ownedTasks == 0 && state.armedTimers == 0)
        await client.shutdown()
        #expect(await client.currentEngine().introspect().lifecycle == .shutDown)
        #expect(tap.lines.isEmpty, "the created client logged, so it did work: \(tap.lines)")
    }
}
