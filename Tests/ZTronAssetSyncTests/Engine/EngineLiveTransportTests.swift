import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport
@testable import ZTronAssetTransport

/// Builds the real HTTP source over the store's staging sink against the loopback server (ARCHITECTURE §13.5 #1:
/// Transport is a test-only dependency of these tests).
struct LoopbackSourceFactory: RemoteSourceFactory {
    let base: URL

    func makeRemoteSource(configuration: RemoteConfiguration, staging: any StagingSink, log: LogRoute) async throws(AssetError) -> any RemoteSource {
        let policy = TransportSecurityPolicy.loopbackTesting(allowedHosts: ["127.0.0.1"])
        let delegate = SessionDelegate(mode: .foreground, staging: staging, policy: policy)
        let foreground = ForegroundTransferBackend(delegate: delegate, maxConnectionsPerHost: 4, requestTimeout: 10, appKey: nil, log: log)
        let http = HTTPSourceConfiguration(baseURL: self.base, appKey: nil, maxConnectionsPerHost: 4, requestTimeout: 10)
        return HTTPRemoteSource(configuration: http, staging: staging, policy: policy, foreground: foreground, background: nil, log: log)
    }
}

/// An engine over a store on `LiveFileSystem` in a per-test directory inside this repository, with the real
/// foreground transport against the loopback server (never the system temporary directory, ARCHITECTURE §14).
@available(macOS 15.0, iOS 18.0, *)
struct LiveEngineHarness {
    let directory: URL
    let server: LoopbackHTTPServer
    let time: ManualTimeSource
    let store: AssetStore
    let engine: SyncEngine
    let layout: StoreLayout

    /// A directory under `.build-tests/sync-engine/` (git-ignored).
    static func directory(_ name: String, filePath: String = #filePath) throws -> URL {
        let repository = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = repository
            .appendingPathComponent(".build-tests", isDirectory: true)
            .appendingPathComponent("sync-engine", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func make(_ name: String, tuning: SyncTuning, handler: @escaping LoopbackHandler) async throws -> LiveEngineHarness {
        let directory = try LiveEngineHarness.directory(name)
        let server = LoopbackHTTPServer(handler: handler)
        let port = try await server.start()
        let base = try #require(URL(string: "http://127.0.0.1:\(port)/"))
        let time = ManualTimeSource()
        let environment = AssetEnvironment(
            fileSystem: LiveFileSystem(),
            metadataExecutor: DispatchBlockingExecutor(label: "sync-tests.metadata"),
            bulkExecutor: DispatchBlockingExecutor(label: "sync-tests.bulk"),
            time: time,
            random: SeededRandom(seed: 0x11FE),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: LoopbackSourceFactory(base: base),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        let storeConfiguration = StoreConfiguration(
            location: .custom(directory),
            legacy: LegacyMigrationPolicy(enabled: false),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let store = AssetStore(configuration: storeConfiguration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
        let configuration = EngineConfiguration(
            tuning: tuning,
            storage: StoragePolicy(),
            network: NetworkPolicy(),
            power: PowerPolicy(),
            refresh: .oncePerAppVersion,
            remote: RemoteConfiguration(http: HTTPSourceConfiguration(baseURL: base)),
            limits: ManifestLimits()
        )
        let engine = SyncEngine(store: store, environment: environment, configuration: configuration)
        return LiveEngineHarness(directory: directory, server: server, time: time, store: store, engine: engine, layout: StoreLayout(base: directory))
    }

    /// Starts the engine, its owned tasks spawned at `EngineHarness.ownedTaskPriorityFloor` or above (F-17), and requires
    /// success.
    func start() async throws {
        await self.engine.setOwnedTaskPriorityFloor(EngineHarness.ownedTaskPriorityFloor)
        _ = try await self.engine.start().get()
    }

    /// Every regular file under the test directory, by path.
    func files() -> [String: Int64] {
        var result: [String: Int64] = [:]
        let enumerator = FileManager.default.enumerator(at: self.directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                result[url.standardizedFileURL.path] = Int64(values?.fileSize ?? 0)
            }
        }
        return result
    }

    /// The staging files, by name.
    func staging() -> [String: Int64] {
        let prefix = self.layout.stagingDirectory.standardizedFileURL.path + "/"
        return self.files().filter { $0.key.hasPrefix(prefix) }
    }

    /// The `CFNetworkDownload_*` files in the temporary directories a URLSession download could use (none expected:
    /// the foreground transport uses data tasks, ADR-019), by path.
    static func networkTemporaries() -> Set<String> {
        var directories = [FileManager.default.temporaryDirectory]
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            directories.append(URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true))
        }
        var paths: Set<String> = []
        for directory in directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasPrefix("CFNetworkDownload_") {
                paths.insert(directory.appendingPathComponent(name).path)
            }
        }
        return paths
    }

    /// The `CFNetworkDownload_*` files created since `before` that hold bytes of one of `bodies` (their first bytes are
    /// a run of a body, so a partial or a resumed download counts too). Other tests of the same process (the iOS
    /// Simulator runs suites in parallel) create and remove such files of their own; only this test's bodies are its
    /// bytes, and an empty file holds none.
    static func networkTemporaries(since before: Set<String>, holding bodies: [Data]) -> [String] {
        LiveEngineHarness.networkTemporaries().subtracting(before).sorted().filter { path in
            guard let handle = FileHandle(forReadingAtPath: path) else {
                return false
            }
            defer {
                try? handle.close()
            }
            let head = (try? handle.read(upToCount: 4_096)) ?? Data()
            return !head.isEmpty && bodies.contains { $0.range(of: head) != nil }
        }
    }

    /// Stops the server and removes the directory.
    func tearDown() async {
        await self.server.stop()
        try? FileManager.default.removeItem(at: self.directory)
    }
}

/// The engine over the real foreground transport (R-STO-1, R-SYN-15, R-NET-8; ADR-050).
@Suite("Engine over the live transport")
struct EngineLiveTransportTests {
    static func manifest(_ entries: [ManifestEntry]) -> LoopbackResponse {
        LoopbackResponse(body: EngineFixture.manifestData(entries))
    }

