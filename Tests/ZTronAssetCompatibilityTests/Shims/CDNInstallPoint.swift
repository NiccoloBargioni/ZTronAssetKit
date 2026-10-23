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
    /// The client a point was created with (`init(client:)`): set before the point is shared, never changed.
    nonisolated private let initial: AssetClient?
    /// The client installed later, at most once, when there was no initial one.
    private var installed: AssetClient?
    /// Tasks waiting in `waitForClient()`, resumed by the installation or by their cancellation.
    private var waiters: [UInt64: CheckedContinuation<AssetClient?, Never>] = [:]
    private var lastWaiter: UInt64 = 0

    /// An empty point whose clients are built from `configuration` and `environment`.
    nonisolated public init(configuration: CDNConfiguration = CDNConfiguration(), environment: AssetEnvironment? = nil) {
        self.configuration = configuration
        self.environment = environment
        self.initial = nil
    }

    /// A point that already holds `client` (what `CDNLocalStore(client:)` binds to).
    nonisolated public init(client: AssetClient) {
        self.configuration = CDNConfiguration(clientConfiguration: client.configuration)
        self.environment = nil
        self.initial = client
    }

    /// The installed client, if any.
    public var client: AssetClient? {
        self.initial ?? self.installed
    }

    /// Installs `client` unless a client is installed already; returns the installed client.
    @discardableResult
    public func install(_ client: AssetClient) -> AssetClient {
        if let current = self.client {
            return current
        }
        self.installed = client
        let waiting = self.waiters
        self.waiters = [:]
        for continuation in waiting.values {
            continuation.resume(returning: client)
        }
        return client
    }

    /// The installed client, or one built for `provider` (`CDNProviderFactory.makeClient(for:base:environment:)`
    /// with this point's configuration and environment) and installed now. Only the first provider builds a client.
    @discardableResult
    public func installClient(for provider: any CDNProviding) -> AssetClient {
        if let current = self.client {
            return current
        }
        return self.install(CDNProviderFactory.makeClient(for: provider, base: self.configuration, environment: self.environment))
    }

    /// Suspends until a client is installed and returns it; `nil` when the calling task is cancelled first.
    public func waitForClient() async -> AssetClient? {
        if let current = self.client {
            return current
        }
        self.lastWaiter += 1
        let key = self.lastWaiter
        // REENTRANCY: k-1 (proposed) — nothing is read after the wait: the continuation carries the installed client
        // (written once, so it cannot change afterwards) or nil, and only one of `install` and `cancelWaiter` finds the
        // key, so the wait resumes exactly once.
        return await withTaskCancellationHandler {
            // REENTRANCY: k-1 (proposed) — as above; the body registers synchronously, after re-reading the slot and
            // the cancellation flag on the main actor.
            await withCheckedContinuation { (continuation: CheckedContinuation<AssetClient?, Never>) in
                if let current = self.client {
                    continuation.resume(returning: current)
                } else if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    self.waiters[key] = continuation
                }
            }
        } onCancel: {
            // The handler runs on the cancelling thread; the slot is the main actor's, so the withdrawal hops there.
            // A cancellation that lands before the registration finds no key here, and the body sees the flag.
            Task { @MainActor in
                self.cancelWaiter(key)
            }
        }
    }

    /// Resumes a cancelled waiter with `nil`, unless the installation resumed it already.
    private func cancelWaiter(_ key: UInt64) {
        self.waiters.removeValue(forKey: key)?.resume(returning: nil)
    }
}
