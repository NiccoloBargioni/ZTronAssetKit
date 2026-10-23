import Foundation
import ZTronAssetKit

/// R-CAR-6 shim: the CDN configuration SPEC §2.1 names for the prior art's `CDNProviderFactory.swift`, which never
/// existed on disk (RECON §1). A thin adapter: every field lands in the `AssetClientConfiguration` the client is
/// built with, so the shims add no settings of their own.
public struct CDNConfiguration: Sendable, Hashable {
    /// The configuration of the client this adapter describes.
    public var clientConfiguration: AssetClientConfiguration

    /// Wraps a complete client configuration (for apps that already build one).
    public init(clientConfiguration: AssetClientConfiguration) {
        self.clientConfiguration = clientConfiguration
    }

    /// The prior art's vocabulary: an HTTP origin (`StaticManifestCDNProvider`'s base URL and manifest path, plus
    /// the CloudFront app key SPEC §2.3 adds), the Apple-hosted tier, the refresh policy and where the store lives.
    /// Legacy migration of `Caches/CDNAssets` is on by default, because an app adopting the shims ran the prior art.
    public init(
        baseURL: URL? = nil,
        manifestPath: String = "manifest.json",
        appKey: AppKey? = nil,
        appleHosted: AppleTierConfiguration? = nil,
        awsOnly: Bool = false,
        refreshPolicy: CDNRefreshPolicy = .oncePerAppVersion,
        location: StorageLocation = .applicationSupport,
        legacy: LegacyMigrationPolicy = LegacyMigrationPolicy()
    ) {
        let http = baseURL.map { HTTPSourceConfiguration(baseURL: $0, manifestPath: manifestPath, appKey: appKey) }
        self.clientConfiguration = AssetClientConfiguration(
            remote: RemoteConfiguration(http: http, appleHosted: appleHosted, awsOnly: awsOnly),
            location: location,
            legacy: legacy,
            refresh: refreshPolicy.refreshPolicy
        )
    }

    /// The remote tiers of `clientConfiguration`.
    public var remote: RemoteConfiguration {
        get {
            self.clientConfiguration.remote
        }
        set {
            self.clientConfiguration.remote = newValue
        }
    }
}

/// A prior-art provider that knows which tier of the client replaces it (internal: the factory's legacy path).
protocol CDNRemoteConfigurable {
    /// The remote tiers a client built for this provider uses.
    var remoteConfiguration: RemoteConfiguration { get }
}

/// R-CAR-6 shim: SPEC §2.1's `CDNProviderFactory` (absent from the prior art on disk, RECON §1) as a thin adapter
/// that builds and installs `AssetClient`s. Tier selection is the client's (R-APL-5: the package's single
/// `#available(iOS 26)` picks the Apple-hosted tier when it is configured), so the factory only configures tiers.
public enum CDNProviderFactory {
    /// A client for `configuration`; no I/O, no task (P-12). `environment` is for tests; `nil` builds `.live()`.
    public static func makeClient(_ configuration: CDNConfiguration, environment: AssetEnvironment? = nil) -> AssetClient {
        AssetClient(configuration: configuration.clientConfiguration, environment: environment)
    }

    /// A client for a prior-art provider: `base` with the provider's tier (`remoteConfiguration(for:)`), or with
    /// `base`'s own remote when the provider is a custom conformance the client cannot use as a transport. When `base`
    /// names an HTTP origin and the provider's HTTP tier is at that origin (scheme, host and port), the client keeps
    /// `base`'s HTTP settings, the app key among them, with the provider's base URL and manifest path: the origin answers
    /// 403 without the key (SPEC §2.3), and the key is never carried to another origin (R-NET-4). The process install
    /// point's configuration names no origin, so a prior-art provider builds a client without a key there.
    public static func makeClient(
        for provider: any CDNProviding,
        base: CDNConfiguration = CDNConfiguration(),
        environment: AssetEnvironment? = nil
    ) -> AssetClient {
        CDNProviderFactory.makeClient(CDNProviderFactory.configuration(for: provider, base: base), environment: environment)
    }

    /// `base` with the tier that replaces `provider`, keeping `base`'s HTTP settings at the same origin
    /// (`makeClient(for:base:environment:)`); `base` itself for a custom conformance.
    static func configuration(for provider: any CDNProviding, base: CDNConfiguration) -> CDNConfiguration {
        guard var remote = CDNProviderFactory.remoteConfiguration(for: provider) else {
            return base
        }
        if let tier = remote.http, var configured = base.remote.http,
            let origin = CDNProviderFactory.origin(of: tier.baseURL), origin == CDNProviderFactory.origin(of: configured.baseURL)
        {
            configured.baseURL = tier.baseURL
            configured.manifestPath = tier.manifestPath
            remote.http = configured
        }
        var configuration = base
        configuration.remote = remote
        return configuration
    }

    /// `scheme://host:port` of an http or https URL, normalised as the transport compares origins (scheme and host
    /// lowercased, a trailing dot dropped, the scheme's default port when none is written); `nil` for anything else.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", var host = url.host?.lowercased() else {
            return nil
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else {
            return nil
        }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }

    /// The client tier that replaces a prior-art provider: `StaticManifestCDNProvider` is the HTTP tier with its base
    /// URL and manifest path, `BackgroundAssetsCDNProvider` the Apple-hosted tier; `nil` for any other conformance.
    public static func remoteConfiguration(for provider: any CDNProviding) -> RemoteConfiguration? {
        (provider as? any CDNRemoteConfigurable)?.remoteConfiguration
    }

    /// Installs a client for `configuration` into `point` (the process-wide one by default) unless one is installed
    /// already, and returns the installed client: the first installation wins (`CDNInstallPoint`). No I/O and no task
    /// (P-12), so the client is not started: start it at launch (`try await client.start()`), before carousel content
    /// is created, because `CDNLocalStore`'s synchronous lookups answer `nil` until it has (ADR-037).
    @MainActor
    @discardableResult
    public static func install(
        _ configuration: CDNConfiguration,
        into point: CDNInstallPoint = .process,
        environment: AssetEnvironment? = nil
    ) -> AssetClient {
        if let installed = point.client {
            return installed
        }
        return point.install(CDNProviderFactory.makeClient(configuration, environment: environment))
    }
}
