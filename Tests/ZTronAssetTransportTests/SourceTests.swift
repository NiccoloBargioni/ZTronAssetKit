import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import ZTronAssetTransport

/// The production `HTTPRemoteSource` as the composition root builds it, and the ADR-026 routing between its two
/// backends (R-NET-3, R-NET-4).
@Suite("HTTP remote source")
struct SourceTests {
    static let base = URL(string: "https://cdn.example.com/assets/")!

    @available(macOS 15.0, *)
    @Test("R-NET-4: the production source allows only HTTPS to its base host and the configured additional hosts", .timeLimit(.minutes(1)))
    func productionSource() async throws {
        let configuration = HTTPSourceConfiguration(
            baseURL: Self.base,
            appKey: TransportFixtures.canaryKey,
            additionalAllowedHosts: ["Media.Example.com."],
            maxConnectionsPerHost: 12
        )
        let staging = FakeStagingSink()
        let source = HTTPRemoteSource(configuration: configuration, staging: staging, log: .tapOnly(nil))
        #expect(source.policy.allowedHosts == ["cdn.example.com", "media.example.com"])
        #expect(source.policy.plaintext == .never)
        #expect(source.background == nil)
        #expect(source.originID == "https://cdn.example.com:443")
        #expect(source.capabilities == RemoteSourceCapabilities(tier: .aws, supportsPriority: true, supportsResume: true, supportsBackground: false, keepsSourceCopies: false))
        let foreground = try #require(source.foreground as? ForegroundTransferBackend)
        #expect(foreground.session.configuration.httpMaximumConnectionsPerHost == 8)
        #expect(foreground.delegate.mode == .foreground)
        #expect(await source.reclaimSourceCopies(AdoptionReport(manifestRemotePaths: ["a"], adoptedRemotePaths: ["a"])) == ReclaimReport())
        #expect(await source.sourceCopyBytes() == 0)
        #expect(await source.reattachedTransfers().isEmpty)
        // Without a background session there is nothing to cancel: staging is left alone.
        let name = StagingFileName(transfer: TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(1), kind: .partial)
        try staging.createPartial(name)
        _ = try staging.appendPartial(Data("kept".utf8), to: name)
        await source.cancelTransfer(name)
        #expect(staging.contents == [name: Data("kept".utf8)])
        await source.invalidate()
    }

    @available(macOS 15.0, *)
    @Test("R-NET-4: the production source refuses a plain-HTTP base URL before any request", .timeLimit(.minutes(1)))
    func productionRefusesPlainHTTP() async throws {
        let configuration = HTTPSourceConfiguration(baseURL: URL(string: "http://127.0.0.1:9/")!, appKey: TransportFixtures.canaryKey)
        let source = HTTPRemoteSource(configuration: configuration, staging: FakeStagingSink(), log: .tapOnly(nil))
        let request = TransferRequest(id: TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(1), remotePath: "a.bin", expectedBytes: 1, maxBytes: 10, priority: .prefetch)
        #expect(await run(await source.transfer(request)).terminal == .failed(.rejected(.insecureScheme)))
        await #expect(throws: TransferError.rejected(.insecureScheme)) {
            try await source.fetchManifest(ManifestRequest(ifNoneMatch: nil, maxBytes: 10, attempt: TransportFixtures.attempt(2)))
        }
        await source.invalidate()
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: an enabled background policy builds a coordinator and reports background support without creating a session", .timeLimit(.minutes(1)))
    func productionBackground() async throws {
        let options = BackgroundTransferOptions(namespace: "media", keyRedirectExposure: .acceptedByOwner)
        let configuration = HTTPSourceConfiguration(baseURL: Self.base, appKey: TransportFixtures.canaryKey, background: .enabled(options))
        let source = HTTPRemoteSource(configuration: configuration, staging: FakeStagingSink(), log: .tapOnly(nil))
        let coordinator = try #require(source.background as? BackgroundTransferCoordinator)
        #expect(coordinator.options == options)
        #expect(source.capabilities.supportsBackground)
        let driver = try #require(coordinator.driver as? LiveBackgroundSessionDriver)
        #expect(driver.identifier.rawValue == "com.ztron.assetkit.bg.media.v1")
        // The session is created by the coordinator's first activation, after the store opened (ADR-028).
        #expect(await !driver.hasSession)
        // What that activation will configure (transport.md §10.4): building a configuration creates no session.
        let made = BackgroundSessionConfiguration.make(identifier: driver.identifier, discretionary: driver.discretionary)
        #expect(made.identifier == "com.ztron.assetkit.bg.media.v1")
        #expect(made.isDiscretionary == options.discretionary && made.sessionSendsLaunchEvents)
        #expect(made.urlCache == nil && made.httpCookieStorage == nil && !made.httpShouldSetCookies && made.urlCredentialStorage == nil)
        #expect(made.httpAdditionalHeaders?.isEmpty == true)
        #expect(made.httpMaximumConnectionsPerHost == 4)
    }

