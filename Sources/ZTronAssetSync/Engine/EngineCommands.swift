import Foundation
import ZTronAssetModel
import ZTronAssetStorage

/// How many bytes deep verification may hash per second of maintenance budget: the byte budget of a slice is derived
/// from the time budget, so a slice stops at its budget even when hashing is faster than the clock moves (R-SYN-16).
enum MaintenanceBudget {
    /// 256 MiB/s (the P-6 floor's order of magnitude).
    static let verificationBytesPerSecond: Double = 256 * 1_024 * 1_024

    /// The byte budget of a slice of `timeBudget` seconds (at least 1 byte).
    static func bytes(for timeBudget: TimeInterval) -> Int64 {
        guard timeBudget.isFinite, timeBudget > 0 else {
            return timeBudget == .infinity ? Int64.max : 1
        }
        let bytes = timeBudget * MaintenanceBudget.verificationBytesPerSecond
        return bytes >= Double(Int64.max) ? Int64.max : max(1, Int64(bytes))
    }
}

extension SyncEngine {
    // MARK: resolve (R-SYN-4, H-3)

    /// One asset at `lane`: the store's current location, an adopted legacy file, or a joined (or new) job; an unknown
    /// id is point-admitted from a fresh manifest (sync.md §6.5).
    func performAwaitAsset(_ id: AssetID, lane: AssetPriority) async -> Result<AssetLocation, AssetError> {
        if Task.isCancelled {
            return .failure(.cancelled)
        }
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        // REENTRANCY: RE-S36 — the lifecycle; a `nil` location falls through to the job path, which re-reads the record.
        if let location = await self.store.location(for: id, extensions: [], recordingAccess: true) {
            self.state.metrics.resolveHits += 1
            return .success(location)
        }
        guard self.isRunning else {
            return .failure(.shutDown)
        }
        if self.state.migration.pending {
            do {
                // REENTRANCY: RE-S36 — the lifecycle; a `nil` answer falls through to the job path.
                if let location = try await self.store.adoptLegacyNow(id) {
                    return .success(location)
                }
            } catch .cancelled {
                return .failure(.cancelled)
            } catch {
                // A legacy file that cannot be adopted is downloaded instead.
            }
            guard self.isRunning else {
                return .failure(.shutDown)
            }
        }
        let view: StorePlanningView
        do {
            // REENTRANCY: f-5 (proposed) — the lifecycle; the record decides T2 (quarantined: no job) before the join,
            // which is synchronous.
            view = try await self.store.planningView()
        } catch {
            return .failure(error.assetError)
        }
        guard self.isRunning else {
            return .failure(.shutDown)
        }
        if view.appliedManifest.digest != self.state.applied.digest || view.appliedManifest.count != self.state.applied.count {
            self.adoptApplied(view.appliedManifest, etag: self.state.appliedETag)
        }
        if let error = self.heldBackError(view.records[id], entry: view.appliedManifest.entry(for: id)) {
            return .failure(error)
        }
        if let error = self.missingSourceError {
            return .failure(error)
        }
        let token = self.nextToken()
        // REENTRANCY: RE-S25 — nothing: the body registers synchronously; the result arrives by value.
        return await withTaskCancellationHandler {
            // REENTRANCY: RE-S25 — as above.
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<AssetLocation, AssetError>, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .failure(.cancelled))
                    return
                }
                guard self.isRunning else {
                    continuation.resume(returning: .failure(.shutDown))
                    return
                }
                if let entry = self.state.applied.entry(for: id) {
                    if self.state.jobs[entry.transferID] != nil {
                        self.state.metrics.resolveJoins += 1
                    }
                    self.state.waiters[token] = Waiter(asset: id, transfer: entry.transferID, continuation: continuation)
                    self.addInterest(token, asset: id, entry: entry, lane: lane, kind: .waiter)
                    self.pump()
                    return
                }
                let now = self.environment.time.monotonicNow()
                if self.state.negativeCache.contains(id, at: now) {
                    continuation.resume(returning: .failure(.notFound))
                    return
                }
                self.state.unknownWaiters[token] = UnknownWaiter(asset: id, lane: lane, continuation: continuation)
                self.beginManifestFetch()
                self.notifyObservers()
            }
        } onCancel: {
            Task {
                // REENTRANCY: RE-S25 — nothing: the hop withdraws only this token (a no-op once it was resumed).
                await self.withdraw(token)
            }
        }
    }

    /// The error every fetch answers when `start()` could not build the remote source; `nil` when it exists.
    var missingSourceError: AssetError? {
        guard self.state.remote == nil else {
            return nil
        }
        return self.state.remoteError ?? .serverUnavailable(retryAfter: nil)
    }

    /// The stored answer for an asset that must not be fetched now (T2, ADR-032): failed until its entry changes, or
    /// quarantined / in integrity backoff for its current content.
    private func heldBackError(_ record: AssetRecord?, entry: ManifestEntry?) -> AssetError? {
        guard let record, let entry else {
            return nil
        }
        let now = self.environment.time.now()
        switch record.residency {
        case .failed(.notFound):
            return .notFound
        case .failed:
            return .integrityFailure
        case .quarantined(let until) where until > now:
            return .integrityFailure
        default:
            break
        }
        if let next = record.integrity.nextEligibleAt, next > now, record.integrity.failedIdentity == entry.contentIdentity, record.referencedBlob == nil {
            return .integrityFailure
        }
        return nil
    }

    /// A caller's cancellation (H-3): withdraws exactly its token.
    func withdraw(_ token: InterestToken) {
        if let waiter = self.state.waiters.removeValue(forKey: token) {
            waiter.continuation.resume(returning: .failure(.cancelled))
            for transfer in self.state.jobs.keys.sorted() where self.state.jobs[transfer]?.interests[token] != nil {
                self.removeInterest(token, from: transfer)
            }
            self.pump()
        } else if let waiter = self.state.unknownWaiters.removeValue(forKey: token) {
            waiter.continuation.resume(returning: .failure(.cancelled))
        }
        self.reconcileIdle()
    }

    // MARK: Groups (R-CAR-3, R-CAR-4)

    /// Registers a prefetch handle's group synchronously; its members join in one owned task that skips assets
    /// already present (sync.md §6.3).
    func performRegisterGroup(_ ids: [AssetID], lane: AssetPriority) -> Result<InterestToken, AssetError> {
        guard !self.isShuttingDown else {
            return .failure(.shutDown)
        }
        if case .degraded(let reason) = self.state.lifecycle {
            return .failure(.storageUnavailable(reason))
        }
        let token = self.nextToken()
        self.state.groups[token] = Group(kind: .prefetch, lane: lane)
        let unique = Array(Set(ids)).sorted()
        self.spawn(.entry) { engine in
            // REENTRANCY: RE-S30 — nothing: the owned task hops onto the actor; `joinGroup` re-validates the group and the lifecycle.
            await engine.joinGroup(token, ids: unique, lane: lane)
        }
        self.notifyObservers()
        return .success(token)
    }

    /// Adds the group's interests for the members that are not present at their current content.
    private func joinGroup(_ token: InterestToken, ids: [AssetID], lane: AssetPriority) async {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        guard await self.ensureStarted() == nil, self.state.groups[token] != nil else {
            return
        }
        let view: StorePlanningView
        do {
            // REENTRANCY: RE-S30 — the lifecycle and the group still registered (a release drops it).
            view = try await self.store.planningView()
        } catch {
            return
        }
        guard self.isRunning, self.state.groups[token] != nil, self.missingSourceError == nil else {
            return
        }
        if view.appliedManifest.digest != self.state.applied.digest {
            self.adoptApplied(view.appliedManifest, etag: self.state.appliedETag)
        }
        for id in ids {
            guard let entry = self.state.applied.entry(for: id) else {
                continue
            }
            let record = view.records[id]
            if record?.referencedBlob != nil, record?.isStale == false {
                continue
            }
            if self.heldBackError(record, entry: entry) != nil {
                continue
            }
            self.state.groups[token]?.pending[id] = entry.transferID
            self.addInterest(token, asset: id, entry: entry, lane: lane, kind: .prefetch)
        }
        self.pump()
    }

    /// Releases a group; unknown tokens are ignored (idempotent, sync-1 S1-05).
    func performReleaseGroup(_ token: InterestToken) {
        guard let group = self.state.groups.removeValue(forKey: token) else {
            return
        }
        group.continuation?.resume(returning: false)
        for transfer in Set(group.pending.values).sorted() {
            self.removeInterest(token, from: transfer)
        }
        self.pump()
        self.reconcileIdle()
    }

    // MARK: Availability (R-SYN-10)

    /// Counts from the store: no network, no I/O.
    func performAvailability(scope: AssetScope) async -> Result<AvailabilityReport, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        // REENTRANCY: RE-S38 — the lifecycle; the answer is the store's snapshot.
        let report = await self.store.availability(of: scope)
        guard self.isRunning else {
            return .failure(.shutDown)
        }
        return .success(report)
    }

    /// Fetch-first, then everything missing in scope at user-initiated priority (sync.md §12.2), in an owned task; the
    /// caller's cancellation withdraws the group and throws `.cancelled`.
    func performEnsureAvailable(scope: AssetScope) async -> Result<AvailabilityReport, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        // REENTRANCY: RE-S25 — nothing: the join registers synchronously; the result arrives by value.
        let result = await self.joinEntry(stopsWorkOnCancel: true) { engine, token in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
            .availability(await engine.ensureTask(token, scope: scope))
        }
        switch result {
        case .availability(let report):
            return report
        case .done(.failure(let error)), .purge(.failure(let error)), .maintenance(.failure(let error)):
            return .failure(error)
        default:
            return .failure(.cancelled)
        }
    }

    /// The `ensureAvailable` task.
    private func ensureTask(_ token: InterestToken, scope: AssetScope) async -> Result<AvailabilityReport, AssetError> {
        if let error = self.missingSourceError {
            return .failure(error)
        }
        // REENTRANCY: RE-S04 — the lifecycle; the outcome is that of the shared fetch.
        let outcome = await self.fetchManifest(token, deadline: false)
        guard self.isRunning, !Task.isCancelled else {
            return .failure(self.isShuttingDown ? .shutDown : .cancelled)
        }
        var manifest: ValidatedManifest?
        var etag = self.state.appliedETag
        var fresh = false
        switch outcome {
        case .fetched(let fetched, let tag, _):
            manifest = fetched
            etag = tag
            fresh = true
        case .notModified:
            fresh = true
        case .failed, .invalid, .circuitOpen, .throttled, .timedOut:
            // Unreachable: the applied manifest decides; a complete scope is answered, otherwise the mapped error.
            // REENTRANCY: RE-S20 — the lifecycle; the report is the store's snapshot.
            let report = await self.store.availability(of: scope)
            if report.isComplete {
                return .success(report)
            }
            return .failure(SyncEngine.unreachableError(outcome, now: self.environment.time.now()))
        case .cancelled:
            return .failure(.cancelled)
        case .shutDown:
            return .failure(.shutDown)
        }
        let space: FreeSpace
        let view: StorePlanningView
        do {
            // REENTRANCY: RE-S06 — the lifecycle and the caller's cancellation.
            let measured = try await self.store.freeSpace()
            // User work plans against the space the OS keeps for important usage (sync-2 S2-23).
            space = FreeSpace(
                volumeImportant: measured.volumeImportant,
                volumeOpportunistic: measured.volumeImportant,
                usedBytes: measured.usedBytes,
                pendingReclaim: measured.pendingReclaim,
                budgetBytes: measured.budgetBytes,
                reserveBytes: measured.reserveBytes
            )
            // REENTRANCY: RE-S37 — the lifecycle; a snapshot `apply` re-validates.
            view = try await self.store.planningView()
        } catch {
            return .failure(error.assetError)
        }
        guard self.isRunning, !Task.isCancelled else {
            return .failure(self.isShuttingDown ? .shutDown : .cancelled)
        }
        self.state.freeSpace = space
        let target = manifest ?? view.appliedManifest
        let policy = PlanningPolicy(storage: self.configuration.storage, includeOnDemand: scope.isExplicit, now: self.environment.time.now())
        // REENTRANCY: RE-S07 — the lifecycle; apply diffs against current state anyway.
        var plan = await SyncEngine.planOffActor(self.planner, manifest: target, view: view, scope: scope, policy: policy, space: space)
        var eviction: EvictionPlan?
        if case .needsEviction(let bytes) = plan.space {
            // REENTRANCY: RE-S37 — the lifecycle; a dry run `apply` re-validates per victim.
            eviction = await self.store.evictionPlan(toFree: bytes, protecting: Set(plan.fetches.map(\.id)))
            if eviction == nil {
                var fallback = policy
                fallback.evictionPermitted = false
                // REENTRANCY: RE-S07 — as above.
                plan = await SyncEngine.planOffActor(self.planner, manifest: target, view: view, scope: scope, policy: fallback, space: space)
            }
        }
        guard self.isRunning, !Task.isCancelled else {
            return .failure(self.isShuttingDown ? .shutDown : .cancelled)
        }
        if case .insufficient(let required, let available) = plan.space {
            return .failure(.insufficientSpace(required: required, available: available))
        }
        if manifest != nil || eviction != nil {
            do {
                // REENTRANCY: RE-S09 — jobs of pruned ids end and changed identities follow (as a run's apply).
                let report = try await self.store.apply(target, etag: etag, eviction: eviction)
                self.adoptApplied(target, etag: etag)
                self.state.generation = max(self.state.generation, report.generation)
            } catch {
                return .failure(error.assetError)
            }
            guard self.isRunning, !Task.isCancelled else {
                return .failure(self.isShuttingDown ? .shutDown : .cancelled)
            }
        }
        var group = Group(kind: .ensure, lane: .userInitiated)
        for fetch in plan.fetches {
            group.pending[fetch.id] = fetch.transfer
        }
        self.state.groups[token] = group
        for fetch in plan.fetches {
            self.addInterest(token, asset: fetch.id, entry: fetch.entry, lane: .userInitiated, kind: .ensure)
        }
        self.pump()
        if !(self.state.groups[token]?.pending.isEmpty ?? true) {
            // REENTRANCY: RE-S20 — the lifecycle and the group still registered; the report is recomputed from the
            // store afterwards.
            let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if self.state.groups[token]?.pending.isEmpty ?? true {
                    continuation.resume(returning: self.state.groups[token] != nil)
                } else {
                    self.state.groups[token]?.continuation = continuation
                }
            }
            guard completed, self.isRunning else {
                self.performReleaseGroup(token)
                return .failure(self.isShuttingDown ? .shutDown : .cancelled)
            }
        }
        self.performReleaseGroup(token)
        // REENTRANCY: RE-S20 — the lifecycle; the report is recomputed from the store.
        var report = await self.store.availability(of: scope)
        guard self.isRunning else {
            return .failure(.shutDown)
        }
        report.manifestFresh = fresh
        return .success(report)
    }

    /// The error of an unreachable manifest for `ensureAvailable`.
    private static func unreachableError(_ outcome: ManifestOutcome, now: Date) -> AssetError {
        switch outcome {
        case .failed(let error):
            return error.assetError(now: now)
        case .circuitOpen(let cause):
            return cause == .authentication ? .authRejected(.confirmed) : .serverUnavailable(retryAfter: nil)
        default:
            return .serverUnavailable(retryAfter: nil)
        }
    }

    // MARK: Refresh (R-SYN-9)

    /// Whether a launch sync is due now.
    func performIsSyncDue() async -> Result<Bool, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        do {
            // REENTRANCY: RE-S38 — the lifecycle; the answer is the store's snapshot.
            let view = try await self.store.planningView()
            guard self.isRunning else {
                return .failure(.shutDown)
            }
            return .success(RefreshDecision.isSyncDue(
                policy: self.configuration.refresh,
                stamp: view.stamp,
                syncDueFlag: view.syncDue,
                appVersion: self.state.launch?.appVersion ?? "",
                now: self.environment.time.now(),
                syncedThisLaunch: self.state.syncedThisLaunch
            ))
        } catch {
            return .failure(error.assetError)
        }
    }

    /// The stamp's completion time.
    func performLastSyncedAt() async -> Result<Date?, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        do {
            // REENTRANCY: RE-S38 — the lifecycle; the answer is the store's snapshot.
            let view = try await self.store.planningView()
            guard self.isRunning else {
                return .failure(.shutDown)
            }
            return .success(view.stamp?.completedAt)
        } catch {
            return .failure(error.assetError)
        }
    }

    // MARK: Scope, pins, leases (ADR-027, ADR-044)

    /// Replaces the retention scope and pushes it to the store in an owned task (RE-S33); starts no run.
    func performSetRetentionScope(_ scope: AssetScope) async -> Result<Void, AssetError> {
        guard !self.isShuttingDown else {
            return .failure(.shutDown)
        }
        self.state.retentionScope = scope
        self.state.retentionSequence += 1
        let sequence = self.state.retentionSequence
        guard self.isRunning else {
            // `start()` pushes the scope in force after `open()`.
            return .success(())
        }
        // REENTRANCY: RE-S25 — nothing: the join registers synchronously; the result arrives by value.
        let result = await self.joinEntry(stopsWorkOnCancel: false) { engine, _ in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
            await engine.pushRetentionScope(sequence)
            return .done(.success(()))
        }
        if case .done(let outcome) = result {
            return outcome
        }
        return .failure(.cancelled)
    }

    private func pushRetentionScope(_ sequence: UInt64) async {
        guard self.state.retentionSequence == sequence else {
            return
        }
        // REENTRANCY: RE-S33 — the lifecycle; a scope set meanwhile has a newer sequence and pushes itself.
        await self.store.setRetentionScope(self.state.retentionScope)
    }

    /// Pins or unpins through the store in an owned task (ADR-039).
    func performSetPinned(_ ids: Set<AssetID>, pinned: Bool) async -> Result<Void, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        // REENTRANCY: RE-S25 — nothing: the join registers synchronously; the result arrives by value.
        let result = await self.joinEntry(stopsWorkOnCancel: false) { engine, _ in
            do throws(StoreError) {
                // REENTRANCY: RE-S30 — the lifecycle.
                try await engine.store.setPinned(ids, pinned: pinned)
                // REENTRANCY: RE-S40 — the lifecycle.
                await engine.refreshStoreDeadline()
                return .done(.success(()))
            } catch {
                return .done(.failure(error.assetError))
            }
        }
        if case .done(let outcome) = result {
            return outcome
        }
        return .failure(.cancelled)
    }

    /// A lease, resolving first when the asset is absent (R-CAR-8); one acquired after shutdown began is released at
    /// once (RE-S30).
    func performAcquireLease(_ id: AssetID) async -> Result<AssetLease, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        for attempt in 0..<2 {
            do {
                // REENTRANCY: RE-S36 — the lifecycle; a lease acquired after shutdown began is released at once.
                let lease = try await self.store.acquireLease(id)
                guard self.isRunning else {
                    // REENTRANCY: RE-S30 — terminal.
                    _ = await self.store.releaseLease(lease)
                    return .failure(.shutDown)
                }
                return .success(lease)
            } catch .notPresent where attempt == 0 {
                // REENTRANCY: RE-S36 — the lifecycle; the lease is retried once after the resolve.
                switch await self.performAwaitAsset(id, lane: .userInitiated) {
                case .success:
                    continue
                case .failure(let error):
                    return .failure(error)
                }
            } catch .unknownAsset(_) where attempt == 0 {
                // REENTRANCY: RE-S36 — as above.
                switch await self.performAwaitAsset(id, lane: .userInitiated) {
                case .success:
                    continue
                case .failure(let error):
                    return .failure(error)
                }
            } catch {
                return .failure(self.isShuttingDown ? .shutDown : error.assetError)
            }
        }
        return .failure(.notFound)
    }

    /// Releases a lease and re-arms the alarm with the store's new deadline; a no-op after shutdown.
    func performReleaseLease(_ lease: AssetLease) {
        guard self.isRunning else {
            return
        }
        self.spawn(.entry) { engine in
            // REENTRANCY: RE-S40 — the lifecycle; the heap's store entry is replaced by the newest deadline.
            let deadline = await engine.store.releaseLease(lease)
            await engine.leaseReleased(deadline)
        }
    }

    private func leaseReleased(_ deadline: MonotonicInstant?) {
        guard self.isRunning else {
            return
        }
        self.setStoreDeadline(deadline)
    }

    // MARK: Purge (R-CLN-6, RE-S24)

    /// Bumps the purge epoch before any await of the purge, ends the active run with `failed(.cancelled)`, withdraws
    /// non-user interests on purged ids (user waiters keep theirs and re-queue), then purges in an owned task.
    func performPurge(_ request: PurgeRequest) async -> Result<PurgeResult, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        self.state.purgeEpoch += 1
        self.settleRun(.cancelled)
        for transfer in self.state.jobs.keys.sorted() {
            guard let job = self.state.jobs[transfer] else {
                continue
            }
            let purged = job.assets.filter { asset in
                guard let entry = self.state.applied.entry(for: asset) else {
                    return true
                }
                switch request {
                case .all:
                    return true
                case .evictable:
                    return entry.policy != .essential
                case .scope(let scope):
                    return scope.contains(entry)
                }
            }
            guard !purged.isEmpty else {
                continue
            }
            for (token, interest) in job.interests.sorted(by: { $0.key < $1.key }) where interest.lane < .userInitiated && interest.kind != .waiter {
                if !interest.assets.isDisjoint(with: purged) {
                    self.removeInterest(token, from: transfer)
                }
            }
        }
        // REENTRANCY: RE-S25 — nothing: the join registers synchronously; the result arrives by value.
        let result = await self.joinEntry(stopsWorkOnCancel: true) { engine, _ in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
            .purge(await engine.purgeTask(request))
        }
        if case .purge(let outcome) = result {
            return outcome
        }
        if case .done(.failure(let error)) = result {
            return .failure(error)
        }
        return .failure(.cancelled)
    }

    private func purgeTask(_ request: PurgeRequest) async -> Result<PurgeResult, AssetError> {
        do {
            // REENTRANCY: RE-S24 — `purgeEpoch` was bumped before the await; afterwards the snapshot and the store's
            // deadline are refreshed.
            let result = try await self.store.purge(request)
            guard self.isRunning else {
                return .failure(.shutDown)
            }
            self.broadcast(.snapshotChanged(generation: self.state.generation))
            // REENTRANCY: RE-S40 — the lifecycle.
            await self.refreshStoreDeadline()
            self.pump()
            return .success(result)
        } catch {
            // REENTRANCY: RE-S40 — the lifecycle.
            await self.refreshStoreDeadline()
            return .failure(self.isShuttingDown ? .shutDown : error.assetError)
        }
    }

    // MARK: Maintenance (R-SYN-16, RE-S23)

    /// Staging GC, orphan GC, eviction and deep verification within `timeBudget`, in an owned task whose caller's
    /// cancellation stops it between batches.
    func runMaintenance(timeBudget: TimeInterval) async -> Result<MaintenanceReport, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        // REENTRANCY: RE-S25 — nothing: the join registers synchronously; the result arrives by value.
        let result = await self.joinEntry(stopsWorkOnCancel: true) { engine, _ in
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
            .maintenance(await engine.maintenanceTask(timeBudget: timeBudget))
        }
        if case .maintenance(let outcome) = result {
            return outcome
        }
        if case .done(.failure(let error)) = result {
            return .failure(error)
        }
        return .failure(.cancelled)
    }

    private func maintenanceTask(timeBudget: TimeInterval) async -> Result<MaintenanceReport, AssetError> {
        let deadline = self.environment.time.monotonicNow().adding(seconds: max(0, timeBudget))
        var report = MaintenanceReport(gcBytes: 0, evictedBytes: 0, verifiedBytes: 0, corruptFound: 0, budgetExhausted: false)
        func expired() -> Bool {
            Task.isCancelled || !self.isRunning || self.environment.time.monotonicNow() >= deadline
        }
        do {
            var claims = Set(self.state.jobs.keys)
            claims.formUnion(self.state.draining.keys)
            claims.formUnion(self.state.launchResumes.keys)
            // REENTRANCY: RE-S23 — the lifecycle, the deadline and cancellation, checked before every step.
            let staging = try await self.store.collectStaging(keeping: claims)
            report.gcBytes = PlanBuilder.adding(report.gcBytes, staging.bytesFreed)
            if expired() {
                report.budgetExhausted = true
                // REENTRANCY: RE-S40 — nothing: the callee re-reads the store deadline and the lifecycle.
                return await self.finishMaintenance(report)
            }
            // REENTRANCY: RE-S23 — as above.
            let garbage = try await self.store.collectGarbage(until: deadline)
            report.gcBytes = PlanBuilder.adding(report.gcBytes, garbage.bytesFreed)
            if expired() {
                report.budgetExhausted = true
                // REENTRANCY: RE-S40 — nothing: the callee re-reads the store deadline and the lifecycle.
                return await self.finishMaintenance(report)
            }
            // REENTRANCY: RE-S23 — as above.
            let eviction = try await self.store.evictIfNeeded()
            report.evictedBytes = eviction.bytesFreed
            if expired() {
                report.budgetExhausted = true
                // REENTRANCY: RE-S40 — nothing: the callee re-reads the store deadline and the lifecycle.
                return await self.finishMaintenance(report)
            }
            // REENTRANCY: RE-S23 — as above.
            let verification = try await self.store.verifyIntegrity(byteBudget: MaintenanceBudget.bytes(for: timeBudget), until: deadline)
            report.verifiedBytes = verification.bytesVerified
            report.corruptFound = verification.corrupt.count
            report.budgetExhausted = !verification.completedPass
            if !verification.corrupt.isEmpty {
                // REENTRANCY: RE-S30 — the lifecycle; quarantines read as a snapshot schedule their re-downloads.
                await self.scheduleHeals(verification.corrupt)
            }
            if self.state.migration.deferred, self.state.migration.pending, !expired() {
                self.startMigration()
            }
        } catch .cancelled {
            report.budgetExhausted = true
        } catch {
            return .failure(self.isShuttingDown ? .shutDown : error.assetError)
        }
        // REENTRANCY: RE-S40 — nothing: the callee re-reads the store deadline and the lifecycle.
        return await self.finishMaintenance(report)
    }

    private func finishMaintenance(_ report: MaintenanceReport) async -> Result<MaintenanceReport, AssetError> {
        // REENTRANCY: RE-S40 — the lifecycle.
        await self.refreshStoreDeadline()
        guard self.isRunning else {
            return .failure(.shutDown)
        }
        self.broadcast(.maintenanceFinished(report))
        return .success(report)
    }

    // MARK: Quarantine (R-CLN-8)

    /// Quarantines through the store, then schedules the re-download at the end of the quarantine.
    func performReportUnreadable(_ id: AssetID) async -> Result<Void, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        // REENTRANCY: RE-S25 — nothing: the join registers synchronously; the result arrives by value.
        let result = await self.joinEntry(stopsWorkOnCancel: false) { engine, _ in
            do throws(StoreError) {
                // REENTRANCY: RE-S30 — the lifecycle.
                try await engine.store.reportUnreadable(id)
            } catch {
                return .done(.failure(error.assetError))
            }
            // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
            await engine.quarantined([id])
            return .done(.success(()))
        }
        if case .done(let outcome) = result {
            return outcome
        }
        return .failure(.cancelled)
    }

    /// Announces quarantined assets and schedules their re-downloads.
    private func quarantined(_ ids: [AssetID]) async {
        for id in ids {
            self.broadcast(.assetRemoved(id, .quarantined))
        }
        // REENTRANCY: RE-S30 — the lifecycle.
        await self.scheduleHeals(ids)
        // REENTRANCY: RE-S40 — the lifecycle.
        await self.refreshStoreDeadline()
    }

    /// Schedules a re-download at the end of each asset's quarantine (read from the store's records).
    private func scheduleHeals(_ ids: [AssetID]) async {
        let view: StorePlanningView
        do {
            // REENTRANCY: RE-S30 — the lifecycle; the records are a snapshot.
            view = try await self.store.planningView()
        } catch {
            return
        }
        guard self.isRunning else {
            return
        }
        let wall = self.environment.time.now()
        let now = self.environment.time.monotonicNow()
        for id in ids {
            guard case .quarantined(let until)? = view.records[id]?.residency else {
                continue
            }
            self.scheduleHeal(id, at: now.adding(seconds: max(0, until.timeIntervalSince(wall))))
        }
    }

    // MARK: Reports (R-CLN-9, R-OBS-2, R-OBS-3)

    /// The store's report plus the source's copies (RE-S32).
    func performStorageReport() async -> Result<StorageReport, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        // REENTRANCY: RE-S32 — the lifecycle; the two figures are independent snapshots.
        var report = await self.store.storageReport()
        guard self.isRunning else {
            return .failure(.shutDown)
        }
        if let remote = self.state.remote {
            // REENTRANCY: RE-S32 — the lifecycle.
            report.sourceCopyBytes = await remote.sourceCopyBytes()
        }
        guard self.isRunning else {
            return .failure(.shutDown)
        }
        return .success(report)
    }

    /// Engine counters plus the store's.
    func performMetrics() async -> Result<MetricsSnapshot, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        // REENTRANCY: RE-S38 — the lifecycle; the store's counters are a snapshot.
        let stored = await self.store.metrics()
        guard self.isRunning else {
            return .failure(.shutDown)
        }
        var metrics = self.state.metrics
        metrics.evictions = stored.evictions
        metrics.evictedBytes = stored.evictedBytes
        metrics.gcBytes = stored.gcBytes
        metrics.integrityFailures += stored.integrityFailures
        return .success(metrics)
    }

    /// Counters, recent errors, launch facts and the store's generation and stamp.
    func performDiagnostics() async -> Result<EngineDiagnostics, AssetError> {
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        let view: StorePlanningView
        do {
            // REENTRANCY: RE-S38 — the lifecycle; a snapshot.
            view = try await self.store.planningView()
        } catch {
            return .failure(error.assetError)
        }
        guard self.isRunning else {
            return .failure(.shutDown)
        }
        var errors = self.state.recentErrors
        for field in self.state.clampedFields {
            errors.append(DiagnosticError(at: self.environment.time.now(), id: nil, failureClass: .rejected, detail: "clamped \(field)"))
        }
        return .success(EngineDiagnostics(
            introspection: self.currentIntrospection(),
            recentErrors: Array(errors.suffix(EngineDiagnostics.recentErrorCapacity)),
            appVersion: self.state.launch?.appVersion,
            launchEpoch: self.state.launch?.report.launchEpoch,
            indexGeneration: view.generation,
            stamp: view.stamp,
            retentionScope: self.state.retentionScope
        ))
    }

    // MARK: Memory pressure (R-CLN-11, ADR-044)

    /// Starts or stops the one observer; only the newest epoch applies.
    func performObserveMemoryPressure(epoch: UInt64, handler: (@Sendable (MemoryPressureLevel) async -> Void)?) -> Result<Void, AssetError> {
        guard !self.isShuttingDown else {
            return .failure(.shutDown)
        }
        guard epoch > self.state.pressure.epoch else {
            return .success(())
        }
        self.state.pressure.epoch = epoch
        self.state.pressure.handler = handler
        if handler == nil {
            let task = self.state.pressure.task
            self.state.pressure.task = nil
            self.cancelTask(task)
        } else if self.state.pressure.task == nil, self.environment.memoryPressure != nil {
            self.state.pressure.token += 1
            let token = self.state.pressure.token
            let task = self.spawn(.pressure) { engine in
                // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
                await engine.observePressure(token: token)
            }
            self.state.pressure.task = task
        }
        self.notifyObservers()
        return .success(())
    }

    private func observePressure(token: UInt64) async {
        defer {
            if self.state.pressure.token == token {
                self.state.pressure.task = nil
                self.notifyObservers()
            }
        }
        guard let source = self.environment.memoryPressure else {
            return
        }
        // REENTRANCY: RE-S31 — the observer's token is still the applied one, else it exits.
        let stream = await source.pressureEvents()
        // REENTRANCY: RE-S31 — per element: the token, the lifecycle and a handler still set.
        for await level in stream {
            guard self.state.pressure.token == token, !self.isShuttingDown, let handler = self.state.pressure.handler else {
                return
            }
            // REENTRANCY: RE-S31 — a stop requested from inside the handler ends the loop after it returns.
            await handler(level)
            guard self.state.pressure.token == token, self.state.pressure.handler != nil, !self.isShuttingDown else {
                return
            }
        }
    }

    // MARK: Background events (R-NET-3, RE-S42)

    /// Makes sure the background session exists and returns once the preceding events are staged.
    func performBackgroundEvents(identifier: String) async -> Result<Void, AssetError> {
        guard !self.isShuttingDown else {
            return .failure(.shutDown)
        }
        // REENTRANCY: RE-S26 — the lifecycle: the caller re-reads it (start may have degraded or shutdown begun).
        if let error = await self.ensureStarted() {
            return .failure(error)
        }
        if let remote = self.state.remote {
            // REENTRANCY: RE-S42 — the lifecycle.
            await remote.handleBackgroundEvents(identifier: identifier)
        }
        return self.isRunning ? .success(()) : .failure(.shutDown)
    }

    // MARK: Entry joins (ADR-039)

    /// Runs `body` in an engine-owned task joined by the caller: the caller's cancellation withdraws its token (and, when
    /// the work is the caller's alone, cancels the task).
    func joinEntry(stopsWorkOnCancel: Bool, _ body: @escaping @Sendable (SyncEngine, InterestToken) async -> EntryResult) async -> EntryResult {
        let token = self.nextToken()
        // REENTRANCY: RE-S25 — nothing: the body registers and spawns synchronously; the result arrives by value.
        return await withTaskCancellationHandler {
            // REENTRANCY: RE-S25 — as above.
            await withCheckedContinuation { (continuation: CheckedContinuation<EntryResult, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .done(.failure(.cancelled)))
                    return
                }
                self.state.entryJoins[token] = continuation
                guard let task = self.spawn(.entry, { engine in
                    // REENTRANCY: RE-S30 — nothing: the entry task's body re-validates the lifecycle after each of its awaits.
                    let result = await body(engine, token)
                    // REENTRANCY: RE-S21 — nothing: the owned task hops onto the actor; the callee re-validates the lifecycle after each of its awaits.
                    await engine.finishEntry(token, result)
                }) else {
                    self.state.entryJoins.removeValue(forKey: token)?.resume(returning: .done(.failure(.shutDown)))
                    return
                }
                self.state.entryTasks[token] = task
            }
        } onCancel: {
            Task {
                // REENTRANCY: RE-S25 — nothing: the hop withdraws only this token.
                await self.withdrawEntry(token, stopWork: stopsWorkOnCancel)
            }
        }
    }

    private func finishEntry(_ token: InterestToken, _ result: EntryResult) {
        self.state.entryTasks[token] = nil
        self.state.entryJoins.removeValue(forKey: token)?.resume(returning: result)
        self.reconcileIdle()
    }

    private func withdrawEntry(_ token: InterestToken, stopWork: Bool) {
        guard let continuation = self.state.entryJoins.removeValue(forKey: token) else {
            return
        }
        continuation.resume(returning: .done(.failure(.cancelled)))
        if stopWork {
            self.cancelTask(self.state.entryTasks[token])
            if let group = self.state.groups.removeValue(forKey: token) {
                group.continuation?.resume(returning: false)
                for transfer in Set(group.pending.values).sorted() {
                    self.removeInterest(token, from: transfer)
                }
                self.pump()
            }
        }
        self.reconcileIdle()
    }

    // MARK: Introspection (R-SYN-14, P-14)

    /// The engine's counters.
    func currentIntrospection() -> EngineIntrospection {
        var byState: [JobStateKind: Int] = [:]
        var queued: [AssetPriority: Int] = [:]
        var running = 0
        var preempting = 0
        var interests = 0
        for job in self.state.jobs.values {
            byState[job.state.kind, default: 0] += 1
            interests += job.interests.count
            switch job.state {
            case .queued:
                queued[job.lane, default: 0] += 1
            case .downloading:
                if job.active?.preempting == true {
                    preempting += 1
                } else {
                    running += 1
                }
            default:
                break
            }
        }
        return EngineIntrospection(
            lifecycle: self.state.lifecycle,
            jobsByState: byState,
            queued: queued,
            running: running,
            preempting: preempting,
            waiters: self.state.waiters.count + self.state.unknownWaiters.count,
            interests: interests,
            groups: self.state.groups.count + (self.state.run == nil ? 0 : 1),
            armedTimers: self.state.alarm == nil ? 0 : 1,
            scheduledDeadlines: self.state.heap.count,
            ownedTasks: self.state.tasks.count,
            watcherActive: self.state.watcher != nil,
            subscribers: self.state.subscribers.count,
            bufferedEvents: self.state.subscribers.values.reduce(0) { $0 + $1.liveCount },
            memoryPressureObserverActive: self.state.pressure.task != nil
        )
    }

    /// Suspends until `predicate` holds, re-evaluated after every mutation (never polled), or until the caller is
    /// cancelled (the `CensusWaiting` pattern, l2fu-1): the wait then returns with the predicate unmet.
    func performWaitUntil(_ predicate: @escaping @Sendable (EngineIntrospection) -> Bool) async {
        self.state.lastObserver += 1
        let id = self.state.lastObserver
        // REENTRANCY: RE-S25 — nothing: a terminal wait registered synchronously; resumed once by the mutation that
        // met the predicate, by the caller's cancellation or by shutdown.
        await withTaskCancellationHandler {
            // REENTRANCY: RE-S25 — as above.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if predicate(self.currentIntrospection()) || Task.isCancelled || self.state.lifecycle == .shutDown {
                    continuation.resume()
                } else {
                    self.state.observers[id] = Observer(predicate: predicate, continuation: continuation)
                    self.notifyConditions()
                }
            }
        } onCancel: {
            Task {
                // REENTRANCY: RE-S25 — nothing: the hop removes only this wait (a no-op once it was resumed).
                await self.cancelObserver(id)
            }
        }
    }

    private func cancelObserver(_ id: UInt64) {
        self.state.observers.removeValue(forKey: id)?.continuation.resume()
    }

    /// Test seam: registered `waitUntil` calls.
    func observerCount() -> Int {
        self.state.observers.count
    }

    /// Test seam: suspends until at least `count` `waitUntil` calls are registered; ends on the caller's cancellation.
    func waitUntilObservers(_ count: Int) async {
        // REENTRANCY: f-8 (proposed) — nothing: a terminal test wait.
        await self.awaitCondition { engine in
            engine.state.observers.count >= count
        }
    }

    /// Test seams' wait: suspends until `condition` holds on the actor, re-evaluated after every mutation, or until the
    /// caller is cancelled or shutdown ends (the `CensusWaiting` pattern).
    func awaitCondition(_ condition: @escaping @Sendable (isolated SyncEngine) -> Bool) async {
        self.state.lastObserver += 1
        let id = self.state.lastObserver
        // REENTRANCY: f-8 (proposed) — nothing: a terminal test wait registered synchronously and resumed once.
        await withTaskCancellationHandler {
            // REENTRANCY: f-8 (proposed) — as above.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if condition(self) || Task.isCancelled || self.state.lifecycle == .shutDown {
                    continuation.resume()
                } else {
                    self.state.conditionObservers[id] = ConditionObserver(condition: condition, continuation: continuation)
                }
            }
        } onCancel: {
            Task {
                // REENTRANCY: f-8 (proposed) — nothing: the hop removes only this wait.
                await self.cancelCondition(id)
            }
        }
    }

    private func cancelCondition(_ id: UInt64) {
        self.state.conditionObservers.removeValue(forKey: id)?.continuation.resume()
    }

    /// Re-evaluates the test seams' conditions.
    private func notifyConditions() {
        guard !self.state.conditionObservers.isEmpty else {
            return
        }
        for id in self.state.conditionObservers.keys.sorted() {
            guard let observer = self.state.conditionObservers[id], observer.condition(self) else {
                continue
            }
            self.state.conditionObservers[id] = nil
            observer.continuation.resume()
        }
    }

    /// Re-evaluates every `waitUntil` predicate (after a mutation).
    func notifyObservers() {
        self.notifyConditions()
        guard !self.state.observers.isEmpty else {
            return
        }
        let snapshot = self.currentIntrospection()
        for id in self.state.observers.keys.sorted() {
            guard let observer = self.state.observers[id], observer.predicate(snapshot) else {
                continue
            }
            self.state.observers[id] = nil
            observer.continuation.resume()
        }
    }

    /// The engine invariants (sync.md §6.2, ARCHITECTURE §7.1), as violations; checked by the model-based test.
    func invariantViolations() -> [String] {
        var violations: [String] = []
        for (token, waiter) in self.state.waiters where self.state.jobs[waiter.transfer]?.interests[token] == nil {
            violations.append("waiter \(token.rawValue) has no interest in \(waiter.transfer)")
        }
        for (transfer, job) in self.state.jobs {
            if job.interests.isEmpty, job.state != .verifying, job.state != .committing {
                violations.append("job \(transfer) has no interest in \(job.state.kind.rawValue)")
            }
            if (job.state == .downloading) != (job.active != nil) {
                violations.append("job \(transfer) in \(job.state.kind.rawValue) with active \(job.active != nil)")
            }
            for token in job.interests.keys where job.interests[token]?.kind == .waiter && self.state.waiters[token] == nil {
                violations.append("waiter interest \(token.rawValue) without a waiter")
            }
        }
        if self.runningCount > self.tuning.maxConcurrentTransfers {
            violations.append("\(self.runningCount) running > \(self.tuning.maxConcurrentTransfers)")
        }
        for (token, group) in self.state.groups {
            for (asset, transfer) in group.pending where self.state.jobs[transfer]?.interests[token] == nil {
                violations.append("group \(token.rawValue) member \(asset) without an interest")
            }
        }
        if self.state.queues.storedCount > 2 * self.state.jobs.count + 16 {
            violations.append("lane queues hold \(self.state.queues.storedCount) entries for \(self.state.jobs.count) jobs")
        }
        if self.state.metrics.illegalTransitions > 0 {
            violations.append("\(self.state.metrics.illegalTransitions) illegal transitions")
        }
        for (key, queue) in self.state.subscribers where queue.storedOrderCount > 2 * queue.liveCount + 16 {
            violations.append("subscriber \(key) order \(queue.storedOrderCount) > 2 × \(queue.liveCount) + 16")
        }
        if let stranded = self.strandedPendingRun() {
            violations.append(stranded)
        }
        return violations
    }

    /// Why the pending run can never start, if so: with no run in progress, its gate is open, or nothing (a deadline,
    /// the conditions watcher, a probe in flight) will open it (sync-2 S2-03, S2-25).
    private func strandedPendingRun() -> String? {
        guard self.isRunning, self.state.run == nil, let pending = self.state.pendingRun else {
            return nil
        }
        switch self.pendingRunGate(pending) {
        case .open:
            return "the pending run's \(pending.gate) gate is open but no run started"
        case .armed:
            return nil
        case .unarmed:
            return "nothing will open the pending run's \(pending.gate) gate"
        }
    }
}
