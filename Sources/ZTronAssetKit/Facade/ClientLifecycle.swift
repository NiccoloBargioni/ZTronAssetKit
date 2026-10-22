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

/// The places where a test can hold or observe `ClientLifecycle` through its seam (`docs/adr-drafts/g.md` G-10). The
/// seam is `nil` in production; each point exists because an interleaving there was a bug no test could otherwise
/// reach deterministically (CLAUDE.md G4), or because the L5-R13 model needs it (`replacementBuilt`). Tests match points
/// by pattern.
enum LifecycleSeamPoint: Sendable {
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
/// `EventForwarder`: a forwarder becomes a follower in the turn that chooses the engine it registers with
/// (`register(_:)`), and every follower is subscribed to the replacement before it is installed (L5-R3, L5-R13), so a
/// stream misses none of the replacement's events.
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

    /// A live event forwarder (G-2, L5-R3, L5-R13), held weakly: the consumer's stream and the forwarder's pump hold it,
    /// and the forwarder gives its entry back when its pump ends, or when it stops before any pump started.
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
    /// The event forwarders registered with this client's engines, by key, each recorded in the turn that chose its
    /// engine (L5-R13); a reopen hands each the replacement's stream before installing it (L5-R3).
    private var followers: [UInt64: Follower] = [:]
    private var lastFollower: UInt64 = 0
    /// Test seam, `nil` in production: awaited at each `LifecycleSeamPoint`, so a test can place a shutdown, a reopen or
    /// a pressure event exactly there (CLAUDE.md G4: interleavings no test could otherwise reach deterministically).
    private var seam: (@Sendable (LifecycleSeamPoint) async -> Void)?
    /// Test seam, `nil` in production: called on the actor after each change of the follower entries with their number
    /// and the number of followers ever recorded (`lastFollower`), so the L5-R13 model can wait, without polling, for none
    /// to be left (its I3) and for a stream's follow turn, which it stamps (orchestrator ruling L5-R21, L5-C2-04).
    private var followerObserver: (@Sendable (_ followers: Int, _ recorded: UInt64) -> Void)?

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
            // REENTRANCY: g-9 (proposed) — nothing here: the hand-over below re-reads the followers and `closed` (a test
            // seam; `nil` in production).
            await seam(.replacementBuilt(next))
        }
        // The hand-over (L5-R3, L5-R13, g-10): every follower is subscribed to `next` through its eager-registering
        // `subscribe()` and handed that stream. `next` is `created` and unreachable by callers, so it publishes nothing
        // until it is installed. The last look at the followers, the check of `closed` and the installation happen in one
        // turn, so every follower recorded before the installation holds a stream of `next` from its first event on.
        var handed: Set<UInt64> = []
        while true {
            guard !self.closed else {
                // A shutdown meanwhile installs nothing: the forwarders take only a stream of an installed generation, so
                // the ones handed `next` never read it.
                return self.endReopen(nil)
            }
            guard let key = self.followers.keys.filter({ !handed.contains($0) }).min() else {
                break
            }
            handed.insert(key)
            guard let forwarder = self.followers[key]?.forwarder else {
                self.followers[key] = nil
                self.followerObserver?(self.followers.count, self.lastFollower)
                continue
            }
            // REENTRANCY: g-10 (proposed) — the followers and `closed`, re-read at the loop's top (a follower recorded
            // meanwhile is handed a stream too); `next` cannot publish meanwhile.
            guard case .success(let stream) = await next.engine.subscribe() else {
                continue
            }
            // REENTRANCY: g-10 (proposed) — as above; a forwarder that finished meanwhile, or that holds a stream of this
            // generation already, drops the stream at once.
            await forwarder.handOver(stream, generation: next.generation)
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

    // MARK: Event forwarders (L5-R3, L5-R13)

    /// A forwarder's registration (L5-R13): its follower key and the stream it registered.
    struct ForwarderRegistration: Sendable {
        /// The key `unfollow(_:)` takes; `nil` when the forwarder was not made a follower (an `events` stream made after
        /// shutdown).
        let key: UInt64?
        /// The registered stream and its engine's generation; `nil` when that engine was retired by a reopen before it
        /// answered, so the streams the reopens handed over since carry the registration.
        let first: (stream: AsyncStream<AssetEvent>, generation: UInt64)?
    }

    /// Makes `forwarder` a follower and registers it with the engine serving now, choosing that engine in the same turn
    /// (orchestrator ruling L5-R13: followership precedes registration). Every reopen from this turn on hands the
    /// forwarder its replacement's stream before installing it (`performReopen`), so no reopen can fall between the
    /// followership and the registration. When the chosen engine was retired by a reopen before it answered (`.shutDown`,
    /// G-5), nothing is registered again: once that reopen installed its replacement, the stream it handed over carries
    /// the registration. After shutdown, `.shutDown` and no follower entry.
    func register(_ forwarder: EventForwarder) async -> Result<ForwarderRegistration, AssetError> {
        guard !self.closed else {
            return .failure(.shutDown)
        }
        self.lastFollower += 1
        let key = self.lastFollower
        self.followers[key] = Follower(forwarder: forwarder)
        self.followerObserver?(self.followers.count, self.lastFollower)
        let core = self.core
        // REENTRANCY: g-11 (proposed) — `closed`, `core` and `retiring`, re-read below: a reopen meanwhile hands this
        // follower its replacement's stream (the follower was recorded first), so only `core.engine`'s answer is used.
        let answer = await core.engine.subscribe()
        switch answer {
        case .success(let stream):
            return .success(ForwarderRegistration(key: key, first: (stream, core.generation)))
        case .failure(.shutDown) where self.hasRetired(core.generation):
            if let reopening = self.reopening {
                // REENTRANCY: g-11 (proposed) — `closed` and `core`, re-read right below: the reopen installed its
                // replacement, whose stream it handed this follower, or the client was shut down.
                _ = await reopening.value
            }
            guard !self.closed, self.core.generation > core.generation else {
                self.unfollow(key)
                return .failure(.shutDown)
            }
            return .success(ForwarderRegistration(key: key, first: nil))
        case .failure(let error):
            self.unfollow(key)
            return .failure(error)
        }
    }

    /// An `events` stream's registration on its first pull (L5-R13): `register(_:)`, or after shutdown the last engine's
    /// stream, which yields only its `clientShutDown` (R-SYN-15), with no follower entry.
    func registerEvents(_ forwarder: EventForwarder) async -> ForwarderRegistration {
        // REENTRANCY: g-11 (proposed) — `core`, read after the registration only when it failed (the client is shut down).
        if case .success(let registration) = await self.register(forwarder) {
            return registration
        }
        return ForwarderRegistration(key: nil, first: (self.core.engine.makeEventStream(), self.core.generation))
    }

    /// Removes a follower entry: its forwarder's pump ended, or it stopped before any pump started, or its registration
    /// failed.
    func unfollow(_ key: UInt64) {
        self.followers[key] = nil
        self.followerObserver?(self.followers.count, self.lastFollower)
    }

    /// The followers' forwarders that are still alive (a test read: the L5-R13 model asks each how many events wait
    /// in it, its I4).
    var liveFollowers: [EventForwarder] {
        self.followers.keys.sorted().compactMap { self.followers[$0]?.forwarder }
    }

    /// Installs or removes the follower observer (tests only; see `followerObserver`), and reports the current counts to
    /// a new one at once.
    func setFollowerObserver(_ observer: (@Sendable (_ followers: Int, _ recorded: UInt64) -> Void)?) {
        self.followerObserver = observer
        observer?(self.followers.count, self.lastFollower)
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
