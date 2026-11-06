import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

extension ZTronAssetKitBenchmarks.StorageBenchmarks {
    /// S3-PERF probe: the store's cost of a run of user-initiated publications (what `ensureAvailable` drives, R-SYN-10)
    /// grows linearly with the catalog. Each `.userInitiated` publication installs a snapshot whose `entries` is the
    /// store's `presentTable` (shared, copy-on-write) and the sink keeps it, so the next publication's
    /// `refreshPresentEntry` copies the whole present table on the store's actor: O(present) per publication, O(n²) per
    /// run. The ratio of a doubled run against P-4's `doubling_ratio_max` (the only scaling budget for a store-side run),
    /// bulk publications (installs at most every `snapshotInstallInterval`) printed beside it as the control.
    @Test("R-SYN-10: user-initiated publications of a doubled catalog cost the store at most doubling_ratio_max times as much", .timeLimit(.minutes(3)))
    @available(macOS 15.0, iOS 18.0, *)
    func userInitiatedPublicationScaling() async throws {
        let ratioMax = try #require(try QualityBudgets().value("P-4", "doubling_ratio_max"))
        _ = try await S3PublishProbe.publishSeconds(count: 500, urgency: .userInitiated)
        var user: [Int: Double] = [:]
        var bulk: [Int: Double] = [:]
        for count in [2_500, 5_000, 10_000] {
            user[count] = try await S3PublishProbe.publishSeconds(count: count, urgency: .userInitiated)
            bulk[count] = try await S3PublishProbe.publishSeconds(count: count, urgency: .bulk)
        }
        let userRatio = try #require(user[10_000]) / max(try #require(user[5_000]), 1e-9)
        let bulkRatio = try #require(bulk[10_000]) / max(try #require(bulk[5_000]), 1e-9)
        print("S3-PERF publish scaling: user-initiated \(user.sorted { $0.key < $1.key }) s (10,000 / 5,000 = \(userRatio)); bulk \(bulk.sorted { $0.key < $1.key }) s (ratio \(bulkRatio)); max \(ratioMax)")
        #expect(userRatio <= ratioMax, "user-initiated publications: \(userRatio)× for a doubled catalog")
    }
}

/// Helpers of the S3-PERF publish probe.
enum S3PublishProbe {
    /// Seconds spent publishing `count` 32-byte assets of a `count`-entry manifest at `urgency`, one after another, on
    /// a fake volume with inline executors and a sink that keeps the installed snapshot (as `SnapshotMirror` does).
    @available(macOS 15.0, iOS 18.0, *)
    static func publishSeconds(count: Int, urgency: AssetPriority, retaining: Bool = true) async throws -> Double {
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(time: time)
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 7),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: FakeRemoteSource()),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        let store = AssetStore(
            configuration: StoreConfiguration(legacy: LegacyMigrationPolicy(enabled: false), commitMinimumInterval: 0),
            environment: StoreEnvironment(environment: environment, snapshotSink: retaining ? ScriptedSnapshotSink() as any SnapshotSink : S3KeyOnlySink())
        )
        let payloads = (0..<count).map { GeneratedPayload.bytes(seed: UInt64(50_000 + $0), offset: 0, length: 32) }
        let entries = payloads.enumerated().map { index, bytes in
            ManifestEntry(identifier: AssetID("pub.\(index)"), fileExtension: "bin", remotePath: "media/\(index).bin", byteSize: 32, checksum: ContentHash.sha256(of: bytes))
        }
        let report = try await store.open()
        _ = try await store.apply(try ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data("pub".utf8))), etag: nil, eviction: nil)
        let sink = try await store.makeStagingSink()
        let clock = ContinuousClock()
        var total = Duration.zero
        for (index, (entry, bytes)) in zip(entries, payloads).enumerated() {
            let name = StagingFileName(transfer: entry.transferID, attempt: TransferAttempt(epoch: report.launchEpoch, sequence: UInt32(index + 1)), kind: .partial)
            try sink.createPartial(name)
            _ = try sink.appendPartial(bytes, to: name)
            let start = clock.now
            _ = try await store.publish(
                StagedFile(name: name, byteCount: 32, resumed: false, httpStatus: 200, etag: nil),
                binding: [entry.identifier],
                expecting: entry.contentIdentity,
                urgency: urgency
            )
            total += clock.now - start
        }
        await store.close()
        return Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18
    }
}

/// Confirmation control (S3-PERF-05): acknowledges every snapshot without keeping it, so the store's present table is
/// uniquely referenced again once `install` returns.
actor S3KeyOnlySink: SnapshotSink {
    func install(_ snapshot: AssetSnapshot) -> InstallAck {
        InstallAck(installed: snapshot.key, accesses: [:])
    }
}

extension ZTronAssetKitBenchmarks.StorageBenchmarks {
    /// Confirmation control (S3-PERF-05): the same user-initiated run with a sink that does not keep the snapshot.
    @Test("S3CONF-05: user-initiated publications with a non-retaining sink", .timeLimit(.minutes(3)))
    @available(macOS 15.0, iOS 18.0, *)
    func userInitiatedPublicationScalingNoRetain() async throws {
        _ = try await S3PublishProbe.publishSeconds(count: 500, urgency: .userInitiated, retaining: false)
        var user: [Int: Double] = [:]
        var kept: [Int: Double] = [:]
        for count in [2_500, 5_000, 10_000] {
            user[count] = try await S3PublishProbe.publishSeconds(count: count, urgency: .userInitiated, retaining: false)
            kept[count] = try await S3PublishProbe.publishSeconds(count: count, urgency: .userInitiated, retaining: true)
        }
        let ratio = try #require(user[10_000]) / max(try #require(user[5_000]), 1e-9)
        let keptRatio = try #require(kept[10_000]) / max(try #require(kept[5_000]), 1e-9)
        print("S3CONF-05 user-initiated, sink not retaining: \(user.sorted { $0.key < $1.key }) s (10,000 / 5,000 = \(ratio)); sink retaining (same run): \(kept.sorted { $0.key < $1.key }) s (ratio \(keptRatio))")
        #expect(ratio > 0)
    }
}
