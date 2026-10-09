import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import os

private func hash(_ seed: UInt8) -> ContentHash {
    ContentHash.sha256(of: Data([seed]))
}

private func entry(
    _ id: String,
    remotePath: String? = nil,
    byteSize: Int64? = nil,
    checksum: ContentHash? = nil,
    directories: [String] = []
) -> ManifestEntry {
    ManifestEntry(
        identifier: AssetID(id),
        fileExtension: "png",
        remotePath: remotePath ?? "media/\(id).png",
        localPathComponents: directories,
        byteSize: byteSize,
        checksum: checksum
    )
}

private func manifest(_ entries: [ManifestEntry]) throws -> ValidatedManifest {
    try ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data(entries.map(\.identifier.rawValue).joined().utf8)))
}

@Suite("Model contracts")
struct ModelContractTests {
    @Test("R-MAN-5: a checksum-less entry changes content identity only when its remotePath changes")
    func legacyIdentityFollowsRemotePathOnly() {
        let original = entry("a.b.icon", remotePath: "media/x/icon.png", byteSize: 100)
        var resized = original
        resized.byteSize = 200
        var moved = original
        moved.localPathComponents = ["Other"]
        var renamedRemote = original
        renamedRemote.remotePath = "media/y/icon.png"

        #expect(ManifestDiff.classify(old: original, new: resized) == .metadataChanged)
        #expect(ManifestDiff.classify(old: original, new: moved) == .metadataChanged)
        #expect(ManifestDiff.classify(old: original, new: renamedRemote) == .contentChanged)
        // The single-flight key agrees with the diff (ADR-034).
        #expect(resized.transferID == original.transferID)
        #expect(renamedRemote.transferID != original.transferID)
    }

    @Test("R-MAN-4: applying diff(a, b) to a yields b and every identifier is classified exactly once")
    func diffAppliesAndPartitions() throws {
        let a = try manifest([
            entry("keep", checksum: hash(1)),
            entry("move", checksum: hash(2), directories: ["Old"]),
            entry("change", checksum: hash(3)),
            entry("drop", checksum: hash(4)),
        ])
        let b = try manifest([
            entry("added", checksum: hash(5)),
            entry("change", checksum: hash(6)),
            entry("keep", checksum: hash(1)),
            entry("move", checksum: hash(2), directories: ["New"]),
        ])
        let diff = ManifestDiff.compute(from: a, to: b)

        #expect(diff.added == ["added"])
        #expect(diff.removed == ["drop"])
        #expect(diff.contentChanged == ["change"])
        #expect(diff.metadataChanged == ["move"])
        #expect(diff.unchanged == ["keep"])
        let all = diff.added + diff.removed + diff.contentChanged + diff.metadataChanged + diff.unchanged
        #expect(Set(all).count == all.count)
        #expect(Set(all) == Set(a.entries.map(\.identifier)).union(b.entries.map(\.identifier)))
        #expect(diff.applied(to: a) == b.entries)
        #expect(ManifestDiff.compute(from: a, to: a).isEmpty)
    }

    @Test("R-NET-1: TransferID accepts only [0-9a-z-] up to 96 bytes with a known prefix")
    func transferIDValidation() {
        #expect(TransferID(rawValue: "c-" + hash(1).hex) != nil)
        #expect(TransferID(rawValue: "m-manifest") == TransferID.manifest)
        #expect(TransferID(rawValue: "") == nil)
        #expect(TransferID(rawValue: "c-ABC") == nil)
        #expect(TransferID(rawValue: "c-../x") == nil)
        #expect(TransferID(rawValue: "c-a.b") == nil)
        #expect(TransferID(rawValue: "x-" + hash(1).hex) == nil)
        #expect(TransferID(rawValue: "c-" + String(repeating: "a", count: 95)) == nil)
        #expect(TransferID.content(hash(1)).kind == .content)
        #expect(TransferID.legacy(identifier: "a", remotePath: "p").kind == .legacy)
    }

    @Test("R-NET-1: StagingFileName round-trips through its parser and rejects foreign names")
    func stagingNamesRoundTrip() throws {
        let attempt = TransferAttempt(epoch: 7, sequence: 3)
        for kind in StagingFileName.Kind.allCases {
            let name = StagingFileName(transfer: .content(hash(9)), attempt: attempt, kind: kind)
            #expect(StagingFileName(parsing: name.rawValue) == name)
            let encoded = try JSONEncoder().encode(name)
            #expect(try JSONDecoder().decode(StagingFileName.self, from: encoded) == name)
        }
        for foreign in ["CFNetworkDownload_ab12.tmp", "x.part", "c-ab.7-3.part.extra", "c-ab.-3.part", "c-ab.7-3.bin", ""] {
            #expect(StagingFileName(parsing: foreign) == nil)
        }
    }

