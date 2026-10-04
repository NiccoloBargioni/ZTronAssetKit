import Foundation

/// Retry behaviour of one lane class (R-SYN-5). Delays use full jitter keyed by asset and attempt (ADR-024).
public struct RetryPolicy: Sendable, Hashable, Codable {
    /// First backoff ceiling in seconds.
    public var baseDelay: TimeInterval
    /// Largest backoff ceiling in seconds.
    public var maxDelay: TimeInterval
    /// Attempts per asset within one run before `failed(.nextRun)`.
    public var maxAttemptsPerRun: Int
    /// A `Retry-After` above this many seconds defers the asset to the next run.
    public var maxRetryAfter: TimeInterval
    /// How long a user-initiated request waits for an origin throttle before failing fast.
    public var interactiveMaxWait: TimeInterval

    /// Creates a policy.
    public init(
        baseDelay: TimeInterval,
        maxDelay: TimeInterval,
        maxAttemptsPerRun: Int,
        maxRetryAfter: TimeInterval,
        interactiveMaxWait: TimeInterval
    ) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxAttemptsPerRun = maxAttemptsPerRun
        self.maxRetryAfter = maxRetryAfter
        self.interactiveMaxWait = interactiveMaxWait
    }

    /// Bulk and prefetch: 1 s doubling to 300 s, 4 attempts per run, `Retry-After` honoured up to 1 h.
    public static let background = RetryPolicy(
        baseDelay: 1,
        maxDelay: 300,
        maxAttemptsPerRun: 4,
        maxRetryAfter: 3_600,
        interactiveMaxWait: 0
    )

    /// User-initiated: 0.25 s doubling to 2 s, 2 attempts, then the waiter gets the error; throttles wait ≤ 2 s.
    public static let interactive = RetryPolicy(
        baseDelay: 0.25,
        maxDelay: 2,
        maxAttemptsPerRun: 2,
        maxRetryAfter: 3_600,
        interactiveMaxWait: 2
    )
}

/// Circuit-breaker thresholds per origin (R-SYN-5, ARCHITECTURE §7.7).
public struct CircuitBreakerPolicy: Sendable, Hashable, Codable {
    /// Distinct assets with a key-rejected-likely 403 (and no success in between) that open the auth breaker.
    public var authDistinctAssets: Int
    /// First auth cooldown in seconds (doubles per trip).
    public var authCooldownBase: TimeInterval
    /// Largest auth cooldown in seconds.
    public var authCooldownMax: TimeInterval
    /// Sliding window of transfer outcomes for the 5xx breaker.
    public var serverWindow: Int
    /// Minimum samples in the window before the 5xx breaker may open.
    public var serverMinimumSamples: Int
    /// 5xx ratio in the window that opens the breaker.
    public var serverErrorRatio: Double
    /// First 5xx cooldown in seconds (doubles per trip).
    public var serverCooldownBase: TimeInterval
    /// Largest 5xx cooldown in seconds.
    public var serverCooldownMax: TimeInterval
    /// Successful *object* transfers needed to reset the trip count after a 5xx trip (a cached manifest 304
    /// never resets it, sync-2 S2-21).
    public var objectSuccessesToReset: Int
    /// A half-open probe that has produced no terminal outcome after this many seconds is abandoned and the
    /// breaker re-arms its probe (sync-2 S2-01 watchdog).
    public var probeWatchdog: TimeInterval

    /// Creates a policy.
    public init(
        authDistinctAssets: Int = 3,
        authCooldownBase: TimeInterval = 300,
        authCooldownMax: TimeInterval = 3_600,
        serverWindow: Int = 20,
        serverMinimumSamples: Int = 5,
        serverErrorRatio: Double = 0.5,
        serverCooldownBase: TimeInterval = 30,
        serverCooldownMax: TimeInterval = 600,
        objectSuccessesToReset: Int = 2,
        probeWatchdog: TimeInterval = 60
    ) {
        self.authDistinctAssets = authDistinctAssets
        self.authCooldownBase = authCooldownBase
        self.authCooldownMax = authCooldownMax
        self.serverWindow = serverWindow
        self.serverMinimumSamples = serverMinimumSamples
        self.serverErrorRatio = serverErrorRatio
        self.serverCooldownBase = serverCooldownBase
        self.serverCooldownMax = serverCooldownMax
        self.objectSuccessesToReset = objectSuccessesToReset
        self.probeWatchdog = probeWatchdog
    }
}

