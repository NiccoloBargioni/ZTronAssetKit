import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// `LiveFileSystem` against per-test directories inside this repository (ARCHITECTURE §14), never the system
/// temporary directory, never `standardDirectory` (which would create a directory outside the repository).
@Suite("Core: live file system")
struct LiveFileSystemTests {
    @Test("R-STO-6: the fake and live file systems agree on the shared conformance contract")
    @available(macOS 15.0, iOS 18.0, *)
    func conformance() throws {
        let directory = try CoreFixture.liveDirectory("conformance")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let live = FileSystemConformance.violations(of: LiveFileSystem(), in: directory)
        #expect(live.isEmpty, "\(live)")
        let fake = FakeFileSystem(time: ManualTimeSource())
        let fakeRoot = URL(fileURLWithPath: "/fake-volume/conformance", isDirectory: true)
        try fake.createDirectory(at: fakeRoot)
        let fakeViolations = FileSystemConformance.violations(of: fake, in: fakeRoot)
        #expect(fakeViolations.isEmpty, "\(fakeViolations)")
    }

    @Test("R-STO-9: the live lock rejects a second opener in the same process and frees on close", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func liveLockIsExclusive() async throws {
        let directory = try CoreFixture.liveDirectory("lock")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let configuration = CoreFixture.configuration(location: .custom(directory))
        let first = LiveStore.make(configuration)
        let second = LiveStore.make(configuration)
        _ = try await first.open()
        await #expect(throws: StoreError.locked) {
            try await second.open()
        }
        await first.close()
        let report = try await second.open()
        #expect(report.launchEpoch > 0)
        await second.close()
    }

    @Test("R-STO-6: a store over the live file system publishes, survives a reopen and keeps its blob", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func liveStoreRoundTrip() async throws {
        let directory = try CoreFixture.liveDirectory("roundtrip")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let configuration = CoreFixture.configuration(location: .custom(directory))
        let bytes = CoreFixture.bytes(42, count: 3 * 1_024 * 1_024 + 17)
        let entry = CoreFixture.entry("live.asset", bytes)
        let store = LiveStore.make(configuration)
        _ = try await store.open()
        _ = try await store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let sink = try await store.makeStagingSink()
        let name = StagingFileName(transfer: entry.transferID, attempt: TransferAttempt(epoch: 1, sequence: 1), kind: .partial)
        try sink.createPartial(name)
        _ = try sink.appendPartial(bytes, to: name)
        let staged = StagedFile(name: name, byteCount: Int64(bytes.count), resumed: false, httpStatus: 200, etag: nil)
        let locations = try await store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .userInitiated)
        let url = try #require(locations[entry.identifier]?.url)
        #expect(try Data(contentsOf: url) == bytes)
        await store.close()

        let reopened = LiveStore.make(configuration)
        let report = try await reopened.open()
        #expect(report.missingBlobs == 0 && !report.degraded)
        #expect(await reopened.location(for: entry.identifier, extensions: ["PNG"], recordingAccess: false)?.url == url)
        #expect(try LiveFileSystem().storeAttributes(at: StoreLayout(base: directory).root).excludedFromBackup)
        await reopened.close()
    }

