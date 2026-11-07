/// Which lanes may use which networks (R-SYN-7). Defaults are a product choice (ADR-036, NEEDS-HUMAN-REVIEW).
public struct NetworkPolicy: Sendable, Hashable, Codable {
    /// Bulk sync on expensive networks (cellular, hotspot). Default `true`: the prior art synced on any network.
    public var bulkOnExpensive: Bool
    /// Bulk sync in Low Data Mode. Default `false`: the user asked for less data.
    public var bulkOnConstrained: Bool
    /// Prefetch on expensive networks. Default `true`.
    public var prefetchOnExpensive: Bool
    /// Prefetch in Low Data Mode. Default `false`.
    public var prefetchOnConstrained: Bool
    /// Explicit user requests ignore the network restrictions above (R-SYN-7 "may override per policy").
    public var userInitiatedOverridesPolicy: Bool

    /// The defaults of ADR-036.
    public init(
        bulkOnExpensive: Bool = true,
        bulkOnConstrained: Bool = false,
        prefetchOnExpensive: Bool = true,
        prefetchOnConstrained: Bool = false,
        userInitiatedOverridesPolicy: Bool = true
    ) {
        self.bulkOnExpensive = bulkOnExpensive
        self.bulkOnConstrained = bulkOnConstrained
        self.prefetchOnExpensive = prefetchOnExpensive
        self.prefetchOnConstrained = prefetchOnConstrained
        self.userInitiatedOverridesPolicy = userInitiatedOverridesPolicy
    }
}

/// Which lanes may run under Low Power Mode and thermal pressure (R-SYN-7). Defaults: ADR-036.
public struct PowerPolicy: Sendable, Hashable, Codable {
    /// Bulk sync in Low Power Mode. Default `false`.
    public var bulkInLowPowerMode: Bool
    /// Prefetch in Low Power Mode. Default `true` (it keeps the visible pages ready).
    public var prefetchInLowPowerMode: Bool
    /// Bulk and prefetch pause at or above this thermal level. Default `.serious`.
    public var pauseBackgroundAtThermal: ThermalLevel
    /// Paused work resumes only at or below this level (hysteresis, sync-2 S2-25). Default `.fair`.
    public var resumeBackgroundAtThermal: ThermalLevel
    /// Concurrent user-initiated transfers allowed at `.critical`. Default 1. Applies to dispatch decisions taken
    /// while the thermal state is known; transfers started before a critical reading arrives are not trimmed.
    public var interactiveConcurrencyAtCritical: Int

    /// The defaults of ADR-036.
    public init(
        bulkInLowPowerMode: Bool = false,
        prefetchInLowPowerMode: Bool = true,
        pauseBackgroundAtThermal: ThermalLevel = .serious,
        resumeBackgroundAtThermal: ThermalLevel = .fair,
        interactiveConcurrencyAtCritical: Int = 1
    ) {
        self.bulkInLowPowerMode = bulkInLowPowerMode
        self.prefetchInLowPowerMode = prefetchInLowPowerMode
        self.pauseBackgroundAtThermal = pauseBackgroundAtThermal
        self.resumeBackgroundAtThermal = resumeBackgroundAtThermal
        self.interactiveConcurrencyAtCritical = interactiveConcurrencyAtCritical
    }
}
