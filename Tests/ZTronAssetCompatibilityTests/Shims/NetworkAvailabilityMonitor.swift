import Foundation
import ZTronAssetKit

/// R-CAR-6 shim of the prior art's connectivity retry (`NetworkAvailabilityMonitor.swift`, read-only), as an adapter
/// over the client's events: a retry registered after a failed on-demand fetch runs the next time the client reports a
/// satisfied network path (`AssetEvent.conditionsChanged`, fed by the client's own reachability, R-NET-9).
///
/// The prior art guarded its registry with a dispatch queue behind `@unchecked Sendable` and `nonisolated(unsafe)`
/// (D-5). Here the registry belongs to one task that consumes a single ordered mailbox (an `AsyncStream`, whose
/// continuation is `Sendable`), so registrations, cancellations and connectivity reports are applied in the order they
/// were made, with no lock and no unsafe escape, and `retryWhenAvailable` and `cancelRetry` stay synchronous and
/// nonisolated (ZTronSVGView cancels from its `deinit`). Like the prior art's path monitor, the first report after the
/// subscription (the client replays the current conditions) counts: a retry registered while online runs at once.
public final class NetworkAvailabilityMonitor: Sendable {
    /// What the registry task consumes, in order.
    private enum Message: Sendable {
        case register(UUID, @Sendable () -> Void)
        case cancel(UUID)
        case available
        case flush(CheckedContinuation<Int, Never>)
    }

    /// The prior art's shared monitor: it follows `CDNInstallPoint.process`, waiting for the app to install a client.
    public static let shared = NetworkAvailabilityMonitor(installPoint: .process)

    private let mailbox: AsyncStream<Message>.Continuation
    private let registry: Task<Void, Never>
    private let forwarder: Task<Void, Never>
    private let makeToken: @Sendable () -> UUID

    /// A monitor over `client`'s connectivity reports.
    public convenience init(client: AssetClient) {
        self.init(events: { client.events })
    }

    /// A monitor over the connectivity reports of whatever client `installPoint` holds, once one is installed.
    public convenience init(installPoint: CDNInstallPoint) {
        self.init(events: { await installPoint.waitForClient()?.events })
    }

    /// A monitor over the event stream `events` returns (`nil`: none, so retries stay pending), with tokens from
    /// `makeToken` (the live default draws random UUIDs, as the prior art did).
    init(events: @escaping @Sendable () async -> AsyncStream<AssetEvent>?, makeToken: @escaping @Sendable () -> UUID = UUID.init) {
        let (_, mailbox) = AsyncStream.makeStream(of: Message.self)
        self.mailbox = mailbox
        self.makeToken = makeToken
        // WP-K skeleton: nothing consumes the mailbox and nothing follows the client yet.
        self.registry = Task {}
        self.forwarder = Task {}
    }

    deinit {
        self.mailbox.finish()
        self.registry.cancel()
        self.forwarder.cancel()
    }

    /// Registers `retry` to run the next time the client reports a satisfied network path, and returns its token.
    /// Device connectivity says nothing about whether the origin has the asset; it is only a reasonable moment to try.
    @discardableResult
    public func retryWhenAvailable(_ retry: @escaping @Sendable () -> Void) -> UUID {
        // WP-K skeleton: nothing is registered yet.
        self.makeToken()
    }

    /// Withdraws a registered retry; a token that already ran or was cancelled changes nothing.
    public func cancelRetry(_ token: UUID) {
        // WP-K skeleton: nothing is withdrawn yet.
    }

    /// Returns once every registration, cancellation and connectivity report made before the call was applied, with the
    /// number of retries still pending (a test seam: what the prior art's tests drove with `runPendingRetries()`).
    func flush() async -> Int {
        // WP-K skeleton: nothing is pending yet.
        0
    }
}