    @Test("R-STO-6: EACCES at open surfaces storageUnavailable without mutating state", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func permissionDeniedAtOpen() async throws {
        let directory = try CoreFixture.liveDirectory("eacces")
        let base = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: base.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LiveStore.make(CoreFixture.configuration(location: .custom(base)))
        do {
            _ = try await store.open()
            Issue.record("open succeeded on an unreadable base")
        } catch {
            #expect(error == .fileSystem(.permissionDenied))
            #expect(error.assetError == .storageUnavailable(.protectedDataUnavailable))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
        await #expect(throws: StoreError.notOpen) {
            try await store.planningView()
        }
    }

    @Test("R-STO-6: the live conformer reports a directory over a file, a missing lock directory and an unreadable item")
    func liveErrorPaths() throws {
        let directory = try CoreFixture.liveDirectory("errors")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appendingPathComponent("closed").path)
            try? FileManager.default.removeItem(at: directory)
        }
        let fileSystem = LiveFileSystem()
        let file = directory.appendingPathComponent("file.bin")
        try fileSystem.write(Data([1]), to: file, mode: .truncate)
        #expect(throws: FileSystemError.alreadyExists) {
            try fileSystem.createDirectory(at: file)
        }
        #expect(throws: FileSystemError.notFound) {
            _ = try fileSystem.acquireExclusiveLock(at: directory.appendingPathComponent("missing/store.lock"))
        }
        #expect(throws: FileSystemError.notFound) {
            try fileSystem.synchronizeDirectory(at: directory.appendingPathComponent("missing"), level: .full)
        }
        #expect(throws: FileSystemError.notFound) {
            _ = try fileSystem.storeAttributes(at: directory.appendingPathComponent("missing"))
        }
        #expect(throws: FileSystemError.notFound) {
            try fileSystem.applyStoreAttributes(.storeDefault, at: directory.appendingPathComponent("missing"))
        }
        let closed = directory.appendingPathComponent("closed", isDirectory: true)
        try fileSystem.createDirectory(at: closed)
        try fileSystem.write(Data([2]), to: closed.appendingPathComponent("inner.bin"), mode: .truncate)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
        #expect(throws: FileSystemError.permissionDenied) {
            _ = try fileSystem.itemInfo(at: closed.appendingPathComponent("inner.bin"))
        }
        #expect(throws: FileSystemError.permissionDenied) {
            _ = try fileSystem.contentsOfDirectory(at: closed)
        }
        #expect(throws: FileSystemError.permissionDenied) {
            try fileSystem.write(Data([3]), to: closed.appendingPathComponent("new.bin"), mode: .append)
        }
        #expect(throws: FileSystemError.permissionDenied) {
            try fileSystem.removeItem(at: closed.appendingPathComponent("inner.bin"))
        }
        #expect(throws: FileSystemError.permissionDenied) {
            try fileSystem.rename(from: closed.appendingPathComponent("inner.bin"), to: directory.appendingPathComponent("out.bin"), mode: .replacing)
        }
        #expect(try fileSystem.read(from: file, offset: 0, maxLength: 0).isEmpty)
    }

    @Test("R-STO-6: the live conformer reports a capacity query on a vanished root and a refused attribute write as typed errors")
    func liveCapacityAndAttributeFailures() throws {
        let directory = try CoreFixture.liveDirectory("capacity")
        let locked = directory.appendingPathComponent("locked.bin")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let fileSystem = LiveFileSystem()
        // `freeSpace()` over a root that vanished surfaces a typed error, never a bogus figure.
        #expect(throws: FileSystemError.notFound) {
            _ = try fileSystem.availableCapacity(at: directory.appendingPathComponent("vanished", isDirectory: true), for: .important)
        }
        #expect(try fileSystem.availableCapacity(at: directory, for: .opportunistic) > 0)
        // Backup exclusion is an extended attribute: on an item the process may not write it is refused with an error
        // of the closed taxonomy. Foundation reports it as NSFileWriteUnknownError over an OSStatus on this macOS (so
        // `.io`, an unknown write failure); a release that reports NSFileWriteNoPermissionError maps to
        // `.permissionDenied`.
        try fileSystem.write(Data([1]), to: locked, mode: .truncate)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.path)
        let refused = #expect(throws: FileSystemError.self) {
            try fileSystem.applyStoreAttributes(.storeDefault, at: locked)
        }
        #expect(refused == .io || refused == .permissionDenied, "\(String(describing: refused))")
        #expect(try fileSystem.storeAttributes(at: locked).excludedFromBackup == false, "nothing was applied")
    }
}

/// Builds stores over `LiveFileSystem` for the live tests.
@available(macOS 15.0, iOS 18.0, *)
enum LiveStore {
    static func make(_ configuration: StoreConfiguration) -> AssetStore {
        let environment = AssetEnvironment(
            fileSystem: LiveFileSystem(),
            metadataExecutor: DispatchBlockingExecutor(label: "test.metadata"),
            bulkExecutor: DispatchBlockingExecutor(label: "test.bulk"),
            time: ManualTimeSource(),
            random: SeededRandom(seed: 11),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: FakeRemoteSource()),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        return AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
    }
}
