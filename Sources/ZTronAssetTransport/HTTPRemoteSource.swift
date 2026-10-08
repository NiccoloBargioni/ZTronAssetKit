import Foundation
import ZTronAssetModel

/// The AWS (CloudFront) tier as a `RemoteSource` (R-NET-1…10; WP-D).
///
/// Immutable: every field is a `let` of a `Sendable` type. Built by the composition root inside
/// `AssetClient.start()` (P-12). The app key is attached per request by the request factory, only for origins the
/// security policy allows (R-NET-4); it is never put in `httpAdditionalHeaders`. WP-D owns every body, including
/// the initialisers implemented in Stage 1 (ARCHITECTURE §6.1, §6.4).
public final class HTTPRemoteSource: RemoteSource {
    /// The configuration (the key redacts itself).
    public let configuration: HTTPSourceConfiguration
    /// Redirect and key policy.
    public let policy: TransportSecurityPolicy
    /// Where bytes go.
    public let staging: any StagingSink
    /// The foreground backend.
    public let foreground: any TransferBackend
    /// The opt-in background backend (ADR-026); `nil` unless `configuration.background` is `.enabled` with a valid
    /// namespace.
    public let background: (any TransferBackend)?
    /// Where `transport` lines go (ADR-047): the environment's route, tap-only in tests.
    public let log: LogRoute

    /// Production: an HTTPS-only policy over `baseURL`'s host plus the additional hosts, the live foreground
    /// backend, and, when `configuration.background` is `.enabled`, the background coordinator over
    /// `LiveBackgroundSessionDriver` (`makeBackgroundBackend`). Creates the foreground `URLSession` (no I/O, about
    /// 0.05 ms); the background session is created only by the coordinator's first `activate()` (ADR-028).
    public convenience init(configuration: HTTPSourceConfiguration, staging: any StagingSink, log: LogRoute) {
        var hosts = configuration.additionalAllowedHosts
        if let host = configuration.baseURL.host {
            hosts.insert(host)
        }
        let policy = TransportSecurityPolicy.production(allowedHosts: hosts, keyHeaderName: configuration.keyHeaderName)
        let delegate = SessionDelegate(mode: .foreground, staging: staging, policy: policy)
        self.init(
            configuration: configuration,
            staging: staging,
            policy: policy,
            foreground: ForegroundTransferBackend(
                delegate: delegate,
                maxConnectionsPerHost: configuration.maxConnectionsPerHost,
                requestTimeout: configuration.requestTimeout,
                appKey: configuration.appKey,
                log: log
            ),
            background: HTTPRemoteSource.makeBackgroundBackend(
                configuration.background,
                staging: staging,
                policy: policy,
                appKey: configuration.appKey,
                requestTimeout: configuration.requestTimeout,
                log: log
            ),
            log: log
        )
    }

    /// Tests and benchmarks (same package): an explicit policy (loopback), injected backends and log route.
    package init(
        configuration: HTTPSourceConfiguration,
        staging: any StagingSink,
        policy: TransportSecurityPolicy,
        foreground: any TransferBackend,
        background: (any TransferBackend)?,
        log: LogRoute
    ) {
        self.configuration = configuration
        self.staging = staging
        self.policy = policy
        self.foreground = foreground
        self.background = background
        self.log = log
    }

    /// The production background backend for `policy` (R-NET-3, ADR-026): `nil` when background transfers are
    /// disabled (the default) or the namespace is not `[0-9a-z-]{1,32}`; otherwise a `BackgroundTransferCoordinator`
    /// over `LiveBackgroundSessionDriver` and its own `.background` `SessionDelegate`. Builds no `URLSession` and
    /// performs no I/O: the driver creates the session in `activate()`, which `start()` calls after the store opened
    /// (ADR-028).
    package static func makeBackgroundBackend(
        _ background: BackgroundTransferPolicy,
        staging: any StagingSink,
        policy: TransportSecurityPolicy
    ) -> (any TransferBackend)? {
        HTTPRemoteSource.makeBackgroundBackend(background, staging: staging, policy: policy, appKey: nil, requestTimeout: 60, log: .tapOnly(nil))
    }

