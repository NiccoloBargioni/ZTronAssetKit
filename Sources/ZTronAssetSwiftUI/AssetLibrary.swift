import Combine
@_exported import ZTronAssetKit

/// The SwiftUI-facing facade of the package (ADR-058): one main-actor `ObservableObject` that an app creates once,
/// injects at its root view with `environmentObject(_:)` and reads from any view with `@EnvironmentObject`.
///
/// It owns one `AssetClient` and adds nothing to what the client does: every method forwards to the client, to its
/// fallback chain or to its prefetch window, so the guarantees are the client's (R-CAR-1). What it adds is state a
/// view can render: the client's event stream is folded into four published properties, so a view never iterates a
/// stream to show a launch state or a sync bar.
///
/// The published state does not say that a file arrived. A view that shows a file awaits `url(for:kind:)` in a
/// `.task` and keeps the URL in its own state; `lookup` and `locate` answer what is on the device at that instant.
///
/// A library is described by a chain of calls that starts at `AssetLibrary.origin(_:)` or
/// `AssetLibrary.appleHosted()` and ends in `library()` (`AssetLibrary.Setup`); it takes no options value. An app that
/// already holds a client, for example one built with its own `AssetEnvironment`, wraps it with `init(client:)`.
///
/// Creating a library performs no I/O and starts nothing (P-12). `start()` opens the store; the first asynchronous
/// call starts it too. Release it and the client shuts down with it, so keep it for the app's lifetime, as a
/// `@StateObject` of the `App`.
@MainActor
public final class AssetLibrary: ObservableObject {
    /// Where the library is in its life. `.ready` means the store is open and the first snapshot is installed, so
    /// `lookup` and `locate` answer.
    @Published public private(set) var phase: Phase = .idle
    /// The store's index generation as the client last announced it, `nil` until its first announcement, a moment
    /// after `phase` became `.ready`. The client announces it when the catalog changed: a manifest was applied, a
    /// purge ran, or a reopened store was caught up. It is assigned at each announcement, even when the number
    /// repeats (a store reopened after a replaced root may reuse one), so a view that derives something from the
    /// catalog reads it again. It is not assigned when a single asset arrives: the client announces those per asset,
    /// on `subscribe()`.
    @Published public private(set) var generation: UInt64?
    /// Network and power state as the client last read it, `nil` until its first reading. The client observes the
    /// device only while it has work (R-SYN-14: an idle client observes nothing), so this is the state during the
    /// last transfer or sync, not a live reachability monitor.
    @Published public private(set) var conditions: DeviceConditions?
    /// The bulk sync as a view shows it: nothing yet, running with its progress, or the last outcome.
    @Published public private(set) var syncActivity: SyncActivity = .idle

    /// The client the library drives: the way to everything the package offers that this facade does not repeat (the
    /// compatibility shims, a `PrefetchWindowController` of another radius).
    nonisolated public let client: AssetClient

    let chain: AssetFallbackChain
    let window: PrefetchWindowController
    /// The kinds whose bundled resources `start()` indexes.
    private let bundledKinds: [AssetKind]
    /// The single-flight start; forgotten when it fails, so `start()` can ask the client again.
    private var startup: Task<Void, Never>?
    /// Folds the client's events into the published state; ends with the stream or with the library.
    private var pump: EventPump?
    /// Every kind handed to the bundle index so far, and the last indexing started for them.
    private var indexedKinds: [AssetKind] = []
    private var indexing: Task<Void, Never>?
    /// The run whose outcome is published: a progress event of the same run that arrives later is stale.
    private var finishedRun: SyncRunID?

    /// Wraps a client the app built itself. The bundle step of `locate` and `url(for:kind:)` reads `Bundle.main`,
    /// and nothing is indexed until a kind is first asked for.
    public convenience init(client: AssetClient) {
        self.init(client: client, bundle: MainBundleLookup(), bundledKinds: [])
    }

    /// The designated initialiser, reached from `Setup.library()`: stores values and creates the chain and the
    /// window, which do no I/O either (P-12).
    init(client: AssetClient, bundle: any BundleLookup, bundledKinds: [AssetKind]) {
        self.client = client
        self.chain = AssetFallbackChain(client: client, bundle: bundle)
        self.window = PrefetchWindowController(client: client)
        self.bundledKinds = bundledKinds
    }

