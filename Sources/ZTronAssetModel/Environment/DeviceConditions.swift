/// The network half of `DeviceConditions` (R-NET-9).
public struct NetworkConditions: Sendable, Hashable, Codable {
    /// `NWPath.status == .satisfied`.
    public var satisfied: Bool
    /// `NWPath.isExpensive` (cellular, personal hotspot).
    public var expensive: Bool
    /// `NWPath.isConstrained` (Low Data Mode).
    public var constrained: Bool

    /// Creates network conditions.
    public init(satisfied: Bool, expensive: Bool, constrained: Bool) {
        self.satisfied = satisfied
        self.expensive = expensive
        self.constrained = constrained
    }
}

/// `ProcessInfo.ThermalState`, as a comparable value (unknown future states map to `.critical`).
public enum ThermalLevel: Int, Sendable, Hashable, Comparable, Codable, CaseIterable {
    /// Nominal.
    case nominal = 0
    /// Fair.
    case fair = 1
    /// Serious.
    case serious = 2
    /// Critical.
    case critical = 3

    /// Orders by severity.
    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The power half of `DeviceConditions` (R-SYN-7).
public struct PowerConditions: Sendable, Hashable, Codable {
    /// `ProcessInfo.isLowPowerModeEnabled`.
    public var lowPowerMode: Bool
    /// `ProcessInfo.thermalState`.
    public var thermal: ThermalLevel

    /// Creates power conditions.
    public init(lowPowerMode: Bool, thermal: ThermalLevel) {
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
    }
}

/// A full, consistent snapshot of network and power state (transport design T-12: one serial queue).
public struct DeviceConditions: Sendable, Hashable, Codable {
    /// Network state.
    public var network: NetworkConditions
    /// Power state.
    public var power: PowerConditions

    /// Creates a snapshot.
    public init(network: NetworkConditions, power: PowerConditions) {
        self.network = network
        self.power = power
    }

    /// Satisfied, unmetered, unconstrained, normal power: what tests assume unless they say otherwise.
    public static let unrestricted = DeviceConditions(
        network: NetworkConditions(satisfied: true, expensive: false, constrained: false),
        power: PowerConditions(lowPowerMode: false, thermal: .nominal)
    )
}

/// Reachability and power, event-driven (R-NET-9, R-SYN-13). Never polled.
///
/// Each call starts one observation. The first element is the current state; later elements arrive on change.
/// Terminating the stream (consumer cancelled or the stream released) stops the underlying observation, so an
/// idle engine observes nothing (R-SYN-14). Live: `LiveDeviceConditionsSource` (Transport), which owns
/// `NWPathMonitor` in an actor because its `Sendable` conformance is iOS 17+.
public protocol DeviceConditionsSource: Sendable {
    /// Starts an observation.
    func conditions() async -> AsyncStream<DeviceConditions>
}
