#if canImport(BackgroundAssets)
import ZTronAssetModel

/// The Apple-hosted tier as a `RemoteSource` (R-APL-1…4, R-CLN-10; WP-E).
///
/// Compiled only where BackgroundAssets exists and available from iOS 26 / macOS 26 (R-APL-1; the macOS clause is
/// required for the host build, APPLE-API-VERIFICATION §1.2). All logic runs against a `PackBackend`, so it is
/// tested with `FakePackBackend`. Catalog in the essential pack, read before any update check is awaited
/// (transport-2 T2-14); pack/catalog skew is `transient(.sourceVersionSkew)`, never integrity (T2-12); a pack is
/// released only after the adopting generation is durably committed (store-1 S1-10).
@available(iOS 26.0, macOS 26.0, *)
public final class AppleHostedRemoteSource: RemoteSource {
    /// The configuration.
    public let configuration: AppleTierConfiguration
    /// The pack seam.
    public let backend: any PackBackend
    /// Where bytes go.
    public let staging: any StagingSink

    /// Creates the source; touches no pack API (R-APL-1).
    public init(configuration: AppleTierConfiguration, backend: any PackBackend, staging: any StagingSink) {
        self.configuration = configuration
        self.backend = backend
        self.staging = staging
    }

    /// `"apple-hosted"`.
    public var originID: String {
        "apple-hosted"
    }

    /// No priority, no resume, no background session; keeps source copies (R-CLN-10).
    public var capabilities: RemoteSourceCapabilities {
        RemoteSourceCapabilities(
            tier: .appleHosted,
            supportsPriority: false,
            supportsResume: false,
            supportsBackground: false,
            keepsSourceCopies: true
        )
    }

    /// Reads the catalog from the essential pack; the digest is the pseudo-ETag (R-APL-4).
    public func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        fatalError("WP-E: AppleHostedRemoteSource.fetchManifest not implemented")
    }

    /// Streams the pack file into staging (adopt-and-release, ADR-027).
    public func transfer(_ request: TransferRequest) async -> any TransferHandle {
        fatalError("WP-E: AppleHostedRemoteSource.transfer not implemented")
    }

    /// Packs have no re-attachable transfers.
    public func reattachedTransfers() async -> [ReattachedTransfer] {
        []
    }

    /// Nothing to cancel.
    public func cancelTransfer(_ name: StagingFileName) async {}

    /// Runs `PackReleasePlanner` and removes the packs it selects.
    public func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport {
        fatalError("WP-E: AppleHostedRemoteSource.reclaimSourceCopies not implemented")
    }

    /// Bytes the OS still holds in media packs whose entries were adopted and that were not released yet, summed
    /// from `PackBackend.installedBytes` (R-CLN-9, H-7, transport-2 T2-13).
    public func sourceCopyBytes() async -> Int64 {
        fatalError("WP-E: AppleHostedRemoteSource.sourceCopyBytes not implemented")
    }

    /// Packs have no background URLSession.
    public func handleBackgroundEvents(identifier: String) async {}

    /// Cancels pack waiters and returns after every in-flight `writeStaged` of this source returned.
    public func invalidate() async {
        fatalError("WP-E: AppleHostedRemoteSource.invalidate not implemented")
    }
}
#endif
