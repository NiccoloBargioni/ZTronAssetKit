import Foundation

/// Why a prior-art operation that the `AssetClient` took over cannot run through the shims (R-CAR-6, WP-K).
///
/// The prior art's store and providers moved files around themselves; the client now owns its store root and its
/// transport, so the few prior-art entry points that would bypass it fail with this error instead of keeping a
/// second, unverified download or file-placement path alive. Each case names the client API that replaces the call.
public enum CDNShimError: Error, Sendable, Hashable {
    /// A provider was asked to download an asset itself. The client downloads, verifies and stores every asset
    /// (`AssetClient.resolve(_:priority:)`, `CDNAssetResolver.resolveViaNetwork`); a provider is configuration and a
    /// manifest source only.
    case downloadsGoThroughTheClient
    /// A file downloaded outside the client was offered to the store. The client owns its root and only places bytes
    /// it fetched and verified itself; the offered file is left where it is, as after a failed move in the prior art.
    case storeIsOwnedByTheClient
}
