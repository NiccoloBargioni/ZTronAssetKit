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
        self.state.manifestFetch?.waiters.removeValue(forKey: token)?.resume(returning: .cancelled)
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
        for token in waiting.keys.sorted() {
            waiting[token]?.resume(returning: outcome)
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
        if let until = self.state.throttles[remote.originID], until > now {
            return .throttled(until)
        }
        var breaker = self.state.breakers[remote.originID] ?? CircuitBreaker(policy: self.tuning.breaker)
        let before = breaker.publicState
        switch breaker.admit(.manifest, at: now) {
        case .allow, .probe:
            self.state.breakers[remote.originID] = breaker
            self.breakerChanged(remote.originID, from: before)
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
                    self.state.throttles[remote.originID] = max(self.state.throttles[remote.originID] ?? .zero, until)
                    self.state.heap.schedule(.throttle(remote.originID), at: until)
                    self.rearm()
                    return .throttled(until)
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
    /// → `.notFound` plus the negative cache; a failed fetch → the mapped error.
    private func answerUnknownWaiters(_ outcome: ManifestOutcome) async {
        let manifest: ValidatedManifest?
        switch outcome {
        case .fetched(let fetched, _, _):
            manifest = fetched
        case .notModified:
            manifest = self.state.newest?.manifest ?? self.state.applied
        case .failed(let error):
            self.failUnknownWaiters(error.assetError(now: self.environment.time.now()))
            return
        case .invalid:
            self.failUnknownWaiters(.serverUnavailable(retryAfter: nil))
            return
        case .circuitOpen(let cause):
            self.failUnknownWaiters(cause == .authentication ? .authRejected(.confirmed) : .serverUnavailable(retryAfter: nil))
            return
        case .throttled(let until):
            self.failUnknownWaiters(.serverUnavailable(retryAfter: until.seconds(since: self.environment.time.monotonicNow())))
            return
        case .timedOut, .cancelled, .shutDown:
            manifest = nil
        }
        guard let manifest else {
            return
        }
        let now = self.environment.time.monotonicNow()
        for token in self.state.unknownWaiters.keys.sorted() {
            guard let waiter = self.state.unknownWaiters[token] else {
                continue
            }
            guard let entry = self.state.applied.entry(for: waiter.asset) ?? manifest.entry(for: waiter.asset) else {
                self.state.unknownWaiters[token] = nil
                self.state.negativeCache.insert(waiter.asset, until: now.adding(seconds: self.tuning.unknownIDRefetchInterval), capacity: self.tuning.unknownIDCacheCapacity)
                waiter.continuation.resume(returning: .failure(.notFound))
                continue
            }
            if self.state.applied.entry(for: waiter.asset) == nil {
                do {
                    // REENTRANCY: RE-S37 — the waiter is re-checked as still registered right below.
                    try await self.store.admit(entry)
                    // REENTRANCY: RE-S37 — the lifecycle; the applied manifest is re-read as a snapshot.
                    let view = try await self.store.planningView()
                    self.adoptApplied(view.appliedManifest, etag: self.state.appliedETag)
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
    }

    /// Fails every unknown-id waiter with `error`, except those whose id the applied manifest lists by now (a run or an
    /// `ensureAvailable` applied it while the fetch failed): they join their job (sync-1 S1-13).
    private func failUnknownWaiters(_ error: AssetError) {
        let waiting = self.state.unknownWaiters
        self.state.unknownWaiters.removeAll()
        var joined = false
        for token in waiting.keys.sorted() {
            guard let waiter = waiting[token] else {
                continue
            }
            if let entry = self.state.applied.entry(for: waiter.asset) {
                self.join(token, waiter: waiter, entry: entry)
                joined = true
            } else {
                waiter.continuation.resume(returning: .failure(error))
            }
        }
        if joined {
            self.pump()
        }
        self.notifyObservers()
    }

    /// Turns an admitted unknown-id waiter into an ordinary waiter of its job (T1).
    private func join(_ token: InterestToken, waiter: UnknownWaiter, entry: ManifestEntry) {
        self.state.waiters[token] = Waiter(asset: waiter.asset, transfer: entry.transferID, continuation: waiter.continuation)
        self.addInterest(token, asset: waiter.asset, entry: entry, lane: waiter.lane, kind: .waiter)
    }
}
