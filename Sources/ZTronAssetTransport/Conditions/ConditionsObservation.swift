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

    /// Registers for power and thermal notifications and starts the path observer, all on one serial queue.
    func start(_ continuation: AsyncStream<DeviceConditions>.Continuation) {
        let path = self.path
        let power = self.power
        let names = [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange]
        for name in names {
            let token = self.center.addObserver(forName: name, object: nil, queue: self.operations) { _ in
                continuation.yield(DeviceConditions(network: path.current, power: power()))
            }
            self.tokens.append(token)
        }
        path.start(queue: self.queue) { network in
            continuation.yield(DeviceConditions(network: network, power: power()))
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
actor ObservationRegistry {
    private(set) var active = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func add() {
        self.active += 1
        self.wake()
    }

    func remove() {
        self.active -= 1
        self.wake()
    }

    func wait(for count: Int) async {
        if self.active == count {
            return
        }
        // REENTRANCY: D-11 (proposed) — a terminal wait, registered synchronously and resumed by `wake()` once the
        // count matches; nothing is read afterwards.
        await withCheckedContinuation { continuation in
            self.waiters.append((count, continuation))
        }
    }

    private func wake() {
        let ready = self.waiters.filter { $0.count == self.active }
        self.waiters.removeAll { $0.count == self.active }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
