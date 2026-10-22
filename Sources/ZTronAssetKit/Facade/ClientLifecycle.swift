import Foundation
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetSync

/// One store and the engine over it: the pair a client serves from, replaced as a whole by a reopen (B-15, B-17).
/// Two values are equal when they hold the same actors, so a seam point can carry one (`LifecycleSeamPoint`).
struct ClientCore: Sendable, Hashable {
    /// 0 for the pair `AssetClient.init` built, one more for each reopen.
    let generation: UInt64
    /// The store.
    let store: AssetStore
    /// The engine over `store`.
    let engine: SyncEngine

    static func == (lhs: ClientCore, rhs: ClientCore) -> Bool {
        lhs.generation == rhs.generation && lhs.store === rhs.store && lhs.engine === rhs.engine
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.generation)
        hasher.combine(ObjectIdentifier(self.engine))
    }
}

/// The places where a test can hold or observe `ClientLifecycle` through its seam (`docs/adr-drafts/g.md` G-10). The
/// seam is `nil` in production; each point exists because an interleaving there was a bug no test could otherwise
/// reach deterministically (CLAUDE.md G4).
enum LifecycleSeamPoint: Sendable, Hashable {
    /// `bind(_:)`: the engine answered a registration; the group, `closed` and the generation are re-read next.
    case registrationAnswered
    /// `performReopen`: the reopen of `generation` is running (`reopening` set, the generation retiring) and the old
    /// engine's shutdown comes next.
    case reopenWillShutDownEngine(generation: UInt64)
    /// `observeMemoryPressure`: the request with `epoch` was recorded.
    case pressureRecorded(epoch: UInt64)
    /// `shutdown()`: `closed` is set and a reopen is running, which the shutdown waits for next.
    case shutdownWillWaitForReopen
    /// `performReopen`: the replacement of `generation` is installed and the newest memory-pressure request applied to
    /// it while it is still `created`; its prefetch groups and its start come next (L5-R2: a shutdown here shuts a
    /// `created` engine down that owns an observer).
    case replacementObservesPressure(generation: UInt64)
    /// `performReopen`: the replacement was built and is not installed yet (`created`, unreachable by callers, so it
    /// has published nothing); the hand-over to the event forwarders and the installation come next. The L5-R13 model
    /// subscribes its oracle to the replacement here, and parks reopens here (orchestrator ruling L5-R13: a seam point
    /// the model needs).
    case replacementBuilt(ClientCore)
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
/// `EventForwarder`: every live forwarder is subscribed to the replacement before it is installed (L5-R3), so a
/// consumer misses none of the replacement's events.
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