    /// The production background backend with the request factory it needs: the policy always, the key only when
    /// the owner accepted redirect exposure (ADR-026), so under the default `.refuse` no background request can
    /// carry it even if a routing defect sent one there.
    static func makeBackgroundBackend(
        _ background: BackgroundTransferPolicy,
        staging: any StagingSink,
        policy: TransportSecurityPolicy,
        appKey: AppKey?,
        requestTimeout: TimeInterval,
        log: LogRoute
    ) -> (any TransferBackend)? {
        guard case .enabled(let options) = background,
            let identifier = BackgroundSessionIdentifier(namespace: options.namespace)
        else {
            return nil
        }
        let delegate = SessionDelegate(mode: .background, staging: staging, policy: policy)
        let driver = LiveBackgroundSessionDriver(identifier: identifier, delegate: delegate, discretionary: options.discretionary)
        let key = options.keyRedirectExposure == .acceptedByOwner ? appKey : nil
        return BackgroundTransferCoordinator(
            driver: driver,
            staging: staging,
            options: options,
            policy: policy,
            appKey: key,
            requestTimeout: requestTimeout,
            log: log
        )
    }

    /// `scheme://host:port` of `baseURL`.
    public var originID: String {
        Origin(url: self.configuration.baseURL)?.description ?? self.configuration.baseURL.absoluteString
    }

    /// AWS: priority and resume supported; background only when a background backend exists.
    public var capabilities: RemoteSourceCapabilities {
        RemoteSourceCapabilities(
            tier: .aws,
            supportsPriority: true,
            supportsResume: true,
            supportsBackground: self.background != nil,
            keepsSourceCopies: false
        )
    }

