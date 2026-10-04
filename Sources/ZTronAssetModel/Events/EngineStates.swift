/// When a failed job may run again (R-SYN-2 `failed(retryAt)`, R-SYN-5, R-SYN-13).
public enum RetryDisposition: Sendable, Hashable {
    /// After a backoff deadline on the monotonic clock (alarm-driven).
    case at(MonotonicInstant)
    /// When the network path becomes satisfied again (R-SYN-13), without polling.
    case whenOnline
    /// The per-run attempt cap was reached; the next run retries.
    case nextRun
    /// Persisted in the index until the manifest entry's content identity changes: integrity exhaustion
    /// (`AssetStore.recordIntegrityFailure`, R-INT-3) or a 404/410 (`AssetStore.recordFailure(_:identity:reason:)`
    /// with `.notFound`, R-NET-6), so a relaunch never requests it again (ADR-032).
    case untilEntryChanges
}

/// Which policy blocked a lane (R-SYN-7).
public enum PolicyBlock: Sendable, Hashable {
    /// Expensive network not allowed for the lane.
    case expensiveNetwork
    /// Low Data Mode not allowed for the lane.
    case constrainedNetwork
    /// Low Power Mode not allowed for the lane.
    case lowPowerMode
    /// Thermal state at or above the pause threshold.
    case thermal(ThermalLevel)
}

/// What opened a circuit breaker (R-SYN-5, ARCHITECTURE §7.7).
public enum BreakerCause: Sendable, Hashable, Codable {
    /// Key-rejected evidence (manifest 403 with an empty body, or ambiguous 403s on several distinct assets).
    case authentication
    /// Sustained 5xx.
    case serverErrors
}

/// Why work is parked (R-SYN-2 `blocked(reason)`).
public enum BlockReason: Sendable, Hashable {
    /// No satisfied network path.
    case offline
    /// Network or power policy.
    case policy(PolicyBlock)
    /// The origin's breaker is open.
    case circuitOpen(BreakerCause)
    /// An origin-wide `Retry-After` is pending.
    case throttled(until: MonotonicInstant)
    /// Space is being reclaimed (doomed blobs past ack and grace); the engine's alarm wakes it (ADR-022).
    case awaitingSpace
    /// Not enough space even after permitted eviction (R-SYN-11).
    case insufficientSpace
}

/// The public face of an origin's breaker (events, diagnostics).
public enum CircuitState: Sendable, Hashable {
    /// Requests flow.
    case closed
    /// Requests fail fast until the cooldown ends.
    case open(cause: BreakerCause, trips: Int)
    /// Exactly one probe may run.
    case halfOpen(cause: BreakerCause, trips: Int)
}
