import Foundation
import ZTronAssetModel

/// Pure mappings from system values to `DeviceConditions` (R-NET-9), tested exhaustively.
public enum ConditionsMapping {
    /// `NWPath` facts as `NetworkConditions`.
    public static func network(satisfied: Bool, expensive: Bool, constrained: Bool) -> NetworkConditions {
        NetworkConditions(satisfied: satisfied, expensive: expensive, constrained: constrained)
    }

    /// `ProcessInfo.ThermalState` as a `ThermalLevel`; unknown future states map to `.critical`.
    public static func thermal(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal:
            return .nominal
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            return .critical
        }
    }
}

/// The live reachability and power source (R-NET-9, R-SYN-7; WP-D).
///
/// `NWPathMonitor` and the notification tokens are owned by an actor (their `Sendable` conformances are iOS 17+
/// or absent, transport.md §9); both inputs are delivered on one serial queue so every element is a consistent
/// snapshot. Event-driven: each `conditions()` call starts one observation whose first element is the current
/// state; terminating the stream stops it, so an idle engine observes nothing (R-SYN-14).
public final class LiveDeviceConditionsSource: DeviceConditionsSource {
    /// The notification center for power and thermal changes.
    public let center: NotificationCenter
    private let makePathObserver: @Sendable () -> any PathObserving
    private let power: @Sendable () -> PowerConditions
    private let registry = ObservationRegistry()

    /// Creates the source (no observation starts until `conditions()`).
    public init(center: NotificationCenter = .default) {
        self.center = center
        self.makePathObserver = LiveDeviceConditionsSource.livePathObserver
        self.power = LiveDeviceConditionsSource.processPower
    }

    /// The path-ingest seam of ARCHITECTURE §6.5: an `NWPath` change cannot be injected in-process, so tests give
    /// their own path observer (and may give the power reading) and drive both halves without the network.
    package init(
        center: NotificationCenter,
        makePathObserver: @escaping @Sendable () -> any PathObserving,
        power: @escaping @Sendable () -> PowerConditions = LiveDeviceConditionsSource.processPower
    ) {
        self.center = center
        self.makePathObserver = makePathObserver
        self.power = power
    }

    /// Starts one observation (`.bufferingNewest(1)`): the path observer's first delivery is the current state;
    /// every later path change and every power or thermal notification on `center` yields a full snapshot.
    public func conditions() async -> AsyncStream<DeviceConditions> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceConditions.self, bufferingPolicy: .bufferingNewest(1))
        let observation = ConditionsObservation(center: self.center, path: self.makePathObserver(), power: self.power)
        let registry = self.registry
        await registry.add()
        continuation.onTermination = { _ in
            Task {
                await observation.stop()
                await registry.remove()
            }
        }
        await observation.start(continuation)
        return stream
    }

    /// Observations started and not yet stopped (the census an idle engine is checked against, R-SYN-14).
    package var activeObservations: Int {
        get async {
            await self.registry.active
        }
    }

    /// Returns once exactly `count` observations are active (a terminated one stops after a hop); event-driven. It
    /// also returns, with the count unmet, when the calling task is cancelled, so a test past its time limit ends
    /// instead of hanging the run (L2 close); `requireObservations(equalTo:)` throws then.
    package func waitForObservations(equalTo count: Int) async {
        await self.registry.wait(for: count)
    }

    /// Returns once exactly `count` observations are active; throws `CancellationError` when the calling task is
    /// cancelled first, so a test whose next step relies on the count stops there instead of awaiting work that
    /// never started (L2 close). A count already matched is reported matched, cancelled or not.
    package func requireObservations(equalTo count: Int) async throws(CancellationError) {
        guard await self.registry.wait(for: count) else {
            throw CancellationError()
        }
    }

    /// The seam that tests the wait itself: `true` once exactly `count` observations are active, `false` when the
    /// calling task was cancelled first. `registered` runs once the wait is registered (never when the count already
    /// matched), so a test can cancel a wait it knows is pending.
    package func waitForObservations(equalTo count: Int, registered: @escaping @Sendable () -> Void) async -> Bool {
        await self.registry.wait(for: count, registered: registered)
    }

    /// A new `NWPathMonitor` behind `PathObserving`: what the public initialiser observes, available to tests that
    /// wrap the live observer (to count its deliveries) through the package initialiser.
    package static let livePathObserver: @Sendable () -> any PathObserving = {
        LivePathObserver()
    }

    /// `ProcessInfo`'s Low Power Mode and thermal state.
    package static let processPower: @Sendable () -> PowerConditions = {
        let info = ProcessInfo.processInfo
        return PowerConditions(lowPowerMode: info.isLowPowerModeEnabled, thermal: ConditionsMapping.thermal(info.thermalState))
    }
}