    /// The foreground transport's smallest progress quantum, read from the transport (`ProgressQuantum.minimum` in
    /// `SessionDelegate+DataTasks.swift`, transport.md §4.4; 256 KiB), so the tests follow a change of it instead of
    /// stalling on a stale copy (close-out cycle 13). The transport reports a data task's first chunk and then only a
    /// chunk that crosses a boundary of `max(minimum, expected / 64)`, so a progress event of at least `n` bytes for a
    /// prefix that stalls at `n` exists only when the first chunk held all `n` bytes (which depends on how the
    /// client's reads split the server's writes) or a chunk ends the prefix on a boundary. Each stalled prefix of
    /// these tests is therefore exactly one quantum long, and each body (`bodyLength`) is longer than the prefix and at
    /// most 64 quanta (`expected / 64` stays at most one quantum): the chunk that completes the prefix crosses the
    /// boundary and is reported with `received == stall` however the reads split, so no wait below depends on
    /// scheduling (L4-R17).
    static let progressQuantum = Int(ProgressQuantum.minimum)

    /// A body `extra` bytes longer than one quantum (`progressQuantum`).
    static func bodyLength(extra: Int) -> Int {
        Self.progressQuantum + extra
    }

    static func isProgress(of id: AssetID, atLeast bytes: Int64) -> @Sendable (AssetEvent) -> Bool {
        { event in
            if case .transferProgress(let asset, let progress) = event {
                return asset == id && progress.received >= bytes
            }
            return false
        }
    }