    @available(macOS 15.0, *)
    @Test("R-SYN-5: a base URL without a host falls back to its text as the origin identifier the circuit breaker is keyed by")
    func originFallback() {
        let source = HTTPRemoteSource(configuration: HTTPSourceConfiguration(baseURL: URL(string: "file:///srv/assets/")!), staging: FakeStagingSink(), log: .tapOnly(nil))
        #expect(source.originID == "file:///srv/assets/")
    }

    @available(macOS 15.0, *)
    @Test("R-NET-4: a backend built without a key sends none and still stages", .timeLimit(.minutes(1)))
    func keylessBackend() async throws {
        let server = LoopbackHTTPServer { _ in LoopbackResponse(body: Data("ok".utf8)) }
        let port = try await server.start()
        let staging = FakeStagingSink()
        let policy = TransportSecurityPolicy.loopbackTesting(allowedHosts: ["127.0.0.1"])
        let backend = ForegroundTransferBackend(
            delegate: SessionDelegate(mode: .foreground, staging: staging, policy: policy),
            maxConnectionsPerHost: 2,
            requestTimeout: 10
        )
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/a.bin"))
        let job = TransportFixtures.job(id: TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(1), url: url, expected: 2)
        guard case .staged(let file)? = await run(await backend.start(job)).terminal else {
            Issue.record("not staged")
            await server.stop()
            return
        }
        #expect(staging.contents[file.name] == Data("ok".utf8))
        #expect(await server.requests.first?.header("x-zombietron-app-key") == nil)
        await backend.invalidate()
        await server.stop()
    }

    /// One routing case of ADR-026 and transport.md §10.7.
    struct RouteCase: Sendable, CustomTestStringConvertible {
        var key: Bool
        var exposure: KeyRedirectExposure
        var priority: AssetPriority = .bulk
        var route: TransferRoute = .backgroundEligible
        var purpose: TransferPurpose = .asset
        var resumed = false
        var expected: Int64? = 100
        var background: Bool

        var testDescription: String {
            "key=\(self.key) \(self.exposure) \(self.priority) \(self.route) \(self.purpose) resumed=\(self.resumed) byteSize=\(String(describing: self.expected))"
        }
    }

    static let routeCases: [RouteCase] = [
        RouteCase(key: true, exposure: .refuse, background: false),
        RouteCase(key: true, exposure: .acceptedByOwner, background: true),
        RouteCase(key: false, exposure: .refuse, background: true),
        RouteCase(key: false, exposure: .refuse, priority: .prefetch, background: false),
        RouteCase(key: false, exposure: .refuse, priority: .userInitiated, background: false),
        RouteCase(key: false, exposure: .refuse, route: .foreground, background: false),
        RouteCase(key: false, exposure: .refuse, purpose: .manifest, background: false),
        RouteCase(key: false, exposure: .refuse, resumed: true, background: false),
        // R-NET-7: the OS downloads a background task whole, so only a size the manifest fixed within the cap goes there.
        RouteCase(key: false, exposure: .refuse, expected: nil, background: false),
        RouteCase(key: false, exposure: .refuse, expected: 1_001, background: false),
        RouteCase(key: false, exposure: .refuse, expected: 1_000, background: true),
    ]