    /// A live event forwarder (G-2, L5-R3), held weakly: the consumer's stream and the forwarder's pump hold it, and the
    /// pump unregisters it when it ends.
    private struct Follower {
        weak var forwarder: EventForwarder?
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
    /// The event forwarders whose pumps read this client's engines, by key; a reopen hands each the replacement's
    /// stream before installing it (L5-R3).
    private var followers: [UInt64: Follower] = [:]
    private var lastFollower: UInt64 = 0
    /// Test seam, `nil` in production: awaited at each `LifecycleSeamPoint`, so a test can place a shutdown, a reopen or
    /// a pressure event exactly there (CLAUDE.md G4: interleavings no test could otherwise reach deterministically).
    private var seam: (@Sendable (LifecycleSeamPoint) async -> Void)?
    /// Test seam, `nil` in production: called on the actor with the number of follower entries after each change, so
    /// the L5-R13 model can wait for none to be left (its I3) without polling.
    private var followerObserver: (@Sendable (Int) -> Void)?

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
            // REENTRANCY: g-2 (proposed) — nothing here: `performReopen` re-checks `closed` after each of its awaits.
            await self.performReopen(old)
        }
        self.reopening = task
        // REENTRANCY: g-1 (proposed) — nothing: the task's result is returned as is.
        return await task.value
    }

    /// The reopen's steps; every await is followed by a check of `closed`, so a shutdown meanwhile builds nothing.
    private func performReopen(_ old: ClientCore) async -> ClientCore? {
        if let seam = self.seam {
            // REENTRANCY: g-9 (proposed) — nothing here: `closed` is re-read after the old engine's shutdown below (a
            // test seam; `nil` in production).
            await seam(.reopenWillShutDownEngine(generation: old.generation))
        }
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
        if let seam = self.seam {
            // REENTRANCY: g-9 (proposed) — nothing here: the hand-over below re-reads the followers, and `closed` is
            // re-read after it (a test seam; `nil` in production).
            await seam(.replacementBuilt(next))
        }
        // REENTRANCY: g-10 (proposed) — `closed`, re-read right below: a shutdown meanwhile installs nothing (the
        // forwarders take only a stream of an installed generation, so the ones handed `next` never read it).
        await self.handOverFollowers(to: next)
        guard !self.closed else {
            return self.endReopen(nil)
        }
        self.core = next
        _ = self.endReopen(next)
        if let pressure = self.pressure, pressure.handler != nil {
            // REENTRANCY: g-3 (proposed) — nothing: the engine ignores a request whose epoch is not newer, so a
            // concurrent call with the same or a newer epoch wins either way.
            _ = await next.engine.observeMemoryPressure(epoch: pressure.epoch, handler: pressure.handler)
        }
        if let seam = self.seam {
            // REENTRANCY: g-9 (proposed) — nothing here: the loop below re-reads the generation, `bind` re-reads `closed`,
            // and the start answers `.shutDown` after a shutdown (a test seam; `nil` in production).
            await seam(.replacementObservesPressure(generation: next.generation))
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

    /// Subscribes every live forwarder to `next` through its eager-registering `subscribe()` and hands it the stream,
    /// before `next` is installed (L5-R3): `next` is `created` and unreachable by callers, so it publishes nothing until
    /// every forwarder holds its stream, and a forwarder reads the replacement from its first event on, after its old
    /// engine's stream ended (`EventForwarder`). A forwarder that registers while this runs is handed one as well: the
    /// followers are re-read after each await; one that registers after the install has no history to lose, and the
    /// replay of its own registration covers the state.
    private func handOverFollowers(to next: ClientCore) async {
        var handled: Set<UInt64> = []
        while let key = self.followers.keys.filter({ !handled.contains($0) }).min() {
            handled.insert(key)
            guard let forwarder = self.followers[key]?.forwarder else {
                self.followers[key] = nil
                self.followerObserver?(self.followers.count)
                continue
            }
            // REENTRANCY: g-10 (proposed) — the followers, re-read at the loop's top (one registered meanwhile is handed a
            // stream too); `next` cannot publish meanwhile (`created`, not installed); `closed` is re-read by the caller.
            guard case .success(let stream) = await next.engine.subscribe() else {
                continue
            }
            // REENTRANCY: g-10 (proposed) — as above; a forwarder that finished meanwhile drops the stream at once.
            await forwarder.handOver(stream, generation: next.generation)
        }
    }

    // MARK: Event forwarders (L5-R3)

    /// Registers a forwarder whose pump reads this client's engines: every reopen from now on hands it the replacement's
    /// stream before installing the replacement. Returns the key `unfollow(_:)` takes.
    func follow(_ forwarder: EventForwarder) -> UInt64 {
        self.lastFollower += 1
        self.followers[self.lastFollower] = Follower(forwarder: forwarder)
        self.followerObserver?(self.followers.count)
        return self.lastFollower
    }

    /// Unregisters a forwarder whose pump ended.
    func unfollow(_ key: UInt64) {
        self.followers[key] = nil
        self.followerObserver?(self.followers.count)
    }

    /// The followers' forwarders that are still alive (a test read: the L5-R13 model asks each how many events wait
    /// in it, its I4).
    var liveFollowers: [EventForwarder] {
        self.followers.keys.sorted().compactMap { self.followers[$0]?.forwarder }
    }

    /// Installs or removes the follower-count observer (tests only; see `followerObserver`), and reports the current
    /// count to a new one at once.
    func setFollowerObserver(_ observer: (@Sendable (Int) -> Void)?) {
        self.followerObserver = observer
        observer?(self.followers.count)
    }

    // MARK: Shutdown

    /// Shuts the client down: no reopen afterwards, every registration refused, the current engine shut down.
    /// Idempotent.
    func shutdown() async {
        self.closed = true
        self.groups = [:]
        self.pressure = nil
        if let reopening = self.reopening {
            if let seam = self.seam {
                // REENTRANCY: g-9 (proposed) — nothing: the wait below follows, and `core` is read after it (a test
                // seam; `nil` in production).
                await seam(.shutdownWillWaitForReopen)
            }
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
    ///
    /// Never waits for a running reopen. The facade's handler calls this from inside the engine-owned observer task,
    /// and a reopen's first step, the old engine's shutdown, joins that task: a wait here would leave the observer
    /// waiting for the reopen, the reopen for the shutdown and the shutdown for the observer, for good (round 2,
    /// correctness lens). Nor does it need to wait: the request is recorded first, a running reopen applies the newest
    /// recorded request to its replacement once that is installed, and the old engine's shutdown stops its observer.
    func observeMemoryPressure(epoch: UInt64, handler: (@Sendable (MemoryPressureLevel) async -> Void)?) async {
        guard !self.closed, epoch > (self.pressure?.epoch ?? 0) else {
            return
        }
        self.pressure = PressureRequest(epoch: epoch, handler: handler)
        if let seam = self.seam {
            // REENTRANCY: g-9 (proposed) — `closed` and `reopening`, re-read right below (a test seam; `nil` in
            // production).
            await seam(.pressureRecorded(epoch: epoch))
        }
        guard !self.closed, self.reopening == nil else {
            return
        }
        // REENTRANCY: g-3 (proposed) — nothing: the engine orders requests by epoch, and a reopen that begins meanwhile
        // applies the newest recorded request to its replacement.
        _ = await self.core.engine.observeMemoryPressure(epoch: epoch, handler: handler)
    }

    /// Installs or removes the test seam (tests only; see `seam`).
    func setSeam(_ seam: (@Sendable (LifecycleSeamPoint) async -> Void)?) {
        self.seam = seam
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
            if let seam = self.seam {
                // REENTRANCY: g-4 (proposed) — as above (a test seam; `nil` in production).
                await seam(.registrationAnswered)
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