    @Test("R-NET-5: ETag rejects empty values, values over 256 bytes and control characters")
    func etagValidation() {
        #expect(ETag(rawValue: "\"v1-abc\"")?.rawValue == "\"v1-abc\"")
        #expect(ETag(rawValue: "W/\"weak\"") != nil)
        #expect(ETag(rawValue: String(repeating: "a", count: 256)) != nil)
        #expect(ETag(rawValue: String(repeating: "a", count: 257)) == nil)
        #expect(ETag(rawValue: "") == nil)
        #expect(ETag(rawValue: "a\nb") == nil)
        #expect(ETag(rawValue: "caf\u{E9}") == nil)
    }

    @Test("R-SEC-1: AppKey and ResumeData redact themselves under description, reflection and dump")
    func secretsRedact() {
        let canary = "CANARY-8d1f6c"
        let key = AppKey(canary)
        let resume = ResumeData(bytes: Data(canary.utf8))
        var dumped = ""
        dump(key, to: &dumped)
        dump(resume, to: &dumped)
        let rendered = [
            String(describing: key), String(reflecting: key), "\(key)",
            String(describing: resume), String(reflecting: resume), dumped,
        ]
        for text in rendered {
            #expect(!text.contains(canary))
        }
        #expect(Mirror(reflecting: key).children.isEmpty)
        #expect(Mirror(reflecting: resume).children.isEmpty)
    }

    @Test("R-NET-6: every TransferError maps to one failure class and the documented AssetError")
    func transferErrorMapping() {
        let now = Date(timeIntervalSince1970: 1_000)
        let evidence = ForbiddenEvidence(purpose: .asset, bodyBytes: 0, contentTypeIsXML: false, keyPresented: true, resumed: false)
        let table: [(TransferError, FailureClass?, AssetError)] = [
            (.offline(.noConnection), .offline, .offline),
            (.transient(.timedOut, retryAfter: nil), .transient, .serverUnavailable(retryAfter: nil)),
            (.transient(.serverError(httpStatus: 503), retryAfter: .seconds(7)), .serverError, .serverUnavailable(retryAfter: 7)),
            (.transient(.throttled, retryAfter: .date(now.addingTimeInterval(30))), .throttled, .serverUnavailable(retryAfter: 30)),
            (.permanentMissing(httpStatus: 404), .notFound, .notFound),
            (.authentication(.forbiddenAmbiguous(evidence)), .authentication, .authRejected(.ambiguous)),
            (.integrity(.truncated(expected: 10, received: 4)), .integrity, .integrityFailure),
            (.insufficientSpace(requiredBytes: 5), .insufficientSpace, .insufficientSpace(required: 5, available: 0)),
            (.rejected(.hostNotAllowed), .rejected, .serverUnavailable(retryAfter: nil)),
            (.cancelled(.byClient), nil, .cancelled),
        ]
        for (error, failureClass, assetError) in table {
            #expect(error.failureClass == failureClass)
            #expect(error.assetError(now: now) == assetError)
        }
        #expect(evidence.hint == .keyRejectedLikely)
        #expect(RetryAfter.date(now.addingTimeInterval(-5)).seconds(from: now) == 0)
    }

    @Test("DispatchBlockingExecutor runs units on its own queue and preserves typed errors", .timeLimit(.minutes(1)))
    func dispatchExecutorRunsOffThePool() async {
        let executor = DispatchBlockingExecutor(label: "com.ztron.assetkit.test-executor")
        let label = await executor.run { String(cString: __dispatch_queue_get_label(nil)) }
        #expect(label == "com.ztron.assetkit.test-executor")
        do throws(FileSystemError) {
            _ = try await executor.run(throwing: { () throws(FileSystemError) -> Int in throw .noSpace })
            Issue.record("the unit's error was not rethrown")
        } catch {
            #expect(error == .noSpace)
        }
        let value = try? await executor.run(throwing: { () throws(FileSystemError) -> Int in 7 })
        #expect(value == 7)
    }