    @available(macOS 15.0, *)
    @Test("R-NET-3: a key-bearing transfer never uses the background session unless the owner accepted redirect exposure", .timeLimit(.minutes(1)), arguments: SourceTests.routeCases)
    func routing(_ route: RouteCase) async throws {
        let options = BackgroundTransferOptions(namespace: "media", keyRedirectExposure: route.exposure)
        let foreground = FakeTransferBackend()
        let background = FakeTransferBackend(kind: .background)
        let source = HTTPRemoteSource(
            configuration: HTTPSourceConfiguration(baseURL: Self.base, appKey: route.key ? TransportFixtures.canaryKey : nil, background: .enabled(options)),
            staging: FakeStagingSink(),
            policy: .production(allowedHosts: ["cdn.example.com"]),
            foreground: foreground,
            background: background,
            log: .tapOnly(nil)
        )
        let id = TransportFixtures.contentID(1)
        let resume = route.resumed
            ? ResumePoint(previous: StagingFileName(transfer: id, attempt: TransportFixtures.attempt(1), kind: .partial), offset: 10, validator: .lastModified("x"))
            : nil
        let request = TransferRequest(
            id: id, attempt: TransportFixtures.attempt(2), purpose: route.purpose, remotePath: "video/a.bin", expectedBytes: route.expected,
            maxBytes: 1_000, priority: route.priority, route: route.route, resume: resume)
        _ = await source.transfer(request)
        let jobs = route.background ? await background.jobs : await foreground.jobs
        let other = route.background ? await foreground.jobs : await background.jobs
        #expect(jobs.count == 1 && other.isEmpty)
        #expect(jobs.first?.url.absoluteString == "https://cdn.example.com/assets/video/a.bin")
        #expect(jobs.first?.resume == resume && jobs.first?.priority == route.priority)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: when the coordinator refuses new work the transfer runs in the foreground", .timeLimit(.minutes(1)))
    func refusedCoordinatorFallsBack() async throws {
        let fixtures = try TransportFixtures.directory("fallback")
        defer { try? FileManager.default.removeItem(at: fixtures) }
        let staging = FakeStagingSink()
        let policy = TransportSecurityPolicy.production(allowedHosts: ["cdn.example.com"])
        let identifier = try #require(BackgroundSessionIdentifier(namespace: "media"))
        let driver = FakeBackgroundSessionDriver(identifier: identifier, delegate: SessionDelegate(mode: .background, staging: staging, policy: policy), fixtures: fixtures)
        let options = BackgroundTransferOptions(namespace: "media", maxTasks: 1)
        let coordinator = BackgroundTransferCoordinator(driver: driver, staging: staging, options: options)
        let foreground = FakeTransferBackend()
        let source = HTTPRemoteSource(
            configuration: HTTPSourceConfiguration(baseURL: Self.base, background: .enabled(options)),
            staging: staging,
            policy: policy,
            foreground: foreground,
            background: coordinator,
            log: .tapOnly(nil)
        )
        func request(_ sequence: UInt32) -> TransferRequest {
            TransferRequest(id: TransportFixtures.contentID(UInt8(sequence)), attempt: TransportFixtures.attempt(sequence), remotePath: "v\(sequence).bin", expectedBytes: 4, maxBytes: 10, priority: .bulk, route: .backgroundEligible)
        }
        let background = await source.transfer(request(1))
        _ = await source.transfer(request(2))
        #expect(await driver.starts.count == 1)
        #expect(await foreground.jobs.map(\.attempt) == [TransportFixtures.attempt(2)])
        await source.invalidate()
        #expect(await driver.invalidations == 1)
        #expect(await foreground.invalidations == 1)
        await source.cancelTransfer(StagingFileName(transfer: TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(1), kind: .partial))
        #expect(await driver.cancellations.isEmpty)
        withExtendedLifetime(background) {}
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: re-attachment through a plain background backend reports its live transfers as running", .timeLimit(.minutes(1)))
    func reattachedThroughPlainBackend() async {
        let background = FakeTransferBackend(kind: .background)
        let name = StagingFileName(transfer: TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(1), kind: .partial)
        await background.scriptLiveTransfers([LiveTransfer(name: name, backend: .background, isRunning: false, bytesReceived: 7, priority: 0.25)])
        let source = HTTPRemoteSource(
            configuration: HTTPSourceConfiguration(baseURL: Self.base),
            staging: FakeStagingSink(),
            policy: .production(allowedHosts: ["cdn.example.com"]),
            foreground: FakeTransferBackend(),
            background: background,
            log: .tapOnly(nil)
        )
        #expect(await source.reattachedTransfers() == [ReattachedTransfer(name: name, isRunning: true, bytesReceived: 7)])
        await source.cancelTransfer(name)
        #expect(await background.cancellations == [FakeBackendCancellation(name: name, keepingPartial: false)])
        // A source whose background is not a coordinator has no session to hand events to: the backend sees nothing.
        await source.handleBackgroundEvents(identifier: "com.ztron.assetkit.bg.default.v1")
        #expect(await background.cancellations.count == 1)
        #expect(await background.jobs.isEmpty)
        #expect(await background.invalidations == 0)
    }
}
