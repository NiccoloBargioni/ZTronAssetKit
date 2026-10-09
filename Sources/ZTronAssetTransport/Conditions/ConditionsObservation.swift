import Foundation
import Network
import ZTronAssetModel

/// Where path changes come from (ARCHITECTURE §6.5): `NWPathMonitor` live, a scripted observer in tests.
package protocol PathObserving: AnyObject, Sendable {
    /// Starts delivering path changes on `queue`; the first delivery is the current path.
    func start(queue: DispatchQueue, onUpdate: @escaping @Sendable (NetworkConditions) -> Void)
    /// The latest path, read on `queue`.
    var current: NetworkConditions { get }
    /// Stops delivering.
    func cancel()
}

/// `NWPathMonitor` behind `PathObserving`. Its `Sendable` conformance is declared iOS 17 / macOS 14 and not
/// enforced as a marker (APPLE-API-VERIFICATION §3 #7); the monitor is only touched through its documented
/// thread-safe members (`start`, `cancel`, `currentPath`, the handler on its own queue).
final class LivePathObserver: PathObserving {
    private let monitor = NWPathMonitor()

    func start(queue: DispatchQueue, onUpdate: @escaping @Sendable (NetworkConditions) -> Void) {
        self.monitor.pathUpdateHandler = { path in
            onUpdate(LivePathObserver.conditions(of: path))
        }
        self.monitor.start(queue: queue)
    }

    var current: NetworkConditions {
        LivePathObserver.conditions(of: self.monitor.currentPath)
    }

    func cancel() {
        self.monitor.cancel()
    }

    private static func conditions(of path: NWPath) -> NetworkConditions {
        ConditionsMapping.network(satisfied: path.status == .satisfied, expensive: path.isExpensive, constrained: path.isConstrained)
    }
}

/// One observation of `LiveDeviceConditionsSource`: owns the path observer and the notification tokens, which are
/// not `Sendable`. `conditions()` awaits `start` before it returns the stream, so the stream's termination (the only
/// caller of `stop`) always comes after `start`.
actor ConditionsObservation {
    private let center: NotificationCenter
    private let path: any PathObserving
    private let power: @Sendable () -> PowerConditions
    private let queue: DispatchQueue
    private let operations: OperationQueue
    private var tokens: [any NSObjectProtocol] = []

    init(center: NotificationCenter, path: any PathObserving, power: @escaping @Sendable () -> PowerConditions) {
        self.center = center
        self.path = path
        self.power = power
        let queue = DispatchQueue(label: "com.ztron.assetkit.conditions")
        let operations = OperationQueue()
        operations.maxConcurrentOperationCount = 1
        operations.underlyingQueue = queue
        self.queue = queue
        self.operations = operations
    }

    /// Starts the path observer, then registers for power and thermal notifications, all on one serial queue. The
    /// path comes first so that a notification can never read `path.current` from an observer that has not started
    /// (an `NWPathMonitor` that has not started reports an unsatisfied path, which would make the first element a
    /// spurious offline snapshot instead of the current state, review round 3).
    func start(_ continuation: AsyncStream<DeviceConditions>.Continuation) {
        let path = self.path
        let power = self.power
        path.start(queue: self.queue) { network in
            continuation.yield(DeviceConditions(network: network, power: power()))
        }
        let names = [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange]
        for name in names {
            let token = self.center.addObserver(forName: name, object: nil, queue: self.operations) { _ in
                continuation.yield(DeviceConditions(network: path.current, power: power()))
            }
            self.tokens.append(token)
        }
    }

    /// Stops the path observer and removes the observers.
    func stop() {
        self.path.cancel()
        for token in self.tokens {
            self.center.removeObserver(token)
        }
        self.tokens = []
    }
}

/// Counts live observations and lets a caller wait for a count without polling.
///
/// A wait also ends when its caller is cancelled (L2 close, `docs/adr-drafts/l2close.md` item 1). A test past its
/// `.timeLimit` is cancelled and Swift Testing then waits for its body to return, so a wait that only the count could
/// end kept a regression that never reaches the count suspended for good, and the whole run hung instead of failing
/// one test. Each waiter is resumed exactly once, by whichever comes first: with `true` by the turn whose count
/// matched, or with `false` by its caller's cancellation. Every mutation runs on the actor, and a waiter is always
/// removed from the table before it is resumed.
actor ObservationRegistry {
    /// One suspended wait.
    private struct Waiter {
        let id: UInt64
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private(set) var active = 0
    private var waiters: [Waiter] = []
    private var lastWaiter: UInt64 = 0

    func add() {
        self.active += 1
        self.wake()
    }

    func remove() {
        self.active -= 1
        self.wake()
    }

    /// Suspends until exactly `count` observations are active, or until the calling task is cancelled: `true` when
    /// the count matched, `false` when the caller was cancelled first (a count already matched is reported matched,
    /// cancelled or not). `registered` runs on the actor once the wait is registered, so a test of the wait itself can
    /// cancel one it knows is pending.
    ///
    /// The count is checked, and the wait registered, synchronously in the continuation body, so no `add` or `remove`
    /// can fall between the check and the registration. A caller cancelled before the body ran is never registered
    /// (`Task.isCancelled`); one cancelled afterwards is resumed by the hop of the cancellation handler, which cannot
    /// touch actor state synchronously and finds nothing to do for a wait that `wake()` already resumed.
    @discardableResult
    func wait(for count: Int, registered: (@Sendable () -> Void)? = nil) async -> Bool {
        if self.active == count {
            return true
        }
        self.lastWaiter += 1
        let id = self.lastWaiter
        // REENTRANCY: D-11 (amended, l2close-1 proposed) — nothing: a terminal wait, registered synchronously in the
        // continuation body and resumed exactly once, by the `wake()` whose count matched or by `cancel(id)`; no state
        // is read afterwards (a caller re-reads `active`).
        return await withTaskCancellationHandler {
            // REENTRANCY: D-11 (amended, l2close-1 proposed) — as above.
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if self.active == count {
                    continuation.resume(returning: true)
                } else if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    self.waiters.append(Waiter(id: id, count: count, continuation: continuation))
                    registered?()
                }
            }
        } onCancel: {
            Task {
                // REENTRANCY: l2close-2 (proposed) — nothing: this task is not the actor's turn; `cancel(id)` re-reads
                // the table and is a no-op for a wait that `wake()` already resumed.
                await self.cancel(id)
            }
        }
    }

    /// Resumes with `true`, and removes, every wait whose count is now active.
    private func wake() {
        var ready: [CheckedContinuation<Bool, Never>] = []
        let active = self.active
        self.waiters.removeAll { waiter in
            guard waiter.count == active else {
                return false
            }
            ready.append(waiter.continuation)
            return true
        }
        for continuation in ready {
            continuation.resume(returning: true)
        }
    }

    /// Resumes wait `id` with `false` (its caller was cancelled); a no-op for a wait already resumed and removed.
    private func cancel(_ id: UInt64) {
        guard let index = self.waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        self.waiters.remove(at: index).continuation.resume(returning: false)
    }
}
