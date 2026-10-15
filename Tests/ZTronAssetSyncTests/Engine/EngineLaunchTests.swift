import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Launch reconciliation and resume (R-NET-3, R-NET-8; ARCHITECTURE §13.5 #3, ADR-028).
@Suite("Engine launch")
struct EngineLaunchTests {
    static let background = RemoteSourceCapabilities(tier: .aws, supportsPriority: true, supportsResume: true, supportsBackground: true, keepsSourceCopies: false)

    /// A first lifetime that applies `entries` on demand (nothing fetched) and shuts down.
    @available(macOS 15.0, iOS 18.0, *)
    static func firstLifetime(_ entries: [ManifestEntry], time: ManualTimeSource) async throws -> EngineHarness {
        let harness = EngineHarness.make(time: time)
        await harness.serveManifest(entries)
        try await harness.start()
        _ = await harness.engine.sync(.force)
        await harness.engine.shutdown()
        return harness
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: a live background task is re-attached after relaunch, not duplicated", .timeLimit(.minutes(1)))
    func liveTaskReattached() async throws {
        let time = ManualTimeSource()
        let bytes = EngineFixture.bytes(131)
        let entry = EngineHarness.onDemand("bg", bytes)
        let first = try await EngineLaunchTests.firstLifetime([entry], time: time)
        let source = FakeRemoteSource(capabilities: EngineLaunchTests.background)
        let name = StagingFileName(transfer: entry.transferID, attempt: TransferAttempt(epoch: 1, sequence: 9), kind: .partial)
        await source.scriptReattached([ReattachedTransfer(name: name, isRunning: true, bytesReceived: 100)])
        await source.script(entry.transferID, [.stage(bytes)])
        let second = EngineHarness.make(disk: first.fileSystem.survivingDisk(), time: time, source: source)
        try await second.start()
        await second.engine.waitUntil { $0.jobsByState.isEmpty && $0.running == 0 }
        #expect(await source.cancelledTransfers.isEmpty, "the wanted live task is not cancelled")
        let starts = await source.starts
        #expect(starts.map(\.id) == [entry.transferID], "joined once, never duplicated")
        #expect(starts.first?.route == .backgroundEligible)
        #expect(try await second.view().records["bg"]?.referencedBlob != nil)
        await second.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: a download completed while the app was dead is adopted from staging, not re-downloaded", .timeLimit(.minutes(1)))
    func completedDownloadAdopted() async throws {
        let time = ManualTimeSource()
        let bytes = EngineFixture.bytes(132)
        let entry = EngineHarness.onDemand("done", bytes)
        let first = try await EngineLaunchTests.firstLifetime([entry], time: time)
        // The OS finished the download and moved it into staging while the app was dead.
        let disk = first.fileSystem.survivingDisk()
        let fileSystem = FakeFileSystem(disk: disk, time: time)
        let name = StagingFileName(transfer: entry.transferID, attempt: TransferAttempt(epoch: 1, sequence: 4), kind: .partial)
        try fileSystem.write(bytes, to: StoreLayout(base: EngineHarness.base).stagingURL(name), mode: .truncate)
        let source = FakeRemoteSource(capabilities: EngineLaunchTests.background)
        await source.scriptReattached([ReattachedTransfer(name: name, isRunning: false, bytesReceived: Int64(bytes.count))])
        let second = EngineHarness.make(time: time, source: source, fileSystem: fileSystem)
        try await second.start()
        #expect(await source.starts.isEmpty, "adopted from staging, not re-downloaded")
        #expect(try await second.view().records["done"]?.referencedBlob != nil)
        #expect(try await second.engine.awaitAsset("done", lane: .userInitiated).get().byteSize == Int64(bytes.count))
        #expect(try fileSystem.itemInfo(at: StoreLayout(base: EngineHarness.base).stagingURL(name)) == nil)
        await second.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-3: an offline launch cancels no live background task", .timeLimit(.minutes(1)))
    func offlineLaunchCancelsNothing() async throws {
        let time = ManualTimeSource()
        let entries = (0..<3).map { EngineHarness.onDemand("bg\($0)", EngineFixture.bytes(UInt64(140 + $0))) }
        let first = try await EngineLaunchTests.firstLifetime(entries, time: time)
        let source = FakeRemoteSource(capabilities: EngineLaunchTests.background)
        let live = entries.enumerated().map { index, entry in
            ReattachedTransfer(name: StagingFileName(transfer: entry.transferID, attempt: TransferAttempt(epoch: 1, sequence: UInt32(index + 1)), kind: .partial), isRunning: true, bytesReceived: 0)
        }
        await source.scriptReattached(live)
        await source.scriptManifest([.fail(.offline(.noConnection))])
        let offline = DeviceConditions(network: NetworkConditions(satisfied: false, expensive: false, constrained: false), power: PowerConditions(lowPowerMode: false, thermal: .nominal))
        let second = EngineHarness.make(disk: first.fileSystem.survivingDisk(), time: time, source: source, conditions: offline)
        try await second.start()
        #expect(await second.engine.sync(.force) == .failed(.offline))
        #expect(await source.cancelledTransfers.isEmpty)
        #expect(await source.controlLog.isEmpty, "no live task was cancelled through a handle either")
        let state = await second.engine.introspect()
        #expect(state.jobsByState[.blocked] == 3, "the re-attached transfers wait for the network")
        await second.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-8: a refused or invalid resume discards the partial and restarts from zero in the next attempt", .timeLimit(.minutes(1)))
    func refusedResumeRestartsFresh() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(150, count: 4_096)
        let entry = EngineHarness.onDemand("large", bytes)
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.hold])
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        let waiter = Task { await engine.awaitAsset("large", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(entry.transferID)
        // The first attempt dropped the connection after writing a partial and a resume sidecar.
        let first = try #require(await harness.source.starts.first)
        let sink = try await harness.store.makeStagingSink()
        try sink.createPartial(first.partialName)
        _ = try sink.appendPartial(bytes.prefix(1_000), to: first.partialName)
        let validator = ResumeValidator.strongETag(try #require(EngineFixture.etag("v1")))
        sink.writeSidecar(ResumeSidecar(name: first.partialName, validator: validator, receivedBytes: 1_000, expectedBytes: Int64(bytes.count)))
        await harness.source.script(entry.transferID, [.fail(.transient(.resumeRejected, retryAfter: nil)), .stage(bytes)])
        await harness.source.release(entry.transferID, with: .failed(.transient(.connectionLost(resumable: true), retryAfter: nil)))
        // The interactive backoff (at most 0.25 s) elapses on the manual clock.
        try await harness.time.requireSleepers(atLeast: 1)
        harness.time.advance(by: 1)
        let location = try await waiter.value.get()
        #expect(location.byteSize == Int64(bytes.count))
        let starts = await harness.source.starts
        #expect(starts.count == 3)
        #expect(starts[1].resume == ResumePoint(previous: first.partialName, offset: 1_000, validator: validator), "the second attempt resumed")
        #expect(starts[2].resume == nil, "the attempt after the refusal starts from zero")
        let layout = StoreLayout(base: EngineHarness.base)
        for request in starts.prefix(2) {
            #expect(try harness.fileSystem.itemInfo(at: layout.stagingURL(request.partialName)) == nil)
            #expect(try harness.fileSystem.itemInfo(at: layout.stagingURL(request.partialName.with(kind: .sidecar))) == nil)
        }
        #expect(try await engine.metrics().get().retries[.transient] == 1, "the refusal itself is retried without a backoff count")
        await engine.shutdown()
    }
}