    @Test("MonotonicInstant.adding saturates infinite and near-maximal deltas instead of returning now or trapping")
    func monotonicSaturation() {
        let start = MonotonicInstant(nanoseconds: 5)
        #expect(start.adding(seconds: .infinity).nanoseconds == UInt64.max)
        #expect(start.adding(seconds: .nan) == start)
        #expect(start.adding(seconds: -1) == start)
        #expect(start.adding(seconds: 0) == start)
        #expect(start.adding(seconds: 1).nanoseconds == 1_000_000_005)
        let nearEnd = MonotonicInstant(nanoseconds: UInt64.max - 1_000)
        #expect(nearEnd.adding(seconds: 0.000_002).nanoseconds == UInt64.max)
        #expect(MonotonicInstant(nanoseconds: UInt64.max - 10).adding(seconds: 1.7e10).nanoseconds == UInt64.max)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-OBS-1: log lines carry the module subsystem and their category and render identifiers as stable hashes")
    func logLinesAreTaggedAndHashed() {
        let id = AssetID("bo7.ri.secret-page")
        let rendered = AssetLog.hashed(id)
        #expect(!rendered.contains(id.rawValue))
        #expect(rendered == AssetLog.hashed(AssetID("bo7.ri.secret-page")))
        #expect(rendered != AssetLog.hashed(AssetID("bo7.ri.other-page")))
        #expect(rendered.count == 19 && rendered.hasPrefix("id#"))
        #expect(AssetLog.subsystem == "com.ztron.assetkit")
        #expect(LogLine(category: .apple, level: .info, message: "x").subsystem == AssetLog.subsystem)
        let tap = RecordingLogTap()
        AssetLog.log(.store, .debug, "evicted \(rendered)", sink: TapOnlyLogSink(), tap: tap)
        #expect(tap.lines == [LogLine(subsystem: "com.ztron.assetkit", category: .store, level: .debug, message: "evicted \(rendered)")])
        #expect(LogLevel.allCases.map(\.osLogType) == [.debug, .info, .error, .fault])
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-OBS-1: every line reaches the environment's sink and tap once, and an environment of fakes keeps the unified log untouched")
    func logRouteReachesSinkAndTap() {
        let sink = RecordingLogSink()
        let tap = RecordingLogTap()
        let route = LogRoute(sink: sink, tap: tap)
        route.log(.transport, .error, "refused \(AssetLog.hashed(AssetID("bo7.a")))")
        let expected = LogLine(category: .transport, level: .error, message: "refused \(AssetLog.hashed(AssetID("bo7.a")))")
        #expect(sink.lines == [expected])
        #expect(tap.lines == [expected])

        let time = ManualTimeSource()
        let environment = AssetEnvironment(
            fileSystem: FakeFileSystem(time: time),
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 7),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: FakeRemoteSource()),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults(),
            logTap: tap
        )
        #expect(environment.logSink is TapOnlyLogSink)
        #expect(environment.logRoute.signposter(.store) == nil)
        environment.logRoute.log(.store, .info, "reaped 3")
        #expect(tap.lines.last == LogLine(category: .store, level: .info, message: "reaped 3"))
        #expect(tap.lines.count == 2)
        #expect(LogRoute.tapOnly(nil).sink is TapOnlyLogSink)
        #expect(OSLogSink().signposter(.sync) != nil)
    }

    @Test("R-SYN-11: the eviction switch defaults to permitted and an out-of-range snapshot install interval is clamped")
    func storagePolicyAndTuningKnobs() {
        #expect(StoragePolicy().evictionPermitted)
        #expect(!StoragePolicy(evictionPermitted: false).evictionPermitted)
        let negative = SyncTuning(snapshotInstallInterval: -1).clamped()
        #expect(negative.tuning.snapshotInstallInterval == 0.1)
        #expect(negative.clampedFields == ["snapshotInstallInterval"])
        let notANumber = SyncTuning(snapshotInstallInterval: .nan).clamped()
        #expect(notANumber.tuning.snapshotInstallInterval == 0.1)
        let valid = SyncTuning(snapshotInstallInterval: 0.25).clamped()
        #expect(valid.tuning.snapshotInstallInterval == 0.25)
        #expect(valid.clampedFields.isEmpty)
    }
}

/// A `LogSink` that records what it is asked to write (the R-OBS-1 route test); gated for `Mutex` (ADR-014).
@available(macOS 15.0, iOS 18.0, *)
private final class RecordingLogSink: LogSink {
    private let recorded = Mutex<[LogLine]>([])

    func write(_ line: LogLine) {
        self.recorded.withLock { $0.append(line) }
    }

    func signposter(_ category: LogCategory) -> OSSignposter? {
        nil
    }

    var lines: [LogLine] {
        self.recorded.withLock { $0 }
    }
}
