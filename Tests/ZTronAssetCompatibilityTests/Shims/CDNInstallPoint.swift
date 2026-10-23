import Foundation
import ZTronAssetKit

/// R-CAR-6 shim: where the prior art's process-wide entry points (`CDNAssetResolver.installed`,
/// `CDNLocalStore.shared`, `NetworkAvailabilityMonitor.shared`) find the one `AssetClient` they adapt.
///
/// The prior art kept `CDNAssetResolver.installed` in a `nonisolated(unsafe) static var` (RECON D-19), which SPEC §4.2
/// forbids. An install point is not mutable global state: it is reached through a `static let`, its single slot is
/// isolated to the main actor (so the compiler proves every access race-free, with no lock and no unsafe escape), and
/// the slot is written at most once. The first installation wins and later ones return the installed client, so after
/// launch the slot is as immutable as a lazily initialised `static let`, only with a value the app supplies. Every shim
/// also takes an explicit client, so apps and tests can avoid the process-wide point entirely.
@MainActor
public final class CDNInstallPoint {
    /// The point the prior art's process-wide entry points follow.
    nonisolated public static let process = CDNInstallPoint()

    /// What a client built here for a prior-art provider looks like (`installClient(for:)`): location, legacy
    /// migration, refresh policy, and the remote tiers a custom provider leaves unset.
    nonisolated public let configuration: CDNConfiguration
    /// The environment such a client runs in (`nil` builds `.live()`); tests pass fakes.
    nonisolated let environment: AssetEnvironment?
    private var installed: AssetClient?

    /// An empty point whose clients are built from `configuration` and `environment`.
    nonisolated public init(configuration: CDNConfiguration = CDNConfiguration(), environment: AssetEnvironment? = nil) {
        self.configuration = configuration
        self.environment = environment
    }

    /// A point that already holds `client` (what `CDNLocalStore(client:)` binds to).
    nonisolated public init(client: AssetClient) {
        self.configuration = CDNConfiguration(clientConfiguration: client.configuration)
        self.environment = nil
        // WP-K skeleton: the client is not kept yet.
    }

    /// The installed client, if any.
    public var client: AssetClient? {
        self.installed
    }

    /// Installs `client` unless a client is installed already; returns the installed client.
    @discardableResult
    public func install(_ client: AssetClient) -> AssetClient {
        // WP-K skeleton: nothing is kept yet.
        client
    }

    /// The installed client, or one built for `provider` (`CDNProviderFactory.makeClient(for:base:environment:)`
    /// with this point's configuration and environment) and installed now. Only the first provider builds a client.
    @discardableResult
    public func installClient(for provider: any CDNProviding) -> AssetClient {
        // WP-K skeleton: nothing is built or kept yet.
        CDNProviderFactory.makeClient(for: provider, base: self.configuration, environment: self.environment)
    }

    /// Suspends until a client is installed and returns it; `nil` when the calling task is cancelled first.
    public func waitForClient() async -> AssetClient? {
        // WP-K skeleton: nobody waits yet.
        self.installed
    }
}