    /// Conditional GET of the manifest through a data task into staging (R-NET-5, ADR-019): `If-None-Match` with
    /// the stored tag, a session without a cache, the cap enforced while streaming; a 304 is `notModified`, a 200's
    /// staged bytes are read back off the pool and the staged file discarded. Every terminal discards the attempt's
    /// partial, so a failed fetch leaves nothing behind.
    public func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        guard let url = RemoteURL.make(base: self.configuration.baseURL, path: self.configuration.manifestPath) else {
            throw .rejected(.invalidURL)
        }
        let job = TransferJob(
            id: .manifest,
            attempt: request.attempt,
            url: url,
            purpose: .manifest,
            ifNoneMatch: request.ifNoneMatch,
            expectedBytes: nil,
            maxBytes: SizeGuard.clampedLimit(request.maxBytes),
            priority: .userInitiated,
            access: request.access
        )
        let handle = await self.foreground.start(job)
        let terminal = await Self.terminal(of: handle.updates)
        switch terminal {
        case .staged(let file) where file.httpStatus == 304:
            self.log.log(.transport, .debug, "manifest not modified")
            return .notModified(removedSources: [])
        case .staged(let file):
            let bytes: Data
            do {
                bytes = try await self.staging.readStaged(file.name, maxBytes: job.maxBytes)
            } catch {
                await self.staging.discard(job.partialName)
                throw error.transferError(requiredBytes: nil)
            }
            await self.staging.discard(job.partialName)
            self.log.log(.transport, .debug, "manifest fetched bytes=\(bytes.count)")
            return .fetched(ManifestPayload(bytes: bytes, etag: file.etag, origin: .network))
        case .failed(let failure):
            await self.staging.discard(job.partialName)
            let kind = failure.failureClass.map { String(describing: $0) } ?? "cancelled"
            self.log.log(.transport, .info, "manifest fetch failed: \(kind)")
            throw failure
        case .paused, .progress, nil:
            await self.staging.discard(job.partialName)
            throw Task.isCancelled ? .cancelled(.byClient) : .transient(.incompleteCallbackSequence, retryAfter: nil)
        }
    }

    /// Starts one attempt: the URL is `baseURL` joined with the validated `remotePath` (TR1-10); the background
    /// backend is used only when ADR-026 allows it (`routesToBackground`), the foreground one otherwise.
    public func transfer(_ request: TransferRequest) async -> any TransferHandle {
        guard let url = RemoteURL.make(base: self.configuration.baseURL, path: request.remotePath) else {
            return ImmediateTransferHandle(id: request.id, attempt: request.attempt, terminal: .failed(.rejected(.invalidURL)))
        }
        let job = TransferJob(
            id: request.id,
            attempt: request.attempt,
            url: url,
            purpose: request.purpose,
            expectedBytes: request.expectedBytes,
            maxBytes: SizeGuard.clampedLimit(request.maxBytes),
            priority: request.priority,
            access: request.access,
            resume: request.resume
        )
        if let background = self.background, await self.routesToBackground(request, url: url, backend: background) {
            return await background.start(job)
        }
        return await self.foreground.start(job)
    }

    /// Background tasks left by an earlier process (empty when background is disabled): live OS tasks and downloads
    /// the OS finished into staging while nobody waited (H-6).
    public func reattachedTransfers() async -> [ReattachedTransfer] {
        guard let background = self.background else {
            return []
        }
        if let coordinator = background as? BackgroundTransferCoordinator {
            return await coordinator.reattached()
        }
        return await background.liveTransfers().map {
            ReattachedTransfer(name: $0.name, isRunning: true, bytesReceived: $0.bytesReceived)
        }
    }

    /// Cancels a re-attached task (background only: foreground tasks never outlive their handles).
    public func cancelTransfer(_ name: StagingFileName) async {
        await self.background?.cancel(name, keepingPartial: false)
    }
    /// HTTP keeps no source copies: an empty report.
    public func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport {
        ReclaimReport()
    }

    /// HTTP keeps no source copies: 0 (R-CLN-9).
    public func sourceCopyBytes() async -> Int64 {
        0
    }

    /// Activates the background session for `identifier` and waits for its pending events to be staged. A no-op for
    /// an identifier that is not this source's session, or when background transfers are disabled.
    public func handleBackgroundEvents(identifier: String) async {
        guard let coordinator = self.background as? BackgroundTransferCoordinator,
            coordinator.driver.identifier.rawValue == identifier
        else {
            return
        }
        await coordinator.awaitBackgroundEvents()
    }

    /// Invalidates the foreground backend and waits for its delegate's last callback (transport-2 T2-04); releases
    /// the background backend without waiting for the OS's tasks (`RemoteSource.invalidate` doc, ADR-028).
    public func invalidate() async {
        await self.foreground.invalidate()
        await self.background?.invalidate()
    }

    /// ADR-026 and transport.md §10.7: a transfer uses the background session only when it is background-eligible,
    /// on the bulk lane, an asset, not a Range resume (the background session cannot continue our partial), of a
    /// `byteSize` known and within the cap (R-NET-7: the OS downloads a background task whole before a byte reaches
    /// us, so only the staged size can be checked, and it must equal `byteSize`), free of the key unless the owner
    /// accepted redirect exposure, and the coordinator admits it (not disabled for the process, under the task cap).
    func routesToBackground(_ request: TransferRequest, url: URL, backend: any TransferBackend) async -> Bool {
        guard request.route == .backgroundEligible, request.priority == .bulk, request.purpose == .asset, request.resume == nil,
            let expected = request.expectedBytes, expected <= request.maxBytes
        else {
            return false
        }
        var exposure = KeyRedirectExposure.refuse
        if case .enabled(let options) = self.configuration.background {
            exposure = options.keyRedirectExposure
        }
        let carriesKey = self.configuration.appKey != nil && self.policy.check(Origin(url: url)) == nil
        guard !carriesKey || exposure == .acceptedByOwner else {
            return false
        }
        guard let coordinator = backend as? BackgroundTransferCoordinator else {
            return true
        }
        return await coordinator.admits()
    }

    /// The first terminal element of `updates`, or `nil` when the stream ended without one (its consumer was
    /// cancelled, which cancels the transfer).
    static func terminal(of updates: AsyncStream<TransferUpdate>) async -> TransferUpdate? {
        for await update in updates where update.isTerminal {
            return update
        }
        return nil
    }

}