    static func isAvailable(_ id: AssetID) -> @Sendable (AssetEvent) -> Bool {
        { event in
            if case .assetAvailable(let asset, _) = event {
                return asset == id
            }
            return false
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-8: an invalid resume yields resumeRejected and the engine's next attempt starts fresh", .timeLimit(.minutes(1)))
    func invalidResumeStartsFresh() async throws {
        let paused = GeneratedPayload.bytes(seed: 0xB0, offset: 0, length: EngineLiveTransportTests.bodyLength(extra: 128 * 1_024))
        let page = GeneratedPayload.bytes(seed: 0xB1, offset: 0, length: 4 * 1_024)
        let pausedEntry = ManifestEntry(identifier: "paused", fileExtension: "bin", remotePath: "media/paused.bin", byteSize: Int64(paused.count), checksum: ContentHash.sha256(of: paused), policy: .onDemand)
        let pageEntry = ManifestEntry(identifier: "page", fileExtension: "bin", remotePath: "media/page.bin", byteSize: Int64(page.count), checksum: ContentHash.sha256(of: page), policy: .onDemand)
        // One progress quantum: the chunk that completes the prefix is always reported (`progressQuantum`).
        let stall = EngineLiveTransportTests.progressQuantum
        let harness = try await LiveEngineHarness.make("invalid-resume", tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0, progressInterval: 0)) { request in
            switch request.target {
            case "/manifest.json":
                return EngineLiveTransportTests.manifest([pausedEntry, pageEntry])
            case "/media/page.bin":
                return LoopbackResponse(body: page)
            default:
                switch request.pathSequence {
                case 1:
                    return LoopbackResponse(body: paused, ending: .stallAfter(bodyBytes: stall), rangeETag: "\"v1\"")
                case 2:
                    // A 206 whose range does not start at the partial's size: an invalid resume.
                    let from = 100
                    return LoopbackResponse(
                        status: 206,
                        headers: ["Content-Range": "bytes \(from)-\(paused.count - 1)/\(paused.count)", "ETag": "\"v1\""],
                        body: paused.subdata(in: from..<paused.count)
                    )
                default:
                    return LoopbackResponse(body: paused)
                }
            }
        }
        let engine = harness.engine
        try await harness.start()
        _ = await engine.sync(.force)
        let probe = EventProbe(stream: try await engine.subscribe().get())
        let group = try await engine.registerGroup(["paused"], lane: .prefetch).get()
        #expect(await probe.next(where: EngineLiveTransportTests.isProgress(of: "paused", atLeast: Int64(stall))) != nil)
        // A user request with every slot busy preempts the prefetch transfer, which pauses with a resume sidecar.
        let location = try await engine.awaitAsset("page", lane: .userInitiated).get()
        #expect(location.byteSize == Int64(page.count))
        #expect(await probe.next(where: EngineLiveTransportTests.isAvailable("paused")) != nil)
        let requests = await harness.server.requests.filter { $0.target == "/media/paused.bin" }
        #expect(requests.count == 3)
        #expect(requests.first?.header("Range") == nil)
        #expect(requests.dropFirst().first?.header("Range") == "bytes=\(stall)-", "the second attempt resumed")
        #expect(requests.last?.header("Range") == nil, "the attempt after the rejected resume starts from zero")
        let stored = try await engine.awaitAsset("paused", lane: .userInitiated).get()
        #expect(try Data(contentsOf: stored.url) == paused)
        #expect(harness.staging().isEmpty, "no partial or sidecar is left in staging")
        await engine.releaseGroup(group)
        await probe.stop()
        await engine.shutdown()
        await harness.tearDown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-STO-1: a cancelled, paused or failed foreground transfer leaves no byte outside the store root", .timeLimit(.minutes(1)))
    func transfersStayInsideTheRoot() async throws {
        let temporaries = LiveEngineHarness.networkTemporaries()
        let cancelled = GeneratedPayload.bytes(seed: 0xC0, offset: 0, length: EngineLiveTransportTests.bodyLength(extra: 128 * 1_024))
        let paused = GeneratedPayload.bytes(seed: 0xC1, offset: 0, length: EngineLiveTransportTests.bodyLength(extra: 128 * 1_024))
        let failed = GeneratedPayload.bytes(seed: 0xC2, offset: 0, length: EngineLiveTransportTests.bodyLength(extra: 128 * 1_024))
        let page = GeneratedPayload.bytes(seed: 0xC3, offset: 0, length: 2 * 1_024)
        func entry(_ id: String, _ bytes: Data) -> ManifestEntry {
            ManifestEntry(identifier: AssetID(id), fileExtension: "bin", remotePath: "media/\(id).bin", byteSize: Int64(bytes.count), checksum: ContentHash.sha256(of: bytes), policy: .onDemand)
        }
        let entries = [entry("cancelled", cancelled), entry("paused", paused), entry("failed", failed), entry("page", page)]
        // One progress quantum: the chunk that completes each prefix is always reported (`progressQuantum`).
        let stall = EngineLiveTransportTests.progressQuantum
        let harness = try await LiveEngineHarness.make("storage-root", tuning: SyncTuning(maxConcurrentTransfers: 1, reservedInteractiveSlots: 0, progressInterval: 0)) { request in
            switch request.target {
            case "/manifest.json":
                return EngineLiveTransportTests.manifest(entries)
            case "/media/cancelled.bin":
                return LoopbackResponse(body: cancelled, ending: .stallAfter(bodyBytes: stall), rangeETag: "\"c\"")
            case "/media/paused.bin":
                return LoopbackResponse(body: paused, ending: request.pathSequence == 1 ? .stallAfter(bodyBytes: stall) : .complete, rangeETag: "\"p\"")
            case "/media/failed.bin":
                return LoopbackResponse(status: 503, body: Data("unavailable".utf8))
            default:
                return LoopbackResponse(body: page)
            }
        }
        let engine = harness.engine
        try await harness.start()
        _ = await engine.sync(.force)
        let probe = EventProbe(stream: try await engine.subscribe().get())
        // Cancelled: the only interest is released while the transfer is mid-body.
        let cancelGroup = try await engine.registerGroup(["cancelled"], lane: .prefetch).get()
        #expect(await probe.next(where: EngineLiveTransportTests.isProgress(of: "cancelled", atLeast: Int64(stall))) != nil)
        await engine.releaseGroup(cancelGroup)
        await engine.waitUntil { $0.jobsByState.isEmpty }
        // Paused: a user request preempts the prefetch transfer mid-body; it resumes afterwards and completes.
        let pauseGroup = try await engine.registerGroup(["paused"], lane: .prefetch).get()
        #expect(await probe.next(where: EngineLiveTransportTests.isProgress(of: "paused", atLeast: Int64(stall))) != nil)
        _ = try await engine.awaitAsset("page", lane: .userInitiated).get()
        #expect(await probe.next(where: EngineLiveTransportTests.isAvailable("paused")) != nil)
        await engine.releaseGroup(pauseGroup)
        // Failed: a 503 on every attempt; the user-initiated caller gets the error after its retry cap.
        let clock = Task {
            // The interactive backoff passes on the manual clock: every alarm sleeper is woken (until cancelled).
            while !Task.isCancelled {
                await harness.time.waitForSleepers(atLeast: 1)
                guard !Task.isCancelled else {
                    return
                }
                if let deadline = harness.time.nextDeadline {
                    harness.time.advance(to: deadline)
                }
            }
        }
        #expect(await engine.awaitAsset("failed", lane: .userInitiated) == .failure(.serverUnavailable(retryAfter: nil)))
        clock.cancel()
        await clock.value
        await probe.stop()
        await engine.shutdown()
        let root = harness.layout.root.standardizedFileURL.path + "/"
        let outside = harness.files().keys.filter { !$0.hasPrefix(root) }
        #expect(outside.isEmpty, "files outside the store root: \(outside)")
        #expect(harness.staging().isEmpty, "the cancelled and failed partials were discarded")
        let created = LiveEngineHarness.networkTemporaries(since: temporaries, holding: [cancelled, paused, failed, page])
        #expect(created.isEmpty, "no CFNetwork temporary file holds this test's bytes: \(created)")
        #expect(await harness.server.requests.contains { $0.target == "/media/failed.bin" })
        await harness.tearDown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: no foreground staging write lands after the store is closed", .timeLimit(.minutes(1)))
    func noStagingWriteAfterClose() async throws {
        let body = GeneratedPayload.bytes(seed: 0xD0, offset: 0, length: EngineLiveTransportTests.bodyLength(extra: 256 * 1_024))
        let entry = ManifestEntry(identifier: "streamed", fileExtension: "bin", remotePath: "media/streamed.bin", byteSize: Int64(body.count), checksum: ContentHash.sha256(of: body), policy: .onDemand)
        // One progress quantum: the chunk that completes the prefix is always reported (`progressQuantum`).
        let stall = EngineLiveTransportTests.progressQuantum
        let harness = try await LiveEngineHarness.make("after-close", tuning: SyncTuning(progressInterval: 0)) { request in
            if request.target == "/manifest.json" {
                return EngineLiveTransportTests.manifest([entry])
            }
            return LoopbackResponse(body: body, ending: .stallAfter(bodyBytes: stall), rangeETag: "\"s\"")
        }
        let engine = harness.engine
        try await harness.start()
        _ = await engine.sync(.force)
        let probe = EventProbe(stream: try await engine.subscribe().get())
        _ = try await engine.registerGroup(["streamed"], lane: .prefetch).get()
        #expect(await probe.next(where: EngineLiveTransportTests.isProgress(of: "streamed", atLeast: Int64(stall))) != nil)
        await engine.shutdown()
        let afterClose = harness.staging()
        // The session would deliver the end of the body or the connection's loss now; it is invalidated.
        await harness.server.stop()
        let reopened = AssetStore(
            configuration: StoreConfiguration(location: .custom(harness.directory), legacy: LegacyMigrationPolicy(enabled: false)),
            environment: StoreEnvironment(
                environment: AssetEnvironment(
                    fileSystem: LiveFileSystem(),
                    metadataExecutor: InlineBlockingExecutor(),
                    bulkExecutor: InlineBlockingExecutor(),
                    time: harness.time,
                    random: SeededRandom(seed: 1),
                    conditions: FakeDeviceConditionsSource(),
                    remoteSources: FakeRemoteSourceFactory(source: FakeRemoteSource()),
                    appVersion: FakeAppVersionSource(),
                    legacyDefaults: FakeLegacyDefaults()
                ),
                snapshotSink: ScriptedSnapshotSink()
            )
        )
        // The closed store released its lock: a new store opens the same root.
        _ = try await reopened.open()
        #expect(harness.staging() == afterClose, "nothing was written to staging after close")
        await reopened.close()
        await probe.stop()
        await harness.tearDown()
    }
}
