import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// A snapshot sink that audits every unlink of a blob for I-3 (ARCHITECTURE §4.4; Stage 3 rulings S3C-6, S3C-7; adapted
/// from the Stage 3 crash hunters' `S3AuditSink`).
///
/// It installs like `ScriptedSnapshotSink` (acknowledging each newer snapshot, or ignoring every install) and journals,
/// against the fake volume's operation log, every install with the paths the readers' snapshot then hands out, and every
/// move of the clock the test reports (`clockMoved()`). So each unlink is placed in time exactly (the clock moves only
/// where the test says) and checked: the readers' snapshot did not hold its path when it ran, a snapshot without it had
/// been acknowledged after the last one that held it, and the deletion grace had passed on the awake clock since that
/// acknowledgement. The crash hunters' sink checked only the first; the confirmer's mutants that skip the
/// acknowledgement or the grace passed it.
@available(macOS 15.0, iOS 18.0, *)
actor CleanupAuditSink: SnapshotSink {
    /// One install as the journal keeps it.
    struct Install: Sendable {
        /// The operations the volume had logged when it ran.
        let operationsBefore: Int
        /// The awake clock then.
        let uptime: MonotonicInstant
        /// The blob paths the readers' snapshot handed out after it.
        let paths: Set<String>
        /// Whether it was acknowledged.
        let acknowledged: Bool
    }

    private let fileSystem: FakeFileSystem
    private let time: ManualTimeSource
    private let acknowledging: Bool
    private var current: AssetSnapshot = .empty
    private(set) var installs: [Install] = []
    /// The awake clock from each operation index on: one entry per install and per reported clock move.
    private var clock: [(operationsBefore: Int, uptime: MonotonicInstant)] = []

    /// A sink over `fileSystem`'s log; `acknowledging == false` ignores every install (the readers keep `.empty`).
    init(fileSystem: FakeFileSystem, time: ManualTimeSource, acknowledging: Bool = true) {
        self.fileSystem = fileSystem
        self.time = time
        self.acknowledging = acknowledging
    }

    func install(_ snapshot: AssetSnapshot) -> InstallAck {
        var retired: AssetSnapshot?
        if self.acknowledging, snapshot.key > self.current.key {
            retired = self.current
            self.current = snapshot
        }
        let paths = Set(self.current.entries.values.map(\.location.url.path))
        let uptime = self.time.uptimeNow()
        let operations = self.fileSystem.operations.count
        self.installs.append(Install(operationsBefore: operations, uptime: uptime, paths: paths, acknowledged: self.acknowledging && retired != nil))
        self.clock.append((operations, uptime))
        return InstallAck(installed: self.current.key, accesses: [:], retired: retired)
    }

    /// Records that the test moved the clock: every operation logged from now on ran at the new time.
    func clockMoved() {
        self.clock.append((self.fileSystem.operations.count, self.time.uptimeNow()))
    }

    /// The I-3 violations among `operations`' unlinks of blobs under `layout`, with `grace` the deletion grace.
    func violations(_ operations: [FSOpRecord], layout: StoreLayout, grace: TimeInterval) -> [String] {
        let prefix = layout.blobsDirectory.path + "/"
        var found: [String] = []
        for operation in operations where operation.kind == .removeItem && operation.failure == nil && operation.url.path.hasPrefix(prefix) {
            guard StoreLayout.parseBlobName(operation.url.lastPathComponent) != nil else {
                continue
            }
            let path = operation.url.path
            let name = operation.url.lastPathComponent
            let before = self.installs.filter { $0.operationsBefore <= operation.index }
            if before.last?.paths.contains(path) == true {
                found.append("I-3: op \(operation.index) unlinked \(name) while the readers' snapshot held it")
                continue
            }
            // The first acknowledged install without the path after the last one that held it.
            let held = before.lastIndex { $0.paths.contains(path) }
            let after = before[(held.map { $0 + 1 } ?? 0)...]
            guard let acknowledged = after.first(where: \.acknowledged) else {
                found.append("I-3: op \(operation.index) unlinked \(name) before a snapshot without it was acknowledged")
                continue
            }
            let at = self.clock.last { $0.operationsBefore <= operation.index }?.uptime ?? acknowledged.uptime
            if at < acknowledged.uptime.adding(seconds: grace) {
                found.append("I-3: op \(operation.index) unlinked \(name) \(at.seconds(since: acknowledged.uptime)) s after the acknowledgement, inside the \(grace) s grace")
            }
        }
        return found
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension CoreHarness {
    /// A cleanup harness whose sink is a `CleanupAuditSink` (inline executors, `CleanupFixture`'s configuration).
    static func audited(
        disk: DiskImage = DiskImage(),
        policy: StoragePolicy = CleanupFixture.policy(),
        legacy: LegacyMigrationPolicy = LegacyMigrationPolicy(enabled: false),
        defaults: FakeLegacyDefaults = FakeLegacyDefaults(),
        crashBefore: Int? = nil,
        mode: CrashMode = .processKill,
        time: ManualTimeSource = ManualTimeSource(),
        acknowledging: Bool = true
    ) -> (CoreHarness, CleanupAuditSink) {
        let fileSystem = FakeFileSystem(
            disk: disk,
            time: time,
            configuration: FakeFileSystemConfiguration(crashBefore: crashBefore, crashMode: mode)
        )
        let configuration = CleanupFixture.configuration(policy: policy, legacy: legacy)
        let sink = CleanupAuditSink(fileSystem: fileSystem, time: time, acknowledging: acknowledging)
        let tap = RecordingLogTap()
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
            logTap: tap
        )
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: sink))
        let harness = CoreHarness(
            fileSystem: fileSystem,
            time: time,
            sink: ScriptedSnapshotSink(),
            tap: tap,
            store: store,
            configuration: configuration,
            metadata: InlineBlockingExecutor()
        )
        return (harness, sink)
    }

    /// `settleDeletions()` with the clock move reported to `audit`.
    @discardableResult
    func settleDeletions(audited audit: CleanupAuditSink) async -> StoreWorkReport {
        _ = await self.store.runDueWork()
        self.time.advance(by: self.configuration.policy.deletionGrace)
        await audit.clockMoved()
        return await self.store.runDueWork()
    }
}
