import Foundation
import ZTronAssetModel
import ZTronAssetStorage

/// A reason for a job to exist (sync.md §6.1): an actor-allocated counter, so allocation is deterministic.
package struct InterestToken: Hashable, Comparable, Sendable {
    /// The counter value.
    package let rawValue: UInt64

    /// Creates a token.
    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Orders by allocation.
    package static func < (lhs: InterestToken, rhs: InterestToken) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The engine lifecycle (sync.md §5.3): every entry point checks it synchronously first.
package enum EngineLifecycle: Sendable, Hashable {
    /// Constructed; `start()` not called.
    case created
    /// `start()` running (an engine-owned task, ADR-039).
    case starting
    /// Serving.
    case running
    /// `store.open()` failed: lookups return nil, async APIs throw `storageUnavailable`.
    case degraded(StorageUnavailableReason)
    /// `shutdown()` began: every entry point fails with `.shutDown`, nothing new is spawned.
    case shuttingDown
    /// Terminal.
    case shutDown
}

/// What the engine owns, for tests and P-14 (R-SYN-14). `package`, so the benchmarks target reads it too.
package struct EngineIntrospection: Sendable, Hashable {
    /// The lifecycle.
    package var lifecycle: EngineLifecycle
    /// Jobs by state.
    package var jobsByState: [JobStateKind: Int]
    /// Queued jobs per lane.
    package var queued: [AssetPriority: Int]
    /// Transfers counted as running.
    package var running: Int
    /// Transfers being paused for preemption.
    package var preempting: Int
    /// Registered `resolve` waiters.
    package var waiters: Int
    /// Interests across jobs.
    package var interests: Int
    /// Prefetch handles, `ensureAvailable` groups and runs.
    package var groups: Int
    /// 0 or 1: the single alarm.
    package var armedTimers: Int
    /// Deadline-heap entries (compacted eagerly, sync-1 S1-10).
    package var scheduledDeadlines: Int
    /// Engine-owned tasks: drivers, alarm, watcher, run, entry-point tasks (ADR-039).
    package var ownedTasks: Int
    /// Whether the conditions watcher runs.
    package var watcherActive: Bool
    /// Event subscribers.
    package var subscribers: Int
    /// Events buffered across subscriber queues.
    package var bufferedEvents: Int
    /// Whether the memory-pressure observer runs (R-CLN-11): only while a `PurgeableCache` is registered. It is an
    /// owned task, so `isIdleSilent` is false while it runs; R-SYN-14 and P-14 are measured with no cache registered.
    package var memoryPressureObserverActive: Bool

    /// Creates a snapshot of the counters.
    package init(
        lifecycle: EngineLifecycle,
        jobsByState: [JobStateKind: Int] = [:],
        queued: [AssetPriority: Int] = [:],
        running: Int = 0,
        preempting: Int = 0,
        waiters: Int = 0,
        interests: Int = 0,
        groups: Int = 0,
        armedTimers: Int = 0,
        scheduledDeadlines: Int = 0,
        ownedTasks: Int = 0,
        watcherActive: Bool = false,
        subscribers: Int = 0,
        bufferedEvents: Int = 0,
        memoryPressureObserverActive: Bool = false
    ) {
        self.lifecycle = lifecycle
        self.jobsByState = jobsByState
        self.queued = queued
        self.running = running
        self.preempting = preempting
        self.waiters = waiters
        self.interests = interests
        self.groups = groups
        self.armedTimers = armedTimers
        self.scheduledDeadlines = scheduledDeadlines
        self.ownedTasks = ownedTasks
        self.watcherActive = watcherActive
        self.subscribers = subscribers
        self.bufferedEvents = bufferedEvents
        self.memoryPressureObserverActive = memoryPressureObserverActive
    }

    /// R-SYN-14: nothing to do and nothing owned.
    package var isIdleSilent: Bool {
        self.armedTimers == 0 && self.ownedTasks == 0 && !self.watcherActive && self.scheduledDeadlines == 0
    }
}

/// What `diagnosticReport()` needs from the engine (R-OBS-3): its counters, the ring of recent errors and the facts
/// it learned in `start()`. Values only; no request, header, URL or key (R-SEC-1).
package struct EngineDiagnostics: Sendable, Hashable {
    /// The ring's capacity: the last errors kept for support.
    package static let recentErrorCapacity = 32

    /// The engine's counters.
    package var introspection: EngineIntrospection
    /// The last errors, oldest first, at most `recentErrorCapacity`.
    package var recentErrors: [DiagnosticError]
    /// The app version read in `start()`; `nil` before it.
    package var appVersion: String?
    /// The store's launch epoch; `nil` before `start()` opened it.
    package var launchEpoch: UInt64?
    /// The committed index generation, read from the store.
    package var indexGeneration: UInt64
    /// The sync stamp, read from the store.
    package var stamp: SyncStamp?
    /// The retention scope in force (ADR-027).
    package var retentionScope: AssetScope

    /// Creates a diagnostics value.
    package init(
        introspection: EngineIntrospection,
        recentErrors: [DiagnosticError],
        appVersion: String?,
        launchEpoch: UInt64?,
        indexGeneration: UInt64,
        stamp: SyncStamp?,
        retentionScope: AssetScope
    ) {
        self.introspection = introspection
        self.recentErrors = recentErrors
        self.appVersion = appVersion
        self.launchEpoch = launchEpoch
        self.indexGeneration = indexGeneration
        self.stamp = stamp
        self.retentionScope = retentionScope
    }
}

/// Everything the engine needs besides its environment and store.
package struct EngineConfiguration: Sendable, Hashable {
    /// Scheduling knobs (clamped).
    package var tuning: SyncTuning
    /// Storage policy (budget, grace, integrity, ADR-035).
    package var storage: StoragePolicy
    /// Network policy (ADR-036).
    package var network: NetworkPolicy
    /// Power policy (ADR-036).
    package var power: PowerPolicy
    /// Refresh policy (R-SYN-9).
    package var refresh: RefreshPolicy
    /// The remote side (R-APL-5).
    package var remote: RemoteConfiguration
    /// Manifest limits (R-MAN-2).
    package var limits: ManifestLimits
    /// The initial retention scope (R-CAR-5, ADR-027): the scope of every bulk run, pushed to the store after
    /// `open()` for eviction preference and pack-release exclusions; `setRetentionScope(_:)` replaces it.
    package var retentionScope: AssetScope

    /// Creates a configuration.
    package init(
        tuning: SyncTuning,
        storage: StoragePolicy,
        network: NetworkPolicy,
        power: PowerPolicy,
        refresh: RefreshPolicy,
        remote: RemoteConfiguration,
        limits: ManifestLimits,
        retentionScope: AssetScope = .all
    ) {
        self.tuning = tuning
        self.storage = storage
        self.network = network
        self.power = power
        self.refresh = refresh
        self.remote = remote
        self.limits = limits
        self.retentionScope = retentionScope
    }
}

/// Full-jitter exponential backoff with keyed randomness (R-SYN-5, ADR-024).
package enum Backoff {
    /// The delay before attempt `attempt + 1` of the asset `key`, or `nil` when `retryAfter` exceeds
    /// `policy.maxRetryAfter` (defer to the next run). Full jitter: `U[0, min(maxDelay, baseDelay · 2^(attempt−1))]`
    /// drawn from `KeyedRandom` keyed by asset and attempt (never by arrival order, sync-2 S2-16); a `Retry-After`
    /// is a lower bound.
    package static func delay(
        attempt: Int,
        retryAfter: TimeInterval?,
        policy: RetryPolicy,
        seed: UInt64,
        key: UInt64
    ) -> TimeInterval? {
        if let retryAfter, retryAfter > policy.maxRetryAfter {
            return nil
        }
        let exponent = Double(max(attempt, 1) - 1)
        let ceiling = min(policy.maxDelay, policy.baseDelay * pow(2, min(exponent, 62)))
        let unit = KeyedRandom.unitInterval(seed: seed, key: key, counter: UInt64(max(attempt, 1)))
        let jittered = max(0, ceiling) * unit
        return max(jittered, retryAfter ?? 0)
    }
}

/// Lane admission under network and power policy (R-SYN-7, sync.md §11.2), pure.
package enum LaneAdmission {
    /// Whether a lane may start work now.
    package enum Verdict: Sendable, Hashable {
        /// Start.
        case admit
        /// Park with this reason.
        case block(BlockReason)
    }

    /// Evaluates one lane.
    package static func evaluate(
        lane: AssetPriority,
        conditions: DeviceConditions?,
        network: NetworkPolicy,
        power: PowerPolicy,
        pausedForThermal: Bool
    ) -> Verdict {
        // Until the first conditions element arrives, user-initiated work proceeds optimistically and the other lanes
        // wait (sync.md §11.1); an unsatisfied path is attempted only by user-initiated work, which the transport
        // fails fast (§11.2).
        guard let conditions, conditions.network.satisfied else {
            return lane == .userInitiated ? .admit : .block(.offline)
        }
        let expensive = conditions.network.expensive
        let constrained = conditions.network.constrained
        switch lane {
        case .userInitiated:
            if network.userInitiatedOverridesPolicy {
                return .admit
            }
            // Without the override, explicit requests follow the prefetch lane's network rules; power never pauses
            // them (R-SYN-7 "may override per policy").
            if expensive, !network.prefetchOnExpensive {
                return .block(.policy(.expensiveNetwork))
            }
            if constrained, !network.prefetchOnConstrained {
                return .block(.policy(.constrainedNetwork))
            }
            return .admit
        case .prefetch:
            return LaneAdmission.background(
                conditions: conditions,
                onExpensive: network.prefetchOnExpensive,
                onConstrained: network.prefetchOnConstrained,
                inLowPower: power.prefetchInLowPowerMode,
                pausedForThermal: pausedForThermal
            )
        case .bulk:
            return LaneAdmission.background(
                conditions: conditions,
                onExpensive: network.bulkOnExpensive,
                onConstrained: network.bulkOnConstrained,
                inLowPower: power.bulkInLowPowerMode,
                pausedForThermal: pausedForThermal
            )
        }
    }

    /// The bulk and prefetch rules: network policy first, then Low Power Mode, then the thermal pause.
    private static func background(
        conditions: DeviceConditions,
        onExpensive: Bool,
        onConstrained: Bool,
        inLowPower: Bool,
        pausedForThermal: Bool
    ) -> Verdict {
        if conditions.network.expensive, !onExpensive {
            return .block(.policy(.expensiveNetwork))
        }
        if conditions.network.constrained, !onConstrained {
            return .block(.policy(.constrainedNetwork))
        }
        if conditions.power.lowPowerMode, !inLowPower {
            return .block(.policy(.lowPowerMode))
        }
        if pausedForThermal {
            return .block(.policy(.thermal(conditions.power.thermal)))
        }
        return .admit
    }
}

/// The per-origin circuit breaker (R-SYN-5, ARCHITECTURE §7.7): a pure value owned by the engine; time and the
/// seed are passed in. Probe resolution is total: any probe exit that is neither success nor a same-cause failure
/// returns to `halfOpen(probe: nil)`, and a watchdog deadline re-arms a silent probe (sync-1 S1-03, sync-2 S2-01).
package struct CircuitBreaker: Sendable, Hashable {
    /// The breaker state.
    package enum State: Sendable, Hashable {
        /// Requests flow.
        case closed
        /// Requests fail fast until `until`.
        case open(cause: BreakerCause, until: MonotonicInstant, trips: Int)
        /// One probe may run; `probe` is the transfer currently probing.
        case halfOpen(cause: BreakerCause, trips: Int, probe: TransferID?, watchdog: MonotonicInstant?)
    }

    /// What a transfer outcome contributes.
    package enum Outcome: Sendable, Hashable {
        /// An object transfer succeeded (a cached 304 never counts, sync-2 S2-21).
        case objectSuccess(TransferID)
        /// A failure with a breaker-relevant cause.
        case failure(TransferID, BreakerCause, distinctAsset: AssetID?)
        /// A failure the breaker does not count (offline, integrity, 404…).
        case neutral(TransferID)
        /// The transfer ended without a terminal outcome (cancelled, paused, superseded, shut down).
        case abandoned(TransferID)
    }

    /// The admission verdict.
    package enum Admission: Sendable, Hashable {
        /// Proceed.
        case allow
        /// Proceed as the single half-open probe.
        case probe
        /// Fail fast or park until `until`.
        case reject(BreakerCause, until: MonotonicInstant?)
    }

    /// The current state.
    package private(set) var state: State
    /// Thresholds.
    package let policy: CircuitBreakerPolicy
    /// Distinct assets with an ambiguous 403 since the last object success, in arrival order (auth suspicion).
    private(set) var authSuspects: [AssetID] = []
    /// The 5xx sliding window: `true` for a 5xx outcome, `false` for an object success, oldest first.
    private(set) var serverWindow: [Bool] = []
    /// Trips carried by a closed breaker until `objectSuccessesToReset` successes reset them (sync-2 S2-21).
    private(set) var carriedTrips = 0
    /// Object successes since the breaker last closed.
    private(set) var successesSinceClose = 0

    /// A closed breaker.
    package init(policy: CircuitBreakerPolicy) {
        self.state = .closed
        self.policy = policy
    }

    /// Records an outcome at `now`.
    ///
    /// Closed: ambiguous object 403s count distinct assets (an object success clears them) and a manifest 403
    /// (`distinctAsset == nil`) opens at once; 5xx outcomes and object successes fill the sliding window. Half-open:
    /// only the probe's outcome counts, and its resolution is total (ADR-031): success closes, a same-cause failure
    /// re-opens with `trips + 1`, any other exit re-arms `halfOpen(probe: nil)`. Open: outcomes of transfers that
    /// started before the trip are ignored.
    package mutating func record(_ outcome: Outcome, at now: MonotonicInstant, seed: UInt64) {
        switch self.state {
        case .closed:
            self.recordClosed(outcome, at: now, seed: seed)
        case .open:
            return
        case .halfOpen(let cause, let trips, let probe, _):
            guard let probe, outcome.transfer == probe else {
                return
            }
            switch outcome {
            case .objectSuccess:
                self.close(carrying: trips)
                self.successesSinceClose = 1
                self.resetCarriedTripsIfDue()
            case .failure(_, let failureCause, _) where failureCause == cause:
                self.open(cause, trips: trips + 1, at: now, seed: seed)
            case .failure, .neutral, .abandoned:
                self.state = .halfOpen(cause: cause, trips: trips, probe: nil, watchdog: nil)
            }
        }
    }

    /// Whether a transfer may start at `now`.
    ///
    /// Open until the cooldown ends, then exactly one probe: the first transfer admitted becomes it (with a
    /// `probeWatchdog` deadline); a probe silent past its watchdog is abandoned and the next transfer probes
    /// (sync-2 S2-01). The probe itself is admitted again (a re-dispatch after a pause).
    package mutating func admit(_ transfer: TransferID, at now: MonotonicInstant) -> Admission {
        switch self.state {
        case .closed:
            return .allow
        case .open(let cause, let until, let trips):
            guard now >= until else {
                return .reject(cause, until: until)
            }
            self.state = .halfOpen(cause: cause, trips: trips, probe: transfer, watchdog: now.adding(seconds: self.policy.probeWatchdog))
            return .probe
        case .halfOpen(let cause, let trips, let probe, let watchdog):
            if let probe, probe != transfer, let watchdog, now < watchdog {
                return .reject(cause, until: watchdog)
            }
            if probe == transfer, let watchdog, now < watchdog {
                return .probe
            }
            self.state = .halfOpen(cause: cause, trips: trips, probe: transfer, watchdog: now.adding(seconds: self.policy.probeWatchdog))
            return .probe
        }
    }

    /// The next instant the breaker changes by time alone (cooldown end, probe watchdog), for the engine's alarm.
    package func nextDeadline() -> MonotonicInstant? {
        switch self.state {
        case .closed:
            return nil
        case .open(_, let until, _):
            return until
        case .halfOpen(_, _, let probe, let watchdog):
            return probe == nil ? nil : watchdog
        }
    }

    /// The public face of the state (events, diagnostics).
    var publicState: CircuitState {
        switch self.state {
        case .closed:
            return .closed
        case .open(let cause, _, let trips):
            return .open(cause: cause, trips: trips)
        case .halfOpen(let cause, let trips, _, _):
            return .halfOpen(cause: cause, trips: trips)
        }
    }

    private mutating func recordClosed(_ outcome: Outcome, at now: MonotonicInstant, seed: UInt64) {
        switch outcome {
        case .objectSuccess:
            self.authSuspects.removeAll()
            self.appendWindow(false)
            self.successesSinceClose += 1
            self.resetCarriedTripsIfDue()
        case .failure(_, .authentication, let asset):
            guard let asset else {
                self.open(.authentication, trips: self.carriedTrips + 1, at: now, seed: seed)
                return
            }
            if !self.authSuspects.contains(asset) {
                self.authSuspects.append(asset)
            }
            if self.authSuspects.count >= max(1, self.policy.authDistinctAssets) {
                self.open(.authentication, trips: self.carriedTrips + 1, at: now, seed: seed)
            }
        case .failure(_, .serverErrors, _):
            self.appendWindow(true)
            let errors = self.serverWindow.filter { $0 }.count
            let samples = self.serverWindow.count
            if samples >= max(1, self.policy.serverMinimumSamples), Double(errors) >= self.policy.serverErrorRatio * Double(samples) {
                self.open(.serverErrors, trips: self.carriedTrips + 1, at: now, seed: seed)
            }
        case .neutral, .abandoned:
            return
        }
    }

    private mutating func appendWindow(_ isServerError: Bool) {
        self.serverWindow.append(isServerError)
        let limit = max(1, self.policy.serverWindow)
        if self.serverWindow.count > limit {
            self.serverWindow.removeFirst(self.serverWindow.count - limit)
        }
    }

    /// Opens for `cause`: cooldown `base · 2^(trips−1)` capped at the maximum; the auth cooldown is jittered to
    /// `[0.5c, c]` with randomness keyed by cause and trip (ADR-024), the 5xx cooldown is exact.
    private mutating func open(_ cause: BreakerCause, trips: Int, at now: MonotonicInstant, seed: UInt64) {
        let base: TimeInterval
        let ceiling: TimeInterval
        switch cause {
        case .authentication:
            base = self.policy.authCooldownBase
            ceiling = self.policy.authCooldownMax
        case .serverErrors:
            base = self.policy.serverCooldownBase
            ceiling = self.policy.serverCooldownMax
        }
        let exponent = Double(min(max(trips, 1) - 1, 62))
        var cooldown = max(0, min(ceiling, base * pow(2, exponent)))
        if cause == .authentication {
            let unit = KeyedRandom.unitInterval(seed: seed, key: StableHash.fnv1a64("breaker.authentication"), counter: UInt64(max(trips, 1)))
            cooldown *= 0.5 + 0.5 * unit
        }
        self.state = .open(cause: cause, until: now.adding(seconds: cooldown), trips: trips)
        self.authSuspects.removeAll()
        self.serverWindow.removeAll()
        self.carriedTrips = trips
        self.successesSinceClose = 0
    }

    private mutating func close(carrying trips: Int) {
        self.state = .closed
        self.carriedTrips = trips
        self.authSuspects.removeAll()
        self.serverWindow.removeAll()
    }

    private mutating func resetCarriedTripsIfDue() {
        if self.successesSinceClose >= max(1, self.policy.objectSuccessesToReset) {
            self.carriedTrips = 0
        }
    }
}

extension CircuitBreaker.Outcome {
    /// The transfer the outcome is about.
    var transfer: TransferID {
        switch self {
        case .objectSuccess(let transfer), .failure(let transfer, _, _), .neutral(let transfer), .abandoned(let transfer):
            return transfer
        }
    }
}

/// What launch reconciliation does with each live task and staged file (H-6, ADR-028, transport.md §10.5 as
/// amended by transport-2 T2-02/T2-03).
package enum ReconcileAction: Sendable, Hashable {
    /// Join the live OS task for this staging name.
    case attach(StagingFileName)
    /// Cancel the live task.
    case cancel(StagingFileName)
    /// Publish this complete staged file through the hash path.
    case adoptStaged(StagingFileName)
    /// Continue this partial with its sidecar.
    case resume(StagingFileName)
    /// Delete this staging file.
    case discard(StagingFileName)
}

/// The pure launch reconciler (WP-F). `wanted` is the set of applied-manifest entries that are not present (never a
/// run's network plan, so an offline launch cancels nothing, transport-2 T2-03). Deterministic: sorted output.
package enum TransferReconciler {
    /// Plans the actions.
    package static func plan(
        live: [ReattachedTransfer],
        staged: StagingInventory,
        wanted: Set<TransferID>
    ) -> [ReconcileAction] {
        var actions: [StagingFileName: ReconcileAction] = [:]
        // Live tasks: per wanted transfer the newest running one is joined, every other running one cancelled; a
        // completed one is adopted (the newest per transfer) when wanted and its file is staged, else discarded.
        var joined = Set<TransferID>()
        for transfer in live.sorted(by: { $0.name > $1.name }) where transfer.isRunning {
            let id = transfer.name.transfer
            if wanted.contains(id), !joined.contains(id) {
                joined.insert(id)
                actions[transfer.name] = .attach(transfer.name)
            } else {
                actions[transfer.name] = .cancel(transfer.name)
            }
        }
        var adopted = Set<TransferID>()
        for transfer in live.sorted(by: { $0.name > $1.name }) where !transfer.isRunning {
            let id = transfer.name.transfer
            if wanted.contains(id), !joined.contains(id), !adopted.contains(id), staged.items[transfer.name] != nil {
                adopted.insert(id)
                actions[transfer.name] = .adoptStaged(transfer.name)
            } else if staged.items[transfer.name] != nil {
                actions[transfer.name] = .discard(transfer.name)
            }
        }
        // Staging leftovers: the newest partial with a sidecar of a wanted transfer nobody joined or adopted is
        // resumed (it keeps its sidecar); everything else of ours is garbage: other partials (a partial without a
        // sidecar cannot be continued, and its completeness is unknown), orphan sidecars, a claim (`.verifying`) or a
        // temporary that a dead process left.
        var resumed = Set<TransferID>()
        for name in staged.items.keys.sorted(by: >) where actions[name] == nil {
            switch name.kind {
            case .partial:
                let id = name.transfer
                let resumable = wanted.contains(id) && !joined.contains(id) && !adopted.contains(id) && !resumed.contains(id)
                    && staged.items[name.with(kind: .sidecar)] != nil
                if resumable {
                    resumed.insert(id)
                    actions[name] = .resume(name)
                } else {
                    actions[name] = .discard(name)
                }
            case .sidecar, .verifying, .partialTemporary, .sidecarTemporary:
                continue
            }
        }
        for name in staged.items.keys where actions[name] == nil {
            if name.kind == .sidecar, case .resume? = actions[name.with(kind: .partial)] {
                continue
            }
            actions[name] = .discard(name)
        }
        return actions.keys.sorted().compactMap { actions[$0] }
    }
}