/// Engine scheduling knobs (R-SYN-3, R-SYN-5, R-SYN-12). Out-of-range values are clamped by `clamped()`, and the
/// clamps are reported in diagnostics.
public struct SyncTuning: Sendable, Hashable, Codable {
    /// Maximum transfers counted as running (R-SYN-3: default 4, valid 1…16).
    public var maxConcurrentTransfers: Int
    /// Slots kept free for user-initiated work; effectively `min(this, max − 1)` (0 when `max == 1`).
    public var reservedInteractiveSlots: Int
    /// Jobs in downloading ∪ verifying ∪ committing for non-user lanes ≤ `pipelineDepth × max`
    /// (user work is never gated by it, sync-2 S2-10).
    public var pipelineDepth: Int
    /// A bulk job queued longer than this outranks prefetch for the next non-reserved slot (seconds).
    public var bulkAging: TimeInterval
    /// Whether a waiting user-initiated job may pause a lower-lane transfer when no slot is free.
    public var preemptLowerLanes: Bool
    /// Retry policy for bulk and prefetch.
    public var retry: RetryPolicy
    /// Retry policy while a job's lane is user-initiated.
    public var interactiveRetry: RetryPolicy
    /// Circuit-breaker thresholds.
    public var breaker: CircuitBreakerPolicy
    /// Minimum seconds between progress events per key: 0.1 s ⇒ ≤ 10 Hz (R-SYN-12).
    public var progressInterval: TimeInterval
    /// Seconds an unknown identifier stays negatively cached after a fresh manifest lacked it.
    public var unknownIDRefetchInterval: TimeInterval
    /// Capacity of the unknown-identifier negative cache (LRU, sync-2 S2-22).
    public var unknownIDCacheCapacity: Int
    /// Planned fetches materialised as jobs beyond the pipeline (sync-1 S1-15: jobs never scale with catalog).
    public var runLookahead: Int
    /// Seconds the network must stay satisfied before a pending run starts (debounce, sync-2 S2-25).
    public var pendingRunDebounce: TimeInterval
    /// Seconds a manifest fetch may take before the engine falls back to the applied manifest (transport-2 T2-14).
    public var manifestFetchDeadline: TimeInterval
    /// Minimum seconds between snapshot installs on the main actor for bulk work (S2-12: ≤ 10 Hz); user-initiated
    /// commits install immediately.
    public var snapshotInstallInterval: TimeInterval

    /// The defaults of sync design §7.1 as amended by the reviews (ARCHITECTURE §7).
    public init(
        maxConcurrentTransfers: Int = 4,
        reservedInteractiveSlots: Int = 1,
        pipelineDepth: Int = 2,
        bulkAging: TimeInterval = 30,
        preemptLowerLanes: Bool = true,
        retry: RetryPolicy = .background,
        interactiveRetry: RetryPolicy = .interactive,
        breaker: CircuitBreakerPolicy = CircuitBreakerPolicy(),
        progressInterval: TimeInterval = 0.1,
        unknownIDRefetchInterval: TimeInterval = 60,
        unknownIDCacheCapacity: Int = 256,
        runLookahead: Int = 16,
        pendingRunDebounce: TimeInterval = 5,
        manifestFetchDeadline: TimeInterval = 30,
        snapshotInstallInterval: TimeInterval = 0.1
    ) {
        self.maxConcurrentTransfers = maxConcurrentTransfers
        self.reservedInteractiveSlots = reservedInteractiveSlots
        self.pipelineDepth = pipelineDepth
        self.bulkAging = bulkAging
        self.preemptLowerLanes = preemptLowerLanes
        self.retry = retry
        self.interactiveRetry = interactiveRetry
        self.breaker = breaker
        self.progressInterval = progressInterval
        self.unknownIDRefetchInterval = unknownIDRefetchInterval
        self.unknownIDCacheCapacity = unknownIDCacheCapacity
        self.runLookahead = runLookahead
        self.pendingRunDebounce = pendingRunDebounce
        self.manifestFetchDeadline = manifestFetchDeadline
        self.snapshotInstallInterval = snapshotInstallInterval
    }

    /// The valid range of `maxConcurrentTransfers` (R-SYN-3).
    public static let concurrencyRange: ClosedRange<Int> = 1...16

    /// A copy with every knob inside its valid range, plus the names of the fields that were clamped.
    public func clamped() -> (tuning: SyncTuning, clampedFields: [String]) {
        var copy = self
        var fields: [String] = []
        let concurrency = min(max(self.maxConcurrentTransfers, SyncTuning.concurrencyRange.lowerBound), SyncTuning.concurrencyRange.upperBound)
        if concurrency != self.maxConcurrentTransfers {
            copy.maxConcurrentTransfers = concurrency
            fields.append("maxConcurrentTransfers")
        }
        let reserved = min(max(self.reservedInteractiveSlots, 0), concurrency - 1)
        if reserved != self.reservedInteractiveSlots {
            copy.reservedInteractiveSlots = reserved
            fields.append("reservedInteractiveSlots")
        }
        if self.pipelineDepth < 1 {
            copy.pipelineDepth = 1
            fields.append("pipelineDepth")
        }
        if !(self.progressInterval >= 0) {
            copy.progressInterval = 0.1
            fields.append("progressInterval")
        }
        if self.unknownIDCacheCapacity < 1 {
            copy.unknownIDCacheCapacity = 1
            fields.append("unknownIDCacheCapacity")
        }
        if self.runLookahead < 0 {
            copy.runLookahead = 0
            fields.append("runLookahead")
        }
        return (copy, fields)
    }
}
