import Foundation
import ZTronAssetModel

/// The AWS (CloudFront) tier as a `RemoteSource` (R-NET-1…10; WP-D).
///
/// Immutable: every field is a `let` of a `Sendable` type. Built by the composition root inside
/// `AssetClient.start()` (P-12). The app key is attached per request by the request factory, only for origins the
/// security policy allows (R-NET-4); it is never put in `httpAdditionalHeaders`.
public final class HTTPRemoteSource: RemoteSource {
    /// The configuration (the key redacts itself).
    public let configuration: HTTPSourceConfiguration
    /// Redirect and key policy.
    public let policy: TransportSecurityPolicy
    /// Where bytes go.
    public let staging: any StagingSink
    /// The foreground backend.
    public let foreground: any TransferBackend
    /// The opt-in background backend (ADR-026); `nil` by default.
    public let background: (any TransferBackend)?

    /// Production: an HTTPS-only policy over `baseURL`'s host plus the additional hosts, and the live foreground
    /// backend.
    public convenience init(configuration: HTTPSourceConfiguration, staging: any StagingSink) {
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
                requestTimeout: configuration.requestTimeout
            ),
            background: nil
        )
    }

    /// Tests and benchmarks (same package): an explicit policy (loopback) and injected backends.
    package init(
        configuration: HTTPSourceConfiguration,
        staging: any StagingSink,
        policy: TransportSecurityPolicy,
        foreground: any TransferBackend,
        background: (any TransferBackend)?
    ) {
        self.configuration = configuration
        self.staging = staging
        self.policy = policy
        self.foreground = foreground
        self.background = background
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

    /// Conditional GET of the manifest through a data task into staging (R-NET-5, ADR-019).
    public func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        fatalError("WP-D: HTTPRemoteSource.fetchManifest not implemented")
    }

    /// Starts one attempt on the foreground backend (or the background one when ADR-026 allows it).
    public func transfer(_ request: TransferRequest) async -> any TransferHandle {
        fatalError("WP-D: HTTPRemoteSource.transfer not implemented")
    }

    /// Background tasks left by an earlier process (empty when background is disabled).
    public func reattachedTransfers() async -> [ReattachedTransfer] {
        fatalError("WP-D: HTTPRemoteSource.reattachedTransfers not implemented")
    }

    /// Cancels a re-attached task.
    public func cancelTransfer(_ name: StagingFileName) async {
        fatalError("WP-D: HTTPRemoteSource.cancelTransfer not implemented")
    }

    /// HTTP keeps no source copies: an empty report.
    public func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport {
        ReclaimReport()
    }

    /// HTTP keeps no source copies: 0 (R-CLN-9).
    public func sourceCopyBytes() async -> Int64 {
        0
    }

    /// Activates the background session for `identifier` and waits for its pending events to be staged.
    public func handleBackgroundEvents(identifier: String) async {
        fatalError("WP-D: HTTPRemoteSource.handleBackgroundEvents not implemented")
    }

    /// Invalidates the foreground backend and waits for its delegate's last callback (transport-2 T2-04); releases
    /// the background backend without waiting for the OS's tasks (`RemoteSource.invalidate` doc, ADR-028).
    public func invalidate() async {
        fatalError("WP-D: HTTPRemoteSource.invalidate not implemented")
    }
}
