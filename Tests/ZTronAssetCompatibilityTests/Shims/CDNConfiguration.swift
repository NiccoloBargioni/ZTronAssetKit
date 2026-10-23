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
        // WP-K skeleton: the mapping is not written yet.
        self.clientConfiguration = AssetClientConfiguration(remote: RemoteConfiguration())
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
        // WP-K skeleton: the configuration is not applied yet.
        AssetClient(configuration: AssetClientConfiguration(remote: RemoteConfiguration()), environment: environment)
    }

    /// A client for a prior-art provider: `base` with the provider's tier (`remoteConfiguration(for:)`), or with
    /// `base`'s own remote when the provider is a custom conformance the client cannot use as a transport.
    public static func makeClient(
        for provider: any CDNProviding,
        base: CDNConfiguration = CDNConfiguration(),
        environment: AssetEnvironment? = nil
    ) -> AssetClient {
        // WP-K skeleton: the provider's tier is not applied yet.
        AssetClient(configuration: base.clientConfiguration, environment: environment)
    }

    /// The client tier that replaces a prior-art provider: `StaticManifestCDNProvider` is the HTTP tier with its base
    /// URL and manifest path, `BackgroundAssetsCDNProvider` the Apple-hosted tier; `nil` for any other conformance.
    public static func remoteConfiguration(for provider: any CDNProviding) -> RemoteConfiguration? {
        // WP-K skeleton: no provider is recognised yet.
        nil
    }

    /// Installs a client for `configuration` into `point` (the process-wide one by default) unless one is installed
    /// already, and returns the installed client: the first installation wins (`CDNInstallPoint`).
    @MainActor
    @discardableResult
    public static func install(
        _ configuration: CDNConfiguration,
        into point: CDNInstallPoint = .process,
        environment: AssetEnvironment? = nil
    ) -> AssetClient {
        // WP-K skeleton: nothing is installed yet.
        CDNProviderFactory.makeClient(configuration, environment: environment)
    }
}