    // MARK: - Lifecycle

    /// Opens the store, launches the sync that is due and starts publishing state. Single-flight and idempotent: it
    /// returns once `phase` is `.ready`, `.failed` or `.shutDown`, and reports a failure there instead of throwing,
    /// because a view renders the phase.
    ///
    /// After a failure, calling it again asks the client again. A client whose store could not be opened answers
    /// the same failure for as long as it lives (it never opens a store twice), so `.failed(.storageUnavailable)`
    /// is final for this library: recovering, for example once another process let go of a `.locked` store, takes a
    /// new library.
    ///
    /// The work runs in a task of the library's own, so a caller that goes away (a `.task` whose view disappeared)
    /// does not cancel the start for everyone else.
    public func start() async {
        switch self.phase {
        case .ready, .shutDown:
            return
        case .idle, .starting, .failed:
            break
        }
        // REENTRANCY: ui-1 — nothing is read after the wait; `launch()` published the phase.
        await self.startupTask().value
    }

    /// Shuts the client down (R-SYN-15): every task is cancelled and joined, the index is flushed, and every call
    /// that needs the store fails with `.shutDown` from then on (`locate` and `url(for:kind:)` still answer an asset
    /// of the app bundle). Returns once the published state is final: `phase` is `.shutDown` and a sync that was
    /// running is reported as `.finished(.failed(.shutDown))`. Idempotent.
    public func shutdown() async {
        // REENTRANCY: ui-2 — `startup` and `pump` are read after the wait, which is when they are final: a start made
        // from here on is answered `.shutDown` by the client, and every stream ends with `clientShutDown`.
        await self.client.shutdown()
        // REENTRANCY: ui-2 — `pump` is read after it: a start in flight has ended, with or without a pump.
        await self.startup?.value
        // REENTRANCY: ui-2 — the pump has applied the stream's last events; the state below is written after them.
        await self.pump?.task.value
        self.pump = nil
        if case .running = self.syncActivity {
            self.syncActivity = .finished(.failed(.shutDown))
        }
        self.publish(\.phase, .shutDown)
    }

    /// Makes the first asynchronous call start the library, as it starts the client: only from `.idle`, so a failed
    /// start is retried by `start()` alone and never by a view that reacts to the failure.
    func begin() {
        if case .idle = self.phase {
            _ = self.startupTask()
        }
    }

    /// The start in flight, or a new one.
    private func startupTask() -> Task<Void, Never> {
        if let startup = self.startup {
            return startup
        }
        self.phase = .starting
        let startup = Task { [weak self] in
            guard let self else {
                return
            }
            // REENTRANCY: ui-1 — nothing is read after it.
            await self.launch()
        }
        self.startup = startup
        return startup
    }

    /// Indexes the bundle for the declared kinds while it subscribes (which starts the client and replays its
    /// current state), then hands the stream to the pump. The bundle needs no store, so its index is built whether
    /// or not the store opens: `locate` finds a bundled asset even after a failed start.
    private func launch() async {
        async let indexed: Void = self.index(self.bundledKinds)
        let events: AsyncStream<AssetEvent>
        do throws(AssetError) {
            // REENTRANCY: ui-1 — nothing is read after it: this is the only start in flight (`startup`), and the
            // phase it publishes is the one it set.
            events = try await self.client.subscribe()
        } catch {
            // REENTRANCY: ui-1 — as above.
            await indexed
            self.startup = nil
            self.phase = error == .shutDown ? .shutDown : .failed(error)
            return
        }
        // REENTRANCY: ui-1 — as above. A `shutdown()` that began meanwhile waits for this start, then for the pump
        // made below, whose stream the client ends, and publishes the final phase after both.
        await indexed
        self.phase = .ready
        self.pump = EventPump(Task { [weak self] in
            // REENTRANCY: ui-3 — each event is applied in the turn it arrives; the library is re-read (weak) per
            // event, so the pump never keeps the library alive.
            for await event in events {
                guard let self else {
                    return
                }
                self.apply(event)
            }
        })
    }

    // MARK: - Published state

