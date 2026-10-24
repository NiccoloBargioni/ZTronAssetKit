import Foundation
import ZTronAssetKit

/// R-CAR-6 shim of the prior art's connectivity retry (`NetworkAvailabilityMonitor.swift`, read-only): a retry
/// registered after a failed on-demand fetch runs the next time the network path is reported satisfied.
///
/// The prior art watched `NWPathMonitor` directly. The shim watches the module's reachability seam,
/// `AssetEnvironment.conditions` (the live conformer is the one every client is built with), not a client's events: a
/// client with nothing to do observes nothing (R-SYN-14), and a retry is registered exactly when the client has given up
/// on the asset, so its events would never announce the network's return. Observation starts with the first
/// registration and lasts as long as the monitor, like the prior art's monitor once created; every report of a satisfied
/// path runs the pending retries, the first one included, as the prior art's initial path update did.
///
/// A report is a conditions report, not only a path update: the live source sends one on every path change and also on
/// every Low Power Mode or thermal-state change, so a pending retry also runs on those reports while the path is
/// satisfied, where the prior art's `NWPathMonitor` retried on path updates only. A view that keeps failing (ZTronSVGView
/// registers again after each failure) therefore also retries then. Running retries only on a changed `network` value
/// would lose path updates the prior art retried on (Wi-Fi to another Wi-Fi), so the shim keeps every satisfied report
/// (orchestrator ruling L5K-R6, K-8). `shared` builds its own live conditions source (ADR-038: fresh conformers per call),
/// so it is a second path monitor in the process beside the one each client observes.
///
/// The prior art guarded its registry with a dispatch queue behind `@unchecked Sendable` and `nonisolated(unsafe)`
/// (D-5). Here the registry belongs to one task that consumes a single ordered mailbox (an `AsyncStream`, whose
/// continuation is `Sendable`), so registrations, cancellations and reports are applied in order with no lock and no
/// unsafe escape, and `retryWhenAvailable` and `cancelRetry` stay synchronous and nonisolated (ZTronSVGView cancels from
/// its `deinit`).
public final class NetworkAvailabilityMonitor: Sendable {
    /// What the registry task consumes, in order.
    private enum Message: Sendable {
        case register(UUID, @Sendable () -> Void)
        case cancel(UUID)
        case report(DeviceConditions)
        case flush(CheckedContinuation<Int, Never>)
    }

    /// The prior art's shared monitor, over the live reachability conformer (inert until the first registration).
    public static let shared = NetworkAvailabilityMonitor(conditions: AssetEnvironment.live().conditions)

    private let mailbox: AsyncStream<Message>.Continuation
    private let registry: Task<Void, Never>
    private let makeToken: @Sendable () -> UUID

    /// A monitor over `conditions` (tests pass `FakeDeviceConditionsSource`).
    public convenience init(conditions: any DeviceConditionsSource) {
        self.init(conditions: conditions, makeToken: UUID.init)
    }

    /// A monitor whose tokens come from `makeToken` (the live default draws random UUIDs, as the prior art did).
    init(conditions: any DeviceConditionsSource, makeToken: @escaping @Sendable () -> UUID) {
        let (messages, mailbox) = AsyncStream.makeStream(of: Message.self)
        self.mailbox = mailbox
        self.makeToken = makeToken
        // The task holds the mailbox and the source, never the monitor, so releasing the monitor ends it (`deinit`).
        self.registry = Task {
            await NetworkAvailabilityMonitor.serve(messages, mailbox: mailbox, conditions: conditions)
        }
    }

    deinit {
        self.mailbox.finish()
        self.registry.cancel()
    }

    /// Registers `retry` to run at the next satisfied conditions report (a path change, or a power or thermal report while
    /// the path is satisfied), and returns its token. Device
    /// connectivity says nothing about whether the origin has the asset; it is only a reasonable moment to try again.
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

    /// Returns once every registration, cancellation and report queued before the call was applied, with the number of
    /// retries still pending (a test seam: what the prior art's tests drove with `runPendingRetries()`).
    func flush() async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            self.mailbox.yield(.flush(continuation))
        }
    }

    /// The registry: the only owner of the pending retries, applying the mailbox in order. The first registration starts
    /// the observation, whose reports join the same mailbox; retries run in registration order (the prior art's order
    /// was a dictionary's), each once, on this task. Ending the registry ends the observation.
    private static func serve(
        _ messages: AsyncStream<Message>,
        mailbox: AsyncStream<Message>.Continuation,
        conditions: any DeviceConditionsSource
    ) async {
        var pending: [UUID: @Sendable () -> Void] = [:]
        var order: [UUID] = []
        var observation: Task<Void, Never>?
        defer {
            observation?.cancel()
        }
        for await message in messages {
            switch message {
            case .register(let token, let retry):
                if pending.updateValue(retry, forKey: token) == nil {
                    order.append(token)
                }
                if observation == nil {
                    observation = Task {
                        for await current in await conditions.conditions() {
                            mailbox.yield(.report(current))
                        }
                    }
                }
            case .cancel(let token):
                if pending.removeValue(forKey: token) != nil {
                    order.removeAll { $0 == token }
                }
            case .report(let current):
                guard current.network.satisfied else {
                    continue
                }
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
