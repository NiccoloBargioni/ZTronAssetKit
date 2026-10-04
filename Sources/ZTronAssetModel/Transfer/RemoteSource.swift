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
///
/// Built atomically by `AssetStore.adoptionReport()`: the store captures its state synchronously, commits the
/// generation holding it durably, and reports only what it captured, so a publish that lands during the commit is
/// never reported as adopted (store-1 S1-10).
public struct AdoptionReport: Sendable, Hashable {
    /// The `remotePath` of every entry of the applied manifest.
    public var manifestRemotePaths: [String]
    /// The entries present at their current content in a **durably committed** generation (store-1 S1-10).
    public var adoptedRemotePaths: Set<String>
    /// Entries outside the client's retention scope (`AssetClientConfiguration.retentionScope`, ADR-027), which
    /// therefore never block a release (transport-2 T2-13).
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
    /// R-CLN-9, H-7 (transport-2 T2-13): bytes the source still holds on the device for content the store adopted,
    /// i.e. Apple packs not yet released (from `PackBackend.installedBytes`); 0 for HTTP. No network. The engine
    /// adds it to `StorageReport.sourceCopyBytes`, because Sync reaches the Apple tier only through this protocol.
    func sourceCopyBytes() async -> Int64
    /// The app forwarded background-session events for `identifier` (R-NET-3): ensures that session exists so the
    /// OS delivers them, and returns once every event delivered before `urlSessionDidFinishEvents` is staged. A
    /// no-op for sources without a background session.
    func handleBackgroundEvents(identifier: String) async
    /// Shutdown (R-SYN-15): cancels every foreground transfer and returns only after the foreground session's
    /// delegate callbacks have stopped, so no foreground staging write lands after `AssetStore.close()`
    /// (transport-2 T2-04). Apple tier: returns after every in-flight `StagingSink.writeStaged` of the source has
    /// returned. The opt-in background session is released **without** waiting for the OS's tasks
    /// (`finishTasksAndInvalidate` delivers its last callback only when every task finished, possibly hours later);
    /// a file it moves into staging after close is reconciled at the next launch (ADR-028).
    func invalidate() async
}

/// Builds the live remote source lazily, inside `AssetClient.start()` and never in `init` (P-12, sync-2 S2-18).
public protocol RemoteSourceFactory: Sendable {
    /// Selects the tier (R-APL-5) and builds its source over the store's staging sink. `log` is the environment's
    /// route (`AssetEnvironment.logRoute`, ADR-047): the source logs its `transport` or `apple` lines through it, so
    /// a test environment's source never writes to the unified log.
    func makeRemoteSource(
        configuration: RemoteConfiguration,
        staging: any StagingSink,
        log: LogRoute
    ) async throws(AssetError) -> any RemoteSource
}
