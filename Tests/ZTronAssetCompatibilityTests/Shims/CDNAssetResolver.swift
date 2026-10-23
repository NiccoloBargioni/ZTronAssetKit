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
    /// Where the resolver's client comes from.
    private enum Binding: Sendable {
        /// A client given explicitly.
        case client(AssetClient)
        /// The prior-art initialiser: the client of `store`'s install point, built from `provider` on first use.
        case store(CDNLocalStore, provider: any CDNProviding)
    }

    private let binding: Binding

    /// A resolver over `client`.
    public init(client: AssetClient) {
        self.binding = .client(client)
    }

    /// The prior art's initialiser. The resolver resolves through the client of `localStore`'s install point; when that
    /// point is empty, the first use builds one there from `cdn` (`CDNInstallPoint.installClient(for:)`: the HTTP tier
    /// at a `StaticManifestCDNProvider`'s base URL, the Apple-hosted tier for a `BackgroundAssetsCDNProvider`, the point's
    /// configured tiers for a custom provider, which is never used as a transport). So the prior art's launch idiom,
    /// `CDNAssetResolver.installed = CDNAssetResolver(cdn: provider)`, installs one client that `CDNLocalStore.shared`
    /// and `CDNSyncCoordinator(cdn:)` share.
    @available(*, deprecated, message: "Build one AssetClient (CDNProviderFactory.install(_:)) and use CDNAssetResolver(client:) or CDNAssetResolver.installed")
    public init(cdn: any CDNProviding, localStore: CDNLocalStore = .shared) {
        self.binding = .store(localStore, provider: cdn)
    }

    /// The client this resolver resolves through (for the prior-art initialiser, built and installed on first use).
    @MainActor
    public var client: AssetClient {
        switch self.binding {
        case .client(let client):
            return client
        case .store(let store, let provider):
            return store.installPoint.installClient(for: provider)
        }
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
        let client: AssetClient
        switch self.binding {
        case .client(let explicit):
            client = explicit
        case .store:
            client = await MainActor.run { self.client }
        }
        let url: URL
        do {
            url = try await client.resolve(AssetID(identifier), priority: .userInitiated)
        } catch {
            return nil
        }
        return CDNAssetResolver.matches(url, candidateExtensions) ? url : nil
    }

    /// Whether `url`'s extension is one of `candidates` (any when empty), ignoring case: the client stores lowercased
    /// extensions (R-SEC-2), the prior art compared the manifest's spelling.
    static func matches(_ url: URL, _ candidates: [String]) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return candidates.isEmpty || candidates.contains { $0.lowercased() == fileExtension }
    }
}

extension CDNInstallPoint {
    /// A resolver over the installed client, if any (`CDNAssetResolver.installed` of this point).
    public var resolver: CDNAssetResolver? {
        self.client.map { CDNAssetResolver(client: $0) }
    }

    /// Installs `resolver`'s client unless a client is installed already; returns the resolver over the installed client.
    @discardableResult
    public func installResolver(_ resolver: CDNAssetResolver) -> CDNAssetResolver {
        CDNAssetResolver(client: self.install(resolver.client))
    }
}
