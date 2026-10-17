import Foundation
import ZTronAssetModel
import ZTronAssetStorage

extension SyncEngine {
    // MARK: Single-flight manifest fetch (RE-S04, RE-S05, RE-S19)

    /// Joins (or starts) the single-flight manifest fetch; the caller's cancellation withdraws only its token.
    func fetchManifest(_ token: InterestToken, deadline: Bool) async -> ManifestOutcome {
        self.beginManifestFetch()
        if deadline, let sequence = self.state.manifestFetch?.sequence {
            let at = self.environment.time.monotonicNow().adding(seconds: self.tuning.manifestFetchDeadline)
            self.state.heap.schedule(.manifest(sequence), at: at)
            self.rearm()
        }
        // REENTRANCY: RE-S25 — nothing: the body registers synchronously; the outcome arrives by value.
        return await withTaskCancellationHandler {
            // REENTRANCY: RE-S25 — as above.
            await withCheckedContinuation { (continuation: CheckedContinuation<ManifestOutcome, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else if self.isShuttingDown {
                    continuation.resume(returning: .shutDown)
                } else if self.state.manifestFetch == nil {
                    continuation.resume(returning: .cancelled)
                } else {
                    self.state.manifestFetch?.waiters[token] = continuation
                }
            }
        } onCancel: {
            Task {
                // REENTRANCY: RE-S25 — nothing: the hop only withdraws this token.
                await self.withdrawManifestWaiter(token)
            }
        }
    }

    private func withdrawManifestWaiter(_ token: InterestToken) {
        if let continuation = self.state.manifestFetch?.waiters.removeValue(forKey: token) {
            continuation.resume(returning: .cancelled)
            return
        }
        // Test seam: a held outcome's waiter is withdrawn the same way, so its wait still ends on cancellation.
        for index in self.state.heldManifestDeliveries.indices {
            if let continuation = self.state.heldManifestDeliveries[index].waiters.removeValue(forKey: token) {
                continuation.resume(returning: .cancelled)
                return
            }
        }
    }

    /// Test seam: the outcomes of the manifest fetches that end from now on wait for `releaseManifestOutcomeDelivery()`
    /// before they reach the runs and `ensureAvailable` calls waiting for them (close-out cycle 18).
    func holdManifestOutcomeDelivery() {
        self.state.manifestDeliveriesHeld = true
    }

    /// Test seam: delivers every held outcome to its waiters in this turn and disarms the hold; shutdown calls it too,
    /// and then the waiters are told the engine is shutting down, as shutdown tells a fetch's waiters.
    func releaseManifestOutcomeDelivery() {
        self.state.manifestDeliveriesHeld = false
        let held = self.state.heldManifestDeliveries
        self.state.heldManifestDeliveries.removeAll()
        for delivery in held {
            let outcome = self.isShuttingDown ? .shutDown : delivery.outcome
            for token in delivery.waiters.keys.sorted() {
                delivery.waiters[token]?.resume(returning: outcome)
            }
        }
    }

    /// Test seam: whether a manifest fetch's outcome waits for `releaseManifestOutcomeDelivery()`.
    var manifestOutcomeHeld: Bool {
        !self.state.heldManifestDeliveries.isEmpty
    }

    /// Starts the fetch task unless one runs.
    func beginManifestFetch() {
        guard self.state.manifestFetch == nil, self.isRunning || self.state.lifecycle == .starting else {
            return
        }
        self.state.lastFetch += 1
        let sequence = self.state.lastFetch
        self.state.manifestFetch = ManifestFetch(sequence: sequence)
        let task = self.spawn(.manifest) { engine in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
            await engine.runManifestFetch(sequence)
        }
        self.state.manifestFetch?.task = task
        self.ensureWatcher()
        self.notifyObservers()
    }

    /// A best-effort update check (Apple tier, `sourceVersionSkew`): a fetch whose result only refreshes the newest
    /// manifest seen.
    func requestManifestCheck() {
        self.beginManifestFetch()
    }

    /// The fetch task: breaker admission, the conditional request, decoding on the bulk executor, then the waiters
    /// and the unknown-identifier waiters (point admission).
    private func runManifestFetch(_ sequence: UInt64) async {
        // REENTRANCY: RE-S04 — the fetch sequence: the outcome is delivered only while this fetch is still the current one.
        let outcome = await self.performManifestFetch(sequence)
        guard self.state.manifestFetch?.sequence == sequence else {
            return
        }
        let waiting = self.state.manifestFetch?.waiters ?? [:]
        self.state.manifestFetch = nil
        self.state.heap.remove(.manifest(sequence))
        if self.state.manifestDeliveriesHeld {
            // Test seam: the outcome waits for `releaseManifestOutcomeDelivery()` (or shutdown); the waiters re-validate
            // after it as they do after an outcome delivered here.
            self.state.heldManifestDeliveries.append(HeldManifestDelivery(outcome: outcome, waiters: waiting))
            self.notifyObservers()
        } else {
            for token in waiting.keys.sorted() {
                waiting[token]?.resume(returning: outcome)
            }
        }
        self.rearm()
        // REENTRANCY: RE-S19 — every unknown-id waiter is re-checked as registered after each admission.
        await self.answerUnknownWaiters(outcome)
        self.reconcileIdle()
    }

    private func performManifestFetch(_ sequence: UInt64) async -> ManifestOutcome {
        guard let remote = self.state.remote else {
            return .failed(.offline(.noConnection))
        }
        let isApple = remote.capabilities.tier == .appleHosted
        if isApple, self.state.conditions == nil {
            // REENTRANCY: f-7 (proposed) — the lifecycle: the update-check gate needs the engine's own conditions
            // (E-17); shutdown resumes this wait.
            await self.waitForConditions()
            guard self.isRunning || self.state.lifecycle == .starting else {
                return .shutDown
            }
        }
        let now = self.environment.time.monotonicNow()
        if let until = self.originGate(at: now).throttledUntil {
            return .throttled(until)
        }
        var breaker = self.state.breakers[remote.originID] ?? CircuitBreaker(policy: self.tuning.breaker)
        let before = breaker.publicState
        switch breaker.admit(.manifest, at: now) {
        case .allow:
            self.state.breakers[remote.originID] = breaker
        case .probe:
            self.state.breakers[remote.originID] = breaker
            self.breakerChanged(remote.originID, from: before)
            // A probe admitted from `halfOpen(probe: nil)` leaves the public state unchanged, so `breakerChanged` did not
            // schedule its watchdog: scheduled here, as `start(_:probe:)` does for a transfer probe (L4-C19-10).
            self.scheduleBreakerDeadline()
        case .reject(let cause, _):
            self.scheduleBreakerDeadline()
            return .circuitOpen(cause)
        }
        let access = self.access(for: .bulk)
        let updateCheck = !isApple || self.appleAccessBlock(access) == nil
        let request = ManifestRequest(
            ifNoneMatch: self.state.appliedETag,
            maxBytes: self.configuration.limits.maxPayloadBytes,
            access: access,
            allowsUpdateCheck: updateCheck,
            attempt: self.nextAttempt()
        )
        self.state.metrics.manifestRequests += 1
        let result: Result<ManifestFetchResult, TransferError>
        do {
            // REENTRANCY: RE-S04 — the lifecycle; the result is used only if its sequence is newer than the last one
            // applied (`newest`).
            result = .success(try await remote.fetchManifest(request))
        } catch {
            result = .failure(error)
        }
        guard self.isRunning || self.state.lifecycle == .starting else {
            return .shutDown
        }
        switch result {
        case .success(.notModified):
            self.state.metrics.manifestNotModified += 1
            self.recordBreaker(.neutral(.manifest))
            return .notModified(sequence: sequence)
        case .success(.fetched(let payload)):
            self.recordBreaker(.objectSuccess(.manifest))
            let options = ManifestDecodingOptions(limits: self.configuration.limits)
            let bytes = payload.bytes
            // REENTRANCY: RE-S05 — the lifecycle; decoding runs on the bulk executor (P-3, C2).
            let decoded: Result<ValidatedManifest, ManifestError> = await self.environment.bulkExecutor.run {
                do throws(ManifestError) {
                    return .success(try ManifestDecoder.decode(bytes, options: options))
                } catch {
                    return .failure(error)
                }
            }
            guard self.isRunning || self.state.lifecycle == .starting else {
                return .shutDown
            }
            switch decoded {
            case .success(let manifest):
                if sequence > (self.state.newest?.sequence ?? 0) {
                    self.state.newest = (manifest, sequence)
                }
                // Identifiers a fresh manifest lists are no longer unknown (sync-1 S1-13): a cached `.notFound` would
                // answer a waiter wrongly until the manifest is applied.
                for id in self.state.negativeCache.expiry.keys.sorted() where manifest.entry(for: id) != nil {
                    self.state.negativeCache.remove(id)
                }
                return .fetched(manifest, etag: payload.etag, sequence: sequence)
            case .failure(let error):
                self.record(nil, .rejected, "manifest rejected: \(error)")
                return .invalid(error)
            }
        case .failure(let error):
            self.recordBreaker(SyncEngine.manifestBreakerOutcome(error))
            if let failureClass = error.failureClass {
                self.state.metrics.failures[failureClass] += 1
                self.record(nil, failureClass, "manifest: \(error)")
            }
            if case .transient(.throttled, let hint) = error {
                let wall = self.environment.time.now()
                let seconds = hint?.seconds(from: wall)
                if let delay = Backoff.delay(attempt: 1, retryAfter: seconds, policy: self.tuning.retry, seed: self.environment.random.seed, key: StableHash.fnv1a64(remote.originID)) {
                    let until = self.environment.time.monotonicNow().adding(seconds: max(delay, seconds ?? 0))
                    // A transfer's 429 may have throttled the origin for longer while this fetch was in flight: the
                    // throttle, its deadline (which alone re-admits the jobs it parked) and the run's block all keep the
                    // later end, as the transfer path does (close-out cycle 15, F-35).
                    let previous = self.state.throttles[remote.originID]
                    let end = max(previous ?? .zero, until)
                    self.state.throttles[remote.originID] = end
                    self.state.heap.schedule(.throttle(remote.originID), at: end)
                    // A user-initiated request a shorter throttle parked fails fast against the new end (F-36).
                    self.throttleExtended(from: previous)
                    self.rearm()
                    return .throttled(end)
                }
            }
            return .failed(error)
        }
    }

    /// The breaker input of a manifest failure: a 403 whose hint is key-rejected opens the auth breaker at once (an
    /// engine inference, ARCHITECTURE §7.6); 5xx feeds the window.
    static func manifestBreakerOutcome(_ error: TransferError) -> CircuitBreaker.Outcome {
        switch error {
        case .authentication(.forbiddenAmbiguous(let evidence)) where evidence.hint == .keyRejectedLikely:
            return .failure(.manifest, .authentication, distinctAsset: nil)
        case .transient(.serverError, _):
            return .failure(.manifest, .serverErrors, distinctAsset: nil)
        case .cancelled:
            return .abandoned(.manifest)
        default:
            return .neutral(.manifest)
        }
    }

    /// Suspends until the first conditions element arrives (or shutdown).
    func waitForConditions() async {
        guard self.state.conditions == nil else {
            return
        }
        self.ensureWatcher(force: true)
        let token = self.nextToken()
        // REENTRANCY: f-7 (proposed) — nothing: resumed by the first conditions element or by shutdown.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if self.state.conditions != nil || self.isShuttingDown {
                continuation.resume()
            } else {
                self.state.conditionWaiters[token] = continuation
            }
        }
    }

    // MARK: Unknown identifiers (point admission, sync.md §6.5)

    /// Answers every registered unknown-id waiter from the fetch's outcome: listed → admitted and joined (T1); absent
    /// → `.notFound` plus the negative cache. A fetch that failed still answers from the newest manifest seen (sync-1
    /// S1-13): an id that manifest or the applied one lists is admitted or joined, and only the others get the mapped
    /// error, never a manifest's verdict.
    private func answerUnknownWaiters(_ outcome: ManifestOutcome) async {
        let manifest: ValidatedManifest?
        let failure: AssetError?
        // A throttle's refusal tells each waiter the time left until the origin's throttle ends, read when that waiter is
        // answered: the admissions below await the store, and a transfer's 429 may extend the throttle meanwhile (F-38).
        var throttledUntil: MonotonicInstant?
        switch outcome {
        case .fetched(let fetched, _, _):
            manifest = fetched
            failure = nil
        case .notModified:
            manifest = self.state.newest?.manifest ?? self.state.applied
            failure = nil
        case .failed(let error):
            manifest = self.state.newest?.manifest
            failure = error.assetError(now: self.environment.time.now())
        case .invalid:
            manifest = self.state.newest?.manifest
            failure = .serverUnavailable(retryAfter: nil)
        case .circuitOpen(let cause):
            manifest = self.state.newest?.manifest
            failure = cause == .authentication ? .authRejected(.confirmed) : .serverUnavailable(retryAfter: nil)
        case .throttled(let until):
            manifest = self.state.newest?.manifest
            failure = self.throttledError(after: until)
            throttledUntil = until
        case .timedOut, .cancelled, .shutDown:
            return
        }
        let now = self.environment.time.monotonicNow()
        // Bindings learned while an admission's reads are in flight are kept for the joins (L4-R5).
        self.state.presenceReaders += 1
        defer {
            self.state.presenceReaders -= 1
        }
        for token in self.state.unknownWaiters.keys.sorted() {
            guard let waiter = self.state.unknownWaiters[token] else {
                continue
            }
            guard let entry = self.state.applied.entry(for: waiter.asset) ?? manifest?.entry(for: waiter.asset) else {
                self.state.unknownWaiters[token] = nil
                if let failure {
                    waiter.continuation.resume(returning: .failure(throttledUntil.map { self.throttledError(after: $0) } ?? failure))
                } else {
                    self.state.negativeCache.insert(waiter.asset, until: now.adding(seconds: self.tuning.unknownIDRefetchInterval), capacity: self.tuning.unknownIDCacheCapacity)
                    waiter.continuation.resume(returning: .failure(.notFound))
                }
                continue
            }
            if self.state.applied.entry(for: waiter.asset) == nil {
                let mark = self.state.copySerial
                let serial = self.state.ledgerForgets
                do {
                    // REENTRANCY: RE-S37 — the waiter is re-checked as still registered right below.
                    try await self.store.admit(entry)
                    // REENTRANCY: RE-S37 — the lifecycle; the applied manifest is re-read as a snapshot and followed
                    // unless the read may predate the copy (`followStoreView`), and an admitted record the store bound to
                    // a live blob is answered from the store.
                    let view = try await self.store.planningView()
                    self.followStoreView(view, readAt: mark)
                    self.noteBound(from: view, ids: [waiter.asset], since: serial)
                } catch {
                    if let pending = self.state.unknownWaiters.removeValue(forKey: token) {
                        pending.continuation.resume(returning: .failure(error.assetError))
                    }
                    continue
                }
                guard self.isRunning else {
                    return
                }
            }
            guard let pending = self.state.unknownWaiters.removeValue(forKey: token) else {
                continue
            }
            self.state.negativeCache.remove(pending.asset)
            self.join(token, waiter: pending, entry: entry)
        }
        self.pump()
        self.notifyObservers()
    }

    /// Turns an admitted unknown-id waiter into an ordinary waiter of its job (T1).
    private func join(_ token: InterestToken, waiter: UnknownWaiter, entry: ManifestEntry) {
        self.state.waiters[token] = Waiter(asset: waiter.asset, transfer: entry.transferID, continuation: waiter.continuation)
        if self.isBound(waiter.asset, to: entry.transferID) {
            self.answerWaiterFromStore(token, asset: waiter.asset, lane: waiter.lane, transfer: entry.transferID)
            return
        }
        self.addInterest(token, asset: waiter.asset, entry: entry, lane: waiter.lane, kind: .waiter)
    }
}
