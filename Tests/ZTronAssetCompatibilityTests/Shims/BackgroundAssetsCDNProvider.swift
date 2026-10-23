import Foundation
import ZTronAssetKit

/// R-CAR-6 shim of the prior art's Apple-hosted provider (`BackgroundAssetsCDNProvider.swift`, read-only): the same
/// availability and initialiser, now a description of the client's Apple-hosted tier and a manifest source.
///
/// The client's Apple tier reads its catalog from the essential pack (SPEC §2.3, R-APL-*) and streams pack files into
/// its store (D-11), so `downloadAsset` is deprecated; `catalog` is what `fetchManifest()` answers, as before, for
/// `CDNSyncCoordinator.verifyFullyAvailable()`. Keeping `@available(iOS 26.0, *)` keeps every call site's
/// availability checks meaningful, although the shim itself calls no iOS 26 API.
@available(iOS 26.0, *)
public struct BackgroundAssetsCDNProvider: CDNProviding {
    private let catalog: [CDNAsset]

    /// The prior art's initialiser: the catalog the app ships (each `remotePath` is `"<assetPackID>/<path>"`).
    public init(catalog: [CDNAsset]) {
        self.catalog = catalog
    }

    /// The app-supplied catalog, as in the prior art (no network, no pack access).
    public func fetchManifest() async throws -> [CDNAsset] {
        // WP-K skeleton: the catalog is not served yet.
        []
    }

    /// Gone: the client's Apple tier adopts pack files (`AssetClient.resolve`). A `remotePath` that is not
    /// `"<assetPackID>/<path>"` still throws `BackgroundAssetsCDNProviderError.malformedRemotePath`; every other call
    /// throws `CDNShimError.downloadsGoThroughTheClient`.
    @available(*, deprecated, message: "The AssetClient's Apple-hosted tier adopts pack files; use AssetClient.resolve(_:priority:) or CDNAssetResolver.resolveViaNetwork")
    public func downloadAsset(_ asset: CDNAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        // WP-K skeleton: the refusal is not written yet.
        URL(fileURLWithPath: asset.remotePath)
    }
}

@available(iOS 26.0, *)
extension BackgroundAssetsCDNProvider: CDNRemoteConfigurable {
    /// The Apple-hosted tier with SPEC §2.3's layout (catalog `ZTronCatalog/catalog.json`, release after adoption).
    var remoteConfiguration: RemoteConfiguration {
        RemoteConfiguration(appleHosted: AppleTierConfiguration())
    }
}

/// The prior art's provider error (now also `Hashable`).
public enum BackgroundAssetsCDNProviderError: Error, Hashable {
    /// `remotePath` was not in the `"<packID>/<relativePath>"` shape this provider expects.
    case malformedRemotePath(String)
}
