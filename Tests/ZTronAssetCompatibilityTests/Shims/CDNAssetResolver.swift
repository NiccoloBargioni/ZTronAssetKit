import Foundation
import ZTronAssetKit

/// R-CAR-6 shim of the prior art's on-demand resolver (`CDNAssetResolver.swift`, read-only): the network step of the
/// fallback chain, as an adapter over `AssetClient.resolve`.
///
/// The client keeps the prior art's observable behaviour (RECON §5): a present asset answers without a transfer; an
/// identifier the applied manifest does not know triggers one fetch-first manifest request (point admission, which
/// commits that one entry and never prunes anything else, as the prior art's resolver never reconciled); errors are
/// swallowed into `nil`. It adds what the prior art lacked: single-flight transfers, verification and typed errors
/// (callers that need them use `AssetClient.resolve` or `AssetFallbackChain.fetch`).
public struct CDNAssetResolver: Sendable {
    private let resolvedClient: AssetClient

    /// A resolver over `client`.
    public init(client: AssetClient) {
        self.resolvedClient = client
    }

    /// The client this resolver resolves through.
    @MainActor
    public var client: AssetClient {
        self.resolvedClient
    }

    /// The process-wide resolver of the prior art, now a view of `CDNInstallPoint.process`: `nil` until the app installs
    /// a client, then a resolver over that client. Setting it installs the resolver's client unless one is installed
    /// already (the first installation wins, `CDNInstallPoint`); setting `nil` changes nothing. Main-actor isolated, so
    /// every read and write is race-free (RECON D-19).
    @MainActor
    public static var installed: CDNAssetResolver? {
        get {
            CDNInstallPoint.process.resolver
        }
        set {
            if let newValue {
                CDNInstallPoint.process.installResolver(newValue)
            }
        }
    }

    /// The local file for `identifier`, fetched if needed, or `nil` when the catalog does not have it, its extension is
    /// not one of `candidateExtensions` (any extension when empty) or anything fails. The extension is checked once the
    /// client resolved the asset, as `AssetFallbackChain.fetch` does (ADR-037), because only then is the entry known.
    public func resolveViaNetwork(identifier: String, candidateExtensions: [String]) async -> URL? {
        // WP-K skeleton: nothing is resolved yet.
        nil
    }
}

extension CDNInstallPoint {
    /// A resolver over the installed client, if any (`CDNAssetResolver.installed` of this point).
    public var resolver: CDNAssetResolver? {
        // WP-K skeleton: no resolver is made yet.
        nil
    }

    /// Installs `resolver`'s client unless a client is installed already; returns the resolver over the installed client.
    @discardableResult
    public func installResolver(_ resolver: CDNAssetResolver) -> CDNAssetResolver {
        // WP-K skeleton: nothing is installed yet.
        resolver
    }
}
