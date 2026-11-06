import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Independent confirmation of S3-CONC-04: (1) the stuck state outlasts a quiescent engine and a later reading of the
/// same network; only a real network edge revives it; (2) control: the same sequence with an unsatisfied first reading,
/// then a satisfied one, is retried, so the only difference is the first-reading rule.
@Suite("S3 confirm: offline before the first reading")
struct S3ConfirmOfflineTests {
    @available(macOS 15.0, iOS 18.0, *)
    struct Rig {
        let engine: SyncEngine
        let source: FakeRemoteSource
        let base: FakeDeviceConditionsSource
        let gated: GatedConditionsSource
        let entry: ManifestEntry
        let group: InterestToken

        static func make(firstReadingSatisfied: Bool) async throws -> Rig {
            let time = ManualTimeSource()
            let fileSystem = FakeFileSystem(
                disk: DiskImage(),
                time: time,
                configuration: FakeFileSystemConfiguration(importantCapacity: 64 << 30, opportunisticCapacity: 64 << 30)
            )
            let source = FakeRemoteSource()
            let base = FakeDeviceConditionsSource(initial: .unrestricted)
            let gated = GatedConditionsSource(base: base, holdFrom: 2)
            let environment = AssetEnvironment(
                fileSystem: fileSystem,
                metadataExecutor: InlineBlockingExecutor(),
                bulkExecutor: InlineBlockingExecutor(),
                time: time,
                random: SeededRandom(seed: 0x5EED),
                conditions: gated,
                remoteSources: FakeRemoteSourceFactory(source: source),
                appVersion: FakeAppVersionSource(version: "1.0+1"),
                legacyDefaults: FakeLegacyDefaults(),
                memoryPressure: FakeMemoryPressureSource(),
                logTap: RecordingLogTap()
            )
            let store = AssetStore(
                configuration: StoreConfiguration(
                    location: .applicationSupport,
                    policy: StoragePolicy(),
                    legacy: LegacyMigrationPolicy(enabled: false),
                    limits: ManifestLimits(),
                    commitMinimumInterval: 0,
                    snapshotInstallInterval: 0
                ),
                environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink())
            )
            let engine = SyncEngine(
                store: store,
                environment: environment,
                configuration: EngineConfiguration(
                    tuning: SyncTuning(),
                    storage: StoragePolicy(),
                    network: NetworkPolicy(),
                    power: PowerPolicy(),
                    refresh: .oncePerAppVersion,
                    remote: RemoteConfiguration(),
                    limits: ManifestLimits(),
                    retentionScope: .all
                )
            )
            let bytes = EngineFixture.bytes(4_242)
            let entry = EngineHarness.onDemand("late", bytes)
            await source.scriptManifest([.fetched(EngineFixture.manifestData([entry]), etag: EngineFixture.etag("v1"))])
            _ = try await engine.start().get()
            let applied = await engine.sync(.force)
            #expect(applied.completeReport != nil)
            await engine.waitUntil { $0.jobsByState.isEmpty && !$0.watcherActive }
            await source.script(entry.transferID, [.fail(.offline(.noConnection)), .stage(bytes)])
            let group = try await engine.registerGroup([entry.identifier], lane: .prefetch).get()
            for await _ in gated.held {
                break
            }
            await engine.waitUntil { $0.jobsByState[.queued] == 1 }
            let answer = await engine.awaitAsset(entry.identifier, lane: .userInitiated)
            #expect(answer == .failure(.offline))
            let failed = await engine.readForTests { $0.state.jobs[entry.transferID]?.state }
            #expect(failed == .failed(.whenOnline))
            if !firstReadingSatisfied {
                // The path was down when the attempt failed: the first reading says so.
                await base.send(DeviceConditions(network: NetworkConditions(satisfied: false, expensive: false, constrained: false), power: DeviceConditions.unrestricted.power))
            }
            await gated.release()
            await engine.awaitCondition { $0.state.conditions != nil }
            return Rig(engine: engine, source: source, base: base, gated: gated, entry: entry, group: group)
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("confirm S3-CONC-04: stuck through quiescence and a steady-network reading; only a real edge retries", .timeLimit(.minutes(1)))
    func stuckUntilRealEdge() async throws {
        let rig = try await Rig.make(firstReadingSatisfied: true)
        let id = rig.entry.transferID
        // Quiescent: no timer, no deadline: nothing will ever re-queue the job by itself.
        await rig.engine.waitUntil { $0.armedTimers == 0 && $0.scheduledDeadlines == 0 }
        await rig.engine.waitUntil { $0.armedTimers == 0 && $0.scheduledDeadlines == 0 && $0.watcherActive }
        #expect(await rig.engine.readForTests { $0.state.jobs[id]?.state } == .failed(.whenOnline))
        #expect(await rig.source.starts.count == 1)
        // A later reading of the same, steady network (only power changes): not an edge.
        var steady = DeviceConditions.unrestricted
        steady.power.lowPowerMode = true
        await rig.base.send(steady)
        await rig.engine.awaitCondition { $0.state.conditions?.power.lowPowerMode == true }
        #expect(await rig.engine.readForTests { $0.state.jobs[id]?.state } == .failed(.whenOnline), "a steady network leaves it failed")
        #expect(await rig.source.starts.count == 1)
        // A real edge (down, then up) revives it.
        await rig.base.send(DeviceConditions(network: NetworkConditions(satisfied: false, expensive: false, constrained: false), power: steady.power))
        await rig.engine.awaitCondition { $0.state.conditions?.network.satisfied == false }
        await rig.base.send(steady)
        await rig.engine.awaitCondition { $0.state.jobs[id]?.state != .failed(.whenOnline) }
        await rig.engine.waitUntil { $0.jobsByState[.downloading] == nil && $0.jobsByState[.queued] == nil }
        #expect(await rig.source.starts.count == 2, "the edge retried it")
        await rig.engine.releaseGroup(rig.group)
        await rig.engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("confirm S3-CONC-04 control: an unsatisfied first reading followed by a satisfied one retries the asset", .timeLimit(.minutes(1)))
    func controlUnsatisfiedFirstReading() async throws {
        let rig = try await Rig.make(firstReadingSatisfied: false)
        let id = rig.entry.transferID
        #expect(await rig.engine.readForTests { $0.state.conditions?.network.satisfied } == false)
        await rig.base.send(.unrestricted)
        await rig.engine.awaitCondition { $0.state.jobs[id]?.state != .failed(.whenOnline) }
        await rig.engine.waitUntil { $0.jobsByState[.downloading] == nil && $0.jobsByState[.queued] == nil }
        #expect(await rig.source.starts.count == 2, "the unsatisfied → satisfied edge retried it")
        await rig.engine.releaseGroup(rig.group)
        await rig.engine.shutdown()
    }
}

