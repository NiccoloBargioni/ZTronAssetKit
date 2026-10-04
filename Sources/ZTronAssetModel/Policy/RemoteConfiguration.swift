import Foundation

/// The CloudFront app key (SPEC §2.3): a scraper filter shipped in the binary, still treated as a secret.
///
/// It redacts itself everywhere a value can be printed (R-NET-4, R-SEC-1): `description`, `debugDescription`,
/// `dump` and `Mirror` show `AppKey(<redacted>)` and no children. It is deliberately not `Codable`, so it can never
/// reach `diagnosticReport()` JSON. Only code inside this package can read the secret (`package` access).
public struct AppKey: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The secret. Readable inside the package only; apps can create a key but never read it back.
    package let secret: String

    /// Wraps a key.
    public init(_ secret: String) {
        self.secret = secret
    }

    /// Always `AppKey(<redacted>)`.
    public var description: String {
        "AppKey(<redacted>)"
    }

    /// Always `AppKey(<redacted>)`.
    public var debugDescription: String {
        "AppKey(<redacted>)"
    }

    /// A mirror with no children, so `dump` and reflection never reach the secret.
    public var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .struct)
    }
}

/// Whether, and how, bulk transfers may use a background `URLSession` (R-NET-3, ADR-026 NEEDS-HUMAN-REVIEW).
public enum BackgroundTransferPolicy: Sendable, Hashable {
    /// Every transfer runs in the foreground session (the default).
    case disabled
    /// The app attests that it forwards `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// to `AssetClient.handleBackgroundEvents`.
    case enabled(BackgroundTransferOptions)
}

/// What a background-session transfer may do when the redirect delegate cannot run (NSURLSession.h:1732).
public enum KeyRedirectExposure: Sendable, Hashable {
    /// A request carrying the app key never uses the background session (R-NET-4 holds). The default.
    case refuse
    /// The owner accepts that the OS follows redirects *with* the key, and that the size cap (R-NET-7) and the
    /// 5-hop limit (R-NET-4) cannot be enforced while the app is not running (ADR-026).
    case acceptedByOwner
}

/// Options of an enabled background session.
public struct BackgroundTransferOptions: Sendable, Hashable {
    /// Namespace of the session identifier `com.ztron.assetkit.bg.<namespace>.v1`; `[0-9a-z-]{1,32}`.
    public var namespace: String
    /// `URLSessionConfiguration.isDiscretionary`.
    public var discretionary: Bool
    /// Tasks handed to the OS at once (bounds the lifecycle buffer, transport-2 T2-17).
    public var maxTasks: Int
    /// Redirect exposure of key-bearing requests.
    public var keyRedirectExposure: KeyRedirectExposure

    /// Creates options with the transport design's defaults.
    public init(
        namespace: String = "default",
        discretionary: Bool = true,
        maxTasks: Int = 32,
        keyRedirectExposure: KeyRedirectExposure = .refuse
    ) {
        self.namespace = namespace
        self.discretionary = discretionary
        self.maxTasks = maxTasks
        self.keyRedirectExposure = keyRedirectExposure
    }
}

/// The AWS (CloudFront) tier (SPEC §2.3).
public struct HTTPSourceConfiguration: Sendable, Hashable {
    /// `https://<distribution>/`; its host is allow-listed implicitly.
    public var baseURL: URL
    /// The manifest path relative to `baseURL`.
    public var manifestPath: String
    /// The app key, sent only to allow-listed HTTPS origins (R-NET-4).
    public var appKey: AppKey?
    /// The header that carries the key.
    public var keyHeaderName: String
    /// Further hosts a redirect may follow (the key is stripped on any cross-origin hop).
    public var additionalAllowedHosts: Set<String>
    /// `httpMaximumConnectionsPerHost`, clamped to 1…8 (P-10).
    public var maxConnectionsPerHost: Int
    /// Request timeout in seconds, applied to the session and every request.
    public var requestTimeout: TimeInterval
    /// Background-session use for bulk transfers.
    public var background: BackgroundTransferPolicy

    /// Creates a configuration with the transport design's defaults.
    public init(
        baseURL: URL,
        manifestPath: String = "manifest.json",
        appKey: AppKey? = nil,
        keyHeaderName: String = "x-zombietron-app-key",
        additionalAllowedHosts: Set<String> = [],
        maxConnectionsPerHost: Int = 6,
        requestTimeout: TimeInterval = 30,
        background: BackgroundTransferPolicy = .disabled
    ) {
        self.baseURL = baseURL
        self.manifestPath = manifestPath
        self.appKey = appKey
        self.keyHeaderName = keyHeaderName
        self.additionalAllowedHosts = additionalAllowedHosts
        self.maxConnectionsPerHost = maxConnectionsPerHost
        self.requestTimeout = requestTimeout
        self.background = background
    }
}

/// What happens to an Apple-hosted pack once its content was adopted into `blobs/` (H-7, ADR-027).
public enum PackRetention: Sendable, Hashable {
    /// Keep packs (permanent double residency; never a whole-pack re-download).
    case keepPacks
    /// Release a media pack once every entry mapped to it is adopted or excluded by the keep-scope (the default).
    case releaseAfterAdoption
}

/// The Apple-hosted tier (R-APL-1…5). Pack ids and paths are plain strings here and validated by
/// `ZTronAssetAppleHosted` (`PackID`, `PackLocation`).
public struct AppleTierConfiguration: Sendable, Hashable {
    /// The essential pack holding the catalog JSON.
    public var catalogPackID: String
    /// The catalog's path inside that pack.
    public var catalogPath: String
    /// Retention of media packs after adoption.
    public var retention: PackRetention
    /// Whether a manifest fetch also schedules a best-effort `checkForUpdates()` (never awaited before the
    /// installed catalog is read, transport-2 T2-14).
    public var updateCheckOnManifestFetch: Bool

    /// The SPEC §2.3 layout: catalog `ZTronCatalog/catalog.json`, release after adoption, update checks on.
    public init(
        catalogPackID: String = "ZTronCatalog",
        catalogPath: String = "catalog.json",
        retention: PackRetention = .releaseAfterAdoption,
        updateCheckOnManifestFetch: Bool = true
    ) {
        self.catalogPackID = catalogPackID
        self.catalogPath = catalogPath
        self.retention = retention
        self.updateCheckOnManifestFetch = updateCheckOnManifestFetch
    }
}

/// The remote side of a client: which tiers exist and the kill switch (R-APL-5).
public struct RemoteConfiguration: Sendable, Hashable {
    /// The AWS tier, used on iOS 15–25 and whenever the Apple tier is not selected.
    public var http: HTTPSourceConfiguration?
    /// The Apple-hosted tier, used on iOS 26+ unless `awsOnly`.
    public var appleHosted: AppleTierConfiguration?
    /// Kill switch: never select the Apple tier.
    public var awsOnly: Bool

    /// Creates a remote configuration.
    public init(http: HTTPSourceConfiguration? = nil, appleHosted: AppleTierConfiguration? = nil, awsOnly: Bool = false) {
        self.http = http
        self.appleHosted = appleHosted
        self.awsOnly = awsOnly
    }
}
