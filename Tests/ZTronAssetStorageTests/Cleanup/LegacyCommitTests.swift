import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Legacy phase 1 commits inside `open()`, before its root barrier (ADR draft B-36, close-out cycle 5): the store must
/// count committed only what a root sync ordered, in a file that holds it.
@Suite("Cleanup: legacy phase 1 and the launch's committed count (R-STO-5, B-36)")
struct LegacyCommitTests {
    @Test(
        "R-STO-5: a legacy phase-1 commit before open()'s barrier with a pending promotion and a failed root sync never counts the surviving generation, and committedFile names a file that holds what it counts",
        .timeLimit(.minutes(1))
    )
    @available(macOS 15.0, iOS 18.0, *)
    func phaseOneCommitBeforeBarrier() async throws {
        // index.bin holds generation 10, index.prev 9, index.tmp a synced 11: the load chooses index.tmp, so 11 waits for
        // its promotion and 10 is the surviving generation.
        let legacyRoot = IndexSpace.volume.appendingPathComponent("CDNAssets", isDirectory: true)
        let bytes = CoreFixture.bytes(800)
        var entry = CoreFixture.entry("legacy.one", bytes)
        entry.localPathComponents = ["D"]
        entry.localFileName = "one"
        let files: [String: Data] = [
            "manifest.json": try LegacyFixture.manifestJSON([entry]),
            "D/one.png": bytes,
        ]
        let disk = try LegacyFixture.disk(files, root: legacyRoot, base: IndexSpace.disk(IndexSpaceSlice(bin: .committed, previous: .older, temporary: .newer)))
        let fileSystem = IndexSpace.fake(disk)
        // The first root sync of the lifetime (the phase-1 commit's promotion) fails; open()'s barrier then succeeds; the
        // launch commit cannot write index.tmp, so the store serves what the phase-1 commit left it counting.
        fileSystem.addFault(FaultRule(operation: .synchronizeDirectory, matching: URLMatcher(lastComponentSuffix: "v1"), occurrence: .nth(1), error: .io))
        fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .every, error: .noSpace))
        let configuration = StoreConfiguration(
            location: .custom(IndexSpace.volume),
            policy: CleanupFixture.policy(),
            legacy: LegacyMigrationPolicy(enabled: true, root: legacyRoot),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let time = ManualTimeSource()
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: IndexSpace.seed),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: FakeRemoteSource()),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults(values: [CleanupFixture.legacyKey: "2+2"])
        )
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
        let report = try await store.open()
        #expect(report.legacyMigrationPending)
        let operations = fileSystem.operations
        let rootSyncs = operations.filter { $0.kind == .synchronizeDirectory && $0.url == IndexSpace.layout.root }
        let promotion = try #require(operations.first { $0.kind == .rename && $0.url.lastPathComponent == "index.tmp" })
        #expect(rootSyncs.count >= 2 && rootSyncs[0].failure == .io && rootSyncs[1].failure == nil, "phase 1's root sync failed, the barrier succeeded")
        #expect(promotion.index < rootSyncs[0].index, "the phase-1 commit promoted the loaded index.tmp before the barrier")
        let core = await store.state.core
        #expect(core.committedGeneration != 10, "the surviving generation was renamed over and is not counted")
        let survivor = fileSystem.survivingDisk()
        if let file = core.commits.committedFile {
            let holding = try #require(survivor.files[IndexSpace.path(file)])
            #expect(try IndexCodec.decode(holding).get().generation == core.committedGeneration)
        } else {
            #expect(core.committedGeneration == 0)
        }
        // Whatever the store counted survives a kill and a power loss: the next launch loads it or a newer generation.
        for mode in [CrashMode.processKill, .powerLossDropUnsynced, .powerLossKeepMetadata] {
            let view = IndexSpace.surviving(survivor, mode)
            let files = Dictionary(uniqueKeysWithValues: IndexFile.allCases.compactMap { file in
                view.files[IndexSpace.path(file)].map { (file, IndexFileRead(size: Int64($0.count), bytes: $0)) }
            })
            let loaded = IndexLoadRule.choose(files)
            #expect((loaded.content?.generation ?? 0) >= core.committedGeneration, "\(mode)")
        }
    }
}
