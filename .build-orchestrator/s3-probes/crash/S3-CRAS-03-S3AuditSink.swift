import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// S3 probe support: a sink that installs like `ScriptedSnapshotSink(.acknowledge)` and remembers, for every install,
/// how many file-system operations had run and which blob paths the readers' snapshot handed out afterwards and the
/// uptime of the install, so an op log can be audited for I-3 (no unlink of a path the readers' current snapshot
/// holds, and none before the grace after the first acknowledged snapshot without it).
@available(macOS 15.0, iOS 18.0, *)
actor S3AuditSink: SnapshotSink {
    struct Install: Sendable {
        let operationsBefore: Int
        let uptime: MonotonicInstant
        let paths: Set<String>
    }

    private var current: AssetSnapshot = .empty
    private(set) var installs: [Install] = []
    private let fileSystem: FakeFileSystem
    private let time: ManualTimeSource

    init(fileSystem: FakeFileSystem, time: ManualTimeSource) {
        self.fileSystem = fileSystem
        self.time = time
    }

    func install(_ snapshot: AssetSnapshot) -> InstallAck {
        var retired: AssetSnapshot?
        if snapshot.key > self.current.key {
            retired = self.current
            self.current = snapshot
        }
        let paths = Set(self.current.entries.values.map(\.location.url.path))
        self.installs.append(Install(operationsBefore: self.fileSystem.operations.count, uptime: self.time.uptimeNow(), paths: paths))
        return InstallAck(installed: self.current.key, accesses: [:], retired: retired)
    }

    /// I-3 violations in `operations`: an unlink of a blob path that the readers' snapshot at that moment held.
    func violations(_ operations: [FSOpRecord], layout: StoreLayout) -> [String] {
        let prefix = layout.blobsDirectory.path + "/"
        var found: [String] = []
        for operation in operations where operation.kind == .removeItem && operation.url.path.hasPrefix(prefix) {
            guard StoreLayout.parseBlobName(operation.url.lastPathComponent) != nil else {
                continue
            }
            let path = operation.url.path
            let before = self.installs.last { $0.operationsBefore <= operation.index }
            if let before, before.paths.contains(path) {
                found.append("I-3: op \(operation.index) unlinked \(operation.url.lastPathComponent) while the readers' snapshot held it")
            }
        }
        return found
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension CoreHarness {
    /// A cleanup harness whose sink is an `S3AuditSink`.
    static func audited(
        disk: DiskImage = DiskImage(),
        policy: StoragePolicy = CleanupFixture.policy(),
        legacy: LegacyMigrationPolicy = LegacyMigrationPolicy(enabled: false),
        defaults: FakeLegacyDefaults = FakeLegacyDefaults(),
        crashBefore: Int? = nil,
        mode: CrashMode = .processKill,
        time: ManualTimeSource = ManualTimeSource()
    ) -> (CoreHarness, S3AuditSink) {
        let fileSystem = FakeFileSystem(
            disk: disk,
            time: time,
            configuration: FakeFileSystemConfiguration(crashBefore: crashBefore, crashMode: mode)
        )
        let configuration = CleanupFixture.configuration(policy: policy, legacy: legacy)
        let sink = S3AuditSink(fileSystem: fileSystem, time: time)
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 0x5EED),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: FakeRemoteSource()),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: defaults,
            logTap: RecordingLogTap()
        )
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: sink))
        let harness = CoreHarness(
            fileSystem: fileSystem,
            time: time,
            sink: ScriptedSnapshotSink(),
            tap: RecordingLogTap(),
            store: store,
            configuration: configuration,
            metadata: InlineBlockingExecutor()
        )
        return (harness, sink)
    }
}
