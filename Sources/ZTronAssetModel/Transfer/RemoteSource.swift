/// What a remote source can do; the engine adapts scheduling to it.
public struct RemoteSourceCapabilities: Sendable, Hashable {
    /// AWS or Apple-hosted.
    public var tier: AssetTier
    /// Whether `TransferHandle.setPriority` has an effect (AWS: yes; Apple: the OS schedules packs).
    public var supportsPriority: Bool
    /// Whether a paused or interrupted transfer can continue (AWS: Range/If-Range; Apple: no).
    public var supportsResume: Bool
    /// Whether a background session is enabled **and** usable for some requests (ADR-026).
    public var supportsBackground: Bool
    /// Whether the source keeps its own copy of adopted content (Apple packs: R-CLN-10 applies).
    public var keepsSourceCopies: Bool

    /// Creates capabilities.
    public init(
        tier: AssetTier,
        supportsPriority: Bool,
        supportsResume: Bool,
        supportsBackground: Bool,
        keepsSourceCopies: Bool
    ) {
        self.tier = tier
        self.supportsPriority = supportsPriority
        self.supportsResume = supportsResume
        self.supportsBackground = supportsBackground
        self.keepsSourceCopies = keepsSourceCopies
    }
}

/// A transfer left by an earlier process that the source can still see (H-6, R-NET-3).
public struct ReattachedTransfer: Sendable, Hashable {
    /// The staging file it writes (transfer and attempt, ADR-013): names survive relaunch, attempt numbers are
    /// comparable across launches because the epoch is persisted (transport-2 T2-06).
    public var name: StagingFileName
    /// Running (or suspended) in the OS, versus already completed into staging.
    public var isRunning: Bool
    /// Bytes received so far.
    public var bytesReceived: Int64

    /// Creates a description.
    public init(name: StagingFileName, isRunning: Bool, bytesReceived: Int64) {
        self.name = name
        self.isRunning = isRunning
        self.bytesReceived = bytesReceived
    }
}

/// What the store holds, so a source can release duplicates it keeps (R-CLN-10, H-7).
public struct AdoptionReport: Sendable, Hashable {
    /// The `remotePath` of every entry of the applied manifest.
    public var manifestRemotePaths: [String]
    /// The entries present, verified and **durably committed** in `blobs/` (store-1 S1-10).
    public var adoptedRemotePaths: Set<String>
    /// Entries the keep-scope excludes, which therefore never block a release (transport-2 T2-13).
    public var excludedRemotePaths: Set<String>

    /// Creates a report.
    public init(manifestRemotePaths: [String], adoptedRemotePaths: Set<String>, excludedRemotePaths: Set<String> = []) {
        self.manifestRemotePaths = manifestRemotePaths
        self.adoptedRemotePaths = adoptedRemotePaths
        self.excludedRemotePaths = excludedRemotePaths
    }
}

/// The outcome of `reclaimSourceCopies`.
public struct ReclaimReport: Sendable, Hashable {
    /// Source copies (pack ids) released.
    public var released: [String]
    /// Releases that failed, by source id.
    public var failed: [String: TransferError]

    /// Creates a report.
    public init(released: [String] = [], failed: [String: TransferError] = [:]) {
        self.released = released
        self.failed = failed
    }
}

/// Where bytes come from: the AWS origin over HTTP, or Apple-hosted packs (R-NET-1, R-APL-1).
///
/// The engine talks to Transport and AppleHosted **only** through this protocol (SPEC §4.1), so the whole engine
/// runs against `FakeRemoteSource` with no network. Conformers own no long-lived task in the default configuration
/// (R-SYN-14).
public protocol RemoteSource: Sendable {
    /// Circuit-breaker and throttle key: `scheme://host[:port]` for HTTP, `"apple-hosted"` for packs.
    var originID: String { get }
    /// What the source can do.
    var capabilities: RemoteSourceCapabilities { get }
    /// A conditional manifest fetch (R-NET-5); never answered from a local HTTP cache.
    func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult
    /// Starts one attempt. `async` only because a resume point may be validated against staging first.
    func transfer(_ request: TransferRequest) async -> any TransferHandle
    /// H-6: transfers an earlier process left live or completed into staging. Called once by `start()`, after the
    /// background session exists and **before** staging is listed (transport-2 T2-03).
    func reattachedTransfers() async -> [ReattachedTransfer]
    /// Cancels a re-attached transfer nobody wants (there is no handle for it).
    func cancelTransfer(_ name: StagingFileName) async
    /// R-CLN-10: releases source-held duplicates of adopted content when policy allows. No-op for HTTP.
    func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport
    /// Shutdown (R-SYN-15): cancels every transfer and returns only after the session's delegate callbacks have
    /// stopped, so no staging write lands after `AssetStore.close()` (transport-2 T2-04).
    func invalidate() async
}

/// Builds the live remote source lazily, inside `AssetClient.start()` and never in `init` (P-12, sync-2 S2-18).
public protocol RemoteSourceFactory: Sendable {
    /// Selects the tier (R-APL-5) and builds its source over the store's staging sink.
    func makeRemoteSource(
        configuration: RemoteConfiguration,
        staging: any StagingSink
    ) async throws(AssetError) -> any RemoteSource
}
