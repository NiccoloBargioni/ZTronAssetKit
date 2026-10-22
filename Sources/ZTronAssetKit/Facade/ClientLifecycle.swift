import Foundation
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetSync

/// One store and the engine over it: the pair a client serves from, replaced as a whole by a reopen (B-15, B-17).
struct ClientCore: Sendable {
    /// 0 for the pair `AssetClient.init` built, one more for each reopen.
    let generation: UInt64
    /// The store.
    let store: AssetStore
    /// The engine over `store`.
    let engine: SyncEngine
}

/// Owns the client's current store and engine, and the reopen after a replaced root (ARCHITECTURE §8, B-15, B-17;
/// WP-G, `docs/adr-drafts/g.md` G-1).
///
/// A store whose root was replaced (`rootVanished`) refuses every commit and mutating call for the rest of its life,
/// and an engine is bound to its store for life, so the facade recovers by building a new pair over the same
/// configuration, environment and mirror. The reopen is single-flight and ordered: the old engine is shut down (its
/// store closed, so it can never install again), then the mirror is reset on the main actor, and only then is the
/// replacement built and started, so the reset precedes the replacement store's first install (B-17: its epoch comes
/// from the index files alone and can be smaller than the mirror's). What the caller registered through the facade
/// survives the reopen: prefetch groups are registered again with the new engine, the memory-pressure observer is
/// started again, and the run-time retention scope is the new engine's. Event streams follow through
/// `EventForwarder`.
///
/// Prefetch registrations go through here (`PrefetchRegistry`): the tokens handed to handles are the facade's own,
/// each bound to the engine token of the generation it was registered with, so a handle released after a reopen
/// never reaches an engine token of another generation.
actor ClientLifecycle: PrefetchRegistry {
    /// A prefetch group as the facade registered it.
    private struct PrefetchGroup {
        let ids: [AssetID]
        let lane: AssetPriority
        /// The generation and engine token it is registered under; `nil` until bound.
        var binding: (generation: UInt64, token: InterestToken)?
        /// A `bind(_:)` for this group is running (a reopen leaves it to that call).
        var bindInFlight = false
    }

    /// The newest memory-pressure request (R-CLN-11), applied again to a replacement engine.
    private struct PressureRequest {
        let epoch: UInt64
        let handler: (@Sendable (MemoryPressureLevel) async -> Void)?
    }

    private let configuration: AssetClientConfiguration
    private let environment: AssetEnvironment
    private let mirror: SnapshotMirror
    private var core: ClientCore
    /// The generation whose engine a running reopen is shutting down.
    private var retiring: UInt64?
    private var reopening: Task<ClientCore?, Never>?
    private var closed = false
    /// The newest retention-scope request (R-CAR-5), the scope a replacement engine is built with.
    private var retentionScope: AssetScope
    /// Counts retention-scope requests, so an apply can tell whether a newer one arrived meanwhile.
    private var retentionEpoch: UInt64 = 0
    private var groups: [InterestToken: PrefetchGroup] = [:]
    private var lastToken: UInt64 = 0
    private var pressure: PressureRequest?
    /// Test seam, `nil` in production: awaited by `bind(_:)` after the engine answered a registration and before the
    /// group, `closed` and the generation are re-read, so a test can place a shutdown or a reopen exactly there
    /// (CLAUDE.md G4: an interleaving no test could otherwise reach deterministically).
    private var registrationSeam: (@Sendable () async -> Void)?

    /// Builds the first pair: actors only, no I/O, no task (P-12).
    init(configuration: AssetClientConfiguration, environment: AssetEnvironment, mirror: SnapshotMirror) {
        self.configuration = configuration
        self.environment = environment
        self.mirror = mirror
        self.retentionScope = configuration.retentionScope
        self.core = ClientLifecycle.makeCore(
            generation: 0,
            configuration: configuration,
            environment: environment,
            mirror: mirror,
            retentionScope: configuration.retentionScope
        )
    }

    /// A store and engine for `configuration`, the engine's retention scope replaced by the run-time one. Pure
    /// construction (P-12).
    private static func makeCore(
        generation: UInt64,
        configuration: AssetClientConfiguration,
        environment: AssetEnvironment,
        mirror: SnapshotMirror,
        retentionScope: AssetScope
    ) -> ClientCore {
        let store = AssetStore(
            configuration: AssetClient.storeConfiguration(for: configuration),
            environment: StoreEnvironment(environment: environment, snapshotSink: mirror)
        )
        let engine = SyncEngine(
            store: store,
            environment: environment,
            configuration: EngineConfiguration(
                tuning: configuration.tuning.clamped().tuning,
                storage: configuration.storage,
                network: configuration.network,
                power: configuration.power,
                refresh: configuration.refresh,
                remote: configuration.remote,
                limits: configuration.limits,
                retentionScope: retentionScope
            )
        )
        return ClientCore(generation: generation, store: store, engine: engine)
    }

    // MARK: The current pair

    /// The pair serving now; waits for a running reopen. After shutdown, the last pair (its engine answers
    /// `.shutDown`).
    func current() async -> ClientCore {
        if let reopening = self.reopening {
            // REENTRANCY: g-1 (proposed) — nothing but `core`, read after the wait: the reopen installed it.
            _ = await reopening.value
        }
        return self.core
    }

    /// Whether the engine of `generation` was replaced, or is being shut down by a reopen: its `clientShutDown`
    /// then ends that engine's stream only, not the client's.
    func hasRetired(_ generation: UInt64) -> Bool {
        generation < self.core.generation || self.retiring == generation
    }

    /// Replaces the pair of `generation` after it reported `rootVanished`: single-flight, so callers that saw the
    /// same failure share one reopen, and a caller whose pair was already replaced gets the replacement. `nil` once
    /// the client is shut down.
    func reopen(replacing generation: UInt64) async -> ClientCore? {
        guard !self.closed else {
            return nil
        }
        if let reopening = self.reopening {
            // REENTRANCY: g-1 (proposed) — `closed` and `core`, read after the wait.
            _ = await reopening.value
            return self.closed ? nil : self.core
        }
        guard generation == self.core.generation else {
            return self.core
        }
        let old = self.core
        self.retiring = old.generation
        let task = Task {
            await self.performReopen(old)
        }
        self.reopening = task
        // REENTRANCY: g-1 (proposed) — nothing: the task's result is returned as is.
        return await task.value
    }

    /// The reopen's steps; every await is followed by a check of `closed`, so a shutdown meanwhile builds nothing.
    private func performReopen(_ old: ClientCore) async -> ClientCore? {
        // REENTRANCY: g-2 (proposed) — `closed`, re-read right below: a shutdown meanwhile ends the reopen.
        await old.engine.shutdown()
        guard !self.closed else {
            return self.endReopen(nil)
        }
        let mirror = self.mirror
        // REENTRANCY: g-2 (proposed) — `closed`, re-read right below.
        await MainActor.run {
            mirror.reset()
        }
        guard !self.closed else {
            return self.endReopen(nil)
        }
        let next = ClientLifecycle.makeCore(
            generation: old.generation + 1,
            configuration: self.configuration,
            environment: self.environment,
            mirror: mirror,
            retentionScope: self.retentionScope
        )
        self.core = next
        _ = self.endReopen(next)
        if let pressure = self.pressure, pressure.handler != nil {
            // REENTRANCY: g-3 (proposed) — nothing: the engine ignores a request whose epoch is not newer, so a
            // concurrent call with the same or a newer epoch wins either way.
            _ = await next.engine.observeMemoryPressure(epoch: pressure.epoch, handler: pressure.handler)
        }
        for token in self.groups.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            // A newer reopen replaced `next` meanwhile (its root vanished too): that reopen's loop re-registers what
            // is left, so this one stops rather than binding groups a second time.
            guard self.core.generation == next.generation else {
                break
            }
            guard let group = self.groups[token], !group.bindInFlight, group.binding?.generation != next.generation else {
                continue
            }
            // REENTRANCY: g-4 (proposed) — `bind` re-reads the group and the generation after each of its awaits; the
            // generation is re-read at the top of the next iteration.
            _ = await self.bind(token)
        }
        guard self.core.generation == next.generation else {
            // The callers get the newest pair rather than one already retired.
            return self.closed ? nil : self.core
        }
        // REENTRANCY: g-3 (proposed) — nothing: the result is left to the callers, whose calls start it too.
        _ = await next.engine.start()
        return next
    }

    private func endReopen(_ result: ClientCore?) -> ClientCore? {
        self.reopening = nil
        self.retiring = nil
        return result
    }

    // MARK: Shutdown

    /// Shuts the client down: no reopen afterwards, every registration refused, the current engine shut down.
    /// Idempotent.
    func shutdown() async {
        self.closed = true
        self.groups = [:]
        self.pressure = nil
        if let reopening = self.reopening {
            // REENTRANCY: g-5 (proposed) — `core`, read after the wait: the reopen stops at its next check of `closed`.
            _ = await reopening.value
        }
        // REENTRANCY: g-5 (proposed) — nothing: terminal.
        await self.core.engine.shutdown()
    }

    // MARK: Run-time state carried across a reopen

    /// Replaces the retention scope (R-CAR-5). The request is recorded first, so a reopen from now on builds its
    /// replacement with it; then the newest recorded scope is applied to the current engine, and applied again when a
    /// newer request was recorded or a reopen replaced the engine during the apply. Calls come from unordered tasks
    /// and can reach the engine in any order, so this is what leaves the engine on the newest request, the one a
    /// replacement would be built with. The engine records a scope on entry, whatever the caller's cancellation.
    func setRetentionScope(_ scope: AssetScope) async -> Result<Void, AssetError> {
        guard !self.closed else {
            return .failure(.shutDown)
        }
        self.retentionEpoch += 1
        self.retentionScope = scope
        while true {
            // REENTRANCY: g-8 (proposed) — `closed`, then the newest request, read right below.
            let core = await self.current()
            guard !self.closed else {
                return .failure(.shutDown)
            }
            let epoch = self.retentionEpoch
            // REENTRANCY: g-8 (proposed) — `closed`, the epoch and the generation, re-read below: a newer request or
            // a replacement engine means another pass.
            let result = await core.engine.setRetentionScope(self.retentionScope)
            let replaced = core.generation != self.core.generation || self.retiring == core.generation
            if case .failure(.shutDown) = result, !replaced || self.closed {
                return result
            }
            if !self.closed, replaced || self.retentionEpoch != epoch {
                continue
            }
            return result
        }
    }

    /// The retention scope a replacement engine would be built with (a test seam of the facade tests).
    var recordedRetentionScope: AssetScope {
        self.retentionScope
    }

    /// Starts (`handler` non-nil) or stops the memory-pressure observer of the current engine, remembering the
    /// newest request for a replacement engine. Requests come from unordered tasks: only a newer epoch counts.
    func observeMemoryPressure(epoch: UInt64, handler: (@Sendable (MemoryPressureLevel) async -> Void)?) async {
        guard !self.closed, epoch > (self.pressure?.epoch ?? 0) else {
            return
        }
        self.pressure = PressureRequest(epoch: epoch, handler: handler)
        // REENTRANCY: g-1 (proposed) — nothing else is read: a reopen meanwhile applies the newest request itself.
        let engine = await self.current().engine
        // REENTRANCY: g-3 (proposed) — nothing: the engine orders requests by epoch.
        _ = await engine.observeMemoryPressure(epoch: epoch, handler: handler)
    }

    /// Installs or removes the registration seam (tests only; see `registrationSeam`).
    func setRegistrationSeam(_ seam: (@Sendable () async -> Void)?) {
        self.registrationSeam = seam
    }

    // MARK: PrefetchRegistry

    /// Registers a group under a facade token, bound to the current engine (R-CAR-4); `.shutDown` after shutdown.
    func registerGroup(_ ids: [AssetID], lane: AssetPriority) async -> Result<InterestToken, AssetError> {
        guard !self.closed else {
            return .failure(.shutDown)
        }
        self.lastToken += 1
        let token = InterestToken(rawValue: self.lastToken)
        self.groups[token] = PrefetchGroup(ids: ids, lane: lane)
        // REENTRANCY: g-4 (proposed) — `bind` re-reads the group and the generation after each of its awaits.
        return await self.bind(token)
    }

    /// Releases a facade token's engine registration; unknown tokens and registrations of a replaced engine (its
    /// shutdown released them) are ignored.
    func releaseGroup(_ token: InterestToken) async {
        guard let group = self.groups.removeValue(forKey: token), let binding = group.binding,
            binding.generation == self.core.generation, self.retiring != binding.generation
        else {
            return
        }
        let engine = self.core.engine
        // REENTRANCY: g-6 (proposed) — nothing: terminal for this token.
        await engine.releaseGroup(binding.token)
    }

    /// Registers the group with the current engine; repeats when a reopen replaced that engine meanwhile, and gives a
    /// registration back when the group was released or the client shut down meanwhile. A group already bound to the
    /// current engine is left as it is: an older reopen's loop can reach a group a newer reopen has bound, and a
    /// second registration would hold the group's interest for the engine's life (no release would name its token).
    private func bind(_ token: InterestToken) async -> Result<InterestToken, AssetError> {
        self.groups[token]?.bindInFlight = true
        defer {
            self.groups[token]?.bindInFlight = false
        }
        while true {
            guard !self.closed else {
                self.groups.removeValue(forKey: token)
                return .failure(.shutDown)
            }
            guard let group = self.groups[token] else {
                return .success(token)
            }
            if let bound = group.binding?.generation, bound == self.core.generation, self.retiring != bound {
                return .success(token)
            }
            // REENTRANCY: g-4 (proposed) — the group, `closed` and the generation, re-read below.
            let core = await self.current()
            // REENTRANCY: g-4 (proposed) — as above.
            let result = await core.engine.registerGroup(group.ids, lane: group.lane)
            if let seam = self.registrationSeam {
                // REENTRANCY: g-4 (proposed) — as above (a test seam; `nil` in production).
                await seam()
            }
            let replaced = core.generation != self.core.generation || self.retiring == core.generation
            switch result {
            case .success(let engineToken):
                guard self.groups[token] != nil, !replaced, !self.closed else {
                    // Released meanwhile, or the engine was replaced or shut down (which releases everything).
                    if self.groups[token] == nil, !replaced {
                        // REENTRANCY: g-6 (proposed) — nothing: terminal for this registration.
                        await core.engine.releaseGroup(engineToken)
                        // A shutdown cleared the groups: the client holds nothing, which `awaitRegistration()`
                        // reports as `.shutDown` (ARCHITECTURE §8); otherwise the caller released the group.
                        return self.closed ? .failure(.shutDown) : .success(token)
                    }
                    continue
                }
                self.groups[token]?.binding = (core.generation, engineToken)
                return .success(token)
            case .failure(let error):
                if case .shutDown = error, replaced, !self.closed {
                    continue
                }
                self.groups.removeValue(forKey: token)
                return .failure(error)
            }
        }
    }
}