    /// Folds one client event into the published state. Per-asset, breaker and maintenance events are not published:
    /// every published change re-renders each observing view, a prefetch window alone emits several per page, and
    /// `lookup` may still miss an asset for a moment after its event (ADR-016), so a view could not act on one
    /// anyway. `events` and `subscribe()` carry them.
    func apply(_ event: AssetEvent) {
        switch event {
        case .clientStarted(let generation):
            // A replacement engine after a reopen (the only engine that starts while a stream is registered) counts
            // its runs from the start again, and the engine it replaced took its run with it without an outcome.
            // The cause of every reopen is a replaced root, so that is the outcome published for such a run; the
            // replacement starts its own run when one is due.
            self.finishedRun = nil
            if case .running = self.syncActivity {
                self.syncActivity = .finished(.failed(.storageUnavailable(.rootVanished)))
            }
            self.generation = generation
        case .snapshotChanged(let generation):
            self.generation = generation
        case .conditionsChanged(let conditions):
            self.publish(\.conditions, conditions)
        case .syncStarted:
            // `finishedRun` stays: an engine numbers its runs upwards, so the run that starts is not the finished
            // one, and a progress event of the finished one that still arrives stays stale.
            self.publish(\.syncActivity, .running(nil))
        case .syncProgress(let run, let progress):
            guard run != self.finishedRun else {
                return
            }
            self.publish(\.syncActivity, .running(progress))
        case .syncFinished(let run, let outcome):
            self.finishedRun = run
            self.publish(\.syncActivity, .finished(outcome))
        case .clientShutDown:
            self.publish(\.phase, .shutDown)
        case .transferProgress, .assetAvailable, .assetFailed, .assetRemoved, .circuitChanged, .maintenanceFinished:
            return
        }
    }

    /// Assigns only a different value: `@Published` announces every assignment, equal or not, and each announcement
    /// re-renders every observing view.
    private func publish<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AssetLibrary, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    // MARK: - Bundle index

    /// Makes the bundle index cover `kinds` and returns once it does. `AssetFallbackChain.prepare(kinds:)` replaces
    /// the index, so every indexing covers all kinds asked for so far and runs after the one before it: the last one
    /// to finish is always the widest.
    func index(_ kinds: [AssetKind]) async {
        var added = false
        for kind in kinds where !self.indexedKinds.contains(kind) {
            self.indexedKinds.append(kind)
            added = true
        }
        if added {
            let all = self.indexedKinds
            let chain = self.chain
            let previous = self.indexing
            self.indexing = Task {
                // REENTRANCY: ui-4 — nothing of the library is read; this wait first is the invariant: the index
                // below replaces the one before it only once that one is installed.
                await previous?.value
                // REENTRANCY: ui-4 — nothing of the library is read.
                await chain.prepare(kinds: all)
            }
        }
        // REENTRANCY: ui-4 — nothing is read after the wait. The latest indexing covers `kinds`: it is this call's,
        // or a later one's, which covers more.
        await self.indexing?.value
    }
}

/// The pump's task, cancelled when the library releases it. A library cannot cancel a task from its own `deinit`
/// (the property is the main actor's), and a pump that only ends at its next event would hold its subscription on
/// an idle client for as long as an app that wrapped the client keeps it.
private final class EventPump: Sendable {
    let task: Task<Void, Never>

    init(_ task: Task<Void, Never>) {
        self.task = task
    }

    deinit {
        self.task.cancel()
    }
}

extension AssetLibrary {
    /// Where a library is in its life.
    public enum Phase: Sendable, Hashable {
        /// Created; this library has started nothing yet. (A library wrapped around a client the app already
        /// started is idle until its own `start()`, although the client answers.)
        case idle
        /// The store is being opened.
        case starting
        /// The store is open and the first snapshot is installed.
        case ready
        /// The start failed, for example with `.storageUnavailable(.locked)` when another client holds the store.
        /// Final for this library when the store could not be opened (see `start()`).
        case failed(AssetError)
        /// Shut down: every call fails with `.shutDown` and `lookup` answers `nil`.
        case shutDown
    }

    /// The bulk sync as a view shows it.
    public enum SyncActivity: Sendable, Hashable {
        /// No run was seen since the library started.
        case idle
        /// A run is in flight; its progress once the first figure arrived (at most ten a second, R-SYN-12).
        case running(SyncProgress?)
        /// The last run's outcome. `sync(_:)` returns the same value to its caller; `.notDue` starts no run and is
        /// never published here.
        indirect case finished(SyncOutcome)
    }
}
