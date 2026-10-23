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
        let (messages, mailbox) = AsyncStream.makeStream(of: Message.self)
        self.mailbox = mailbox
        self.makeToken = makeToken
        self.registry = Task {
            await NetworkAvailabilityMonitor.serve(messages)
        }
        // The forwarder holds the mailbox's continuation, never the monitor, so releasing the monitor ends both tasks.
        self.forwarder = Task {
            guard let stream = await events() else {
                return
            }
            for await event in stream {
                if case .conditionsChanged(let conditions) = event, conditions.network.satisfied {
                    mailbox.yield(.available)
                }
            }
        }
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
        let token = self.makeToken()
        self.mailbox.yield(.register(token, retry))
        return token
    }

    /// Withdraws a registered retry; a token that already ran or was cancelled changes nothing.
    public func cancelRetry(_ token: UUID) {
        self.mailbox.yield(.cancel(token))
    }

    /// Returns once every registration, cancellation and connectivity report made before the call was applied, with the
    /// number of retries still pending (a test seam: what the prior art's tests drove with `runPendingRetries()`).
    func flush() async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            self.mailbox.yield(.flush(continuation))
        }
    }

    /// The registry: the only owner of the pending retries, applying the mailbox in order. Retries run in registration
    /// order (the prior art's order was a dictionary's), each once, on this task.
    private static func serve(_ messages: AsyncStream<Message>) async {
        var pending: [UUID: @Sendable () -> Void] = [:]
        var order: [UUID] = []
        for await message in messages {
            switch message {
            case .register(let token, let retry):
                if pending.updateValue(retry, forKey: token) == nil {
                    order.append(token)
                }
            case .cancel(let token):
                if pending.removeValue(forKey: token) != nil {
                    order.removeAll { $0 == token }
                }
            case .available:
                let due = order.compactMap { pending[$0] }
                pending.removeAll()
                order.removeAll()
                for retry in due {
                    retry()
                }
            case .flush(let continuation):
                continuation.resume(returning: pending.count)
            }
        }
    }
}
