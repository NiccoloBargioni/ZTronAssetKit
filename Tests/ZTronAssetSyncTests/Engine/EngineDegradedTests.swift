import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A factory whose source cannot be built (an invalid configuration, for example).
struct FailingSourceFactory: RemoteSourceFactory {
    let error: AssetError

    func makeRemoteSource(configuration: RemoteConfiguration, staging: any StagingSink, log: LogRoute) async throws(AssetError) -> any RemoteSource {
        throw self.error
    }
}

/// The engine without a remote source or without a store (R-NET-1, R-CAR-7, R-SYN-15).
@Suite("Engine degraded")
struct EngineDegradedTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-1: a remote source that cannot be built leaves stored assets served and fails every fetch with its error", .timeLimit(.minutes(1)))
    func missingSourceFailsFetches() async throws {
        let time = ManualTimeSource()
        let first = EngineHarness.make(time: time)
        let stored = EngineFixture.bytes(201)
        let storedEntry = EngineFixture.entry("stored", stored)
        let absent = EngineHarness.onDemand("absent", EngineFixture.bytes(202))
        await first.serveManifest([storedEntry, absent])
        await first.source.script(storedEntry.transferID, [.stage(stored)])
        try await first.start()
        _ = await first.engine.sync(.force)
        await first.engine.shutdown()

        let error = AssetError.serverUnavailable(retryAfter: nil)
        let second = EngineHarness.make(disk: first.fileSystem.survivingDisk(), time: time, remote: nil, factory: FailingSourceFactory(error: error))
        try await second.start()
        let engine = second.engine
        #expect(try await engine.awaitAsset("stored", lane: .userInitiated).get().byteSize == Int64(stored.count))
        #expect(await engine.awaitAsset("absent", lane: .userInitiated) == .failure(error))
        #expect(await engine.sync(.force) == .failed(error))
        #expect(await engine.ensureAvailable(scope: .identifiers(["absent"])) == .failure(error))
        let state = await engine.introspect()
        #expect(state.waiters == 0 && state.jobsByState.isEmpty)
        let diagnostics = try await engine.diagnostics().get()
        #expect(diagnostics.recentErrors.contains { $0.failureClass == .rejected })
        await engine.shutdown()
    }
}
