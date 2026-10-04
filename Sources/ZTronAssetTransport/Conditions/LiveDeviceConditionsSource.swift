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

    /// Creates the source (no observation starts until `conditions()`).
    public init(center: NotificationCenter = .default) {
        self.center = center
    }

    /// Starts one observation (`.bufferingNewest(1)`).
    public func conditions() async -> AsyncStream<DeviceConditions> {
        fatalError("WP-D: LiveDeviceConditionsSource.conditions not implemented")
    }
}
