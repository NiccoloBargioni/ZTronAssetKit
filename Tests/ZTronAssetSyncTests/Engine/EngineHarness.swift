import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Manifest and payload builders for engine tests (WP-F).
enum EngineFixture {
    /// Deterministic payload bytes.
    static func bytes(_ seed: UInt64, count: Int = 300) -> Data {
        GeneratedPayload.bytes(seed: seed, offset: 0, length: count)
    }

    /// An entry for `bytes`; checksum-less when `checksum` is false.
    static func entry(
        _ id: String,
        _ bytes: Data,
        policy: AssetPolicy = .standard,
        tags: [String] = [],
        checksum: Bool = true,
        size: Bool = true,
        ext: String = "png",
        directory: [String] = ["dir"]
    ) -> ManifestEntry {
        ManifestEntry(
            identifier: AssetID(id),
            fileExtension: ext,
            remotePath: "media/\(id).\(ext)",
            localPathComponents: directory,
            byteSize: size ? Int64(bytes.count) : nil,
            checksum: checksum ? ContentHash.sha256(of: bytes) : nil,
            tags: tags,
            policy: policy
        )
    }

    /// The wire bytes of a manifest (the prior art's bare array, R-MAN-1).
    static func manifestData(_ entries: [ManifestEntry]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding plain value types cannot fail.
        return (try? encoder.encode(entries)) ?? Data("[]".utf8)
    }

    /// A strong ETag for `tag`.
    static func etag(_ tag: String) -> ETag? {
        ETag(rawValue: "\"\(tag)\"")
    }
}

/// An engine over a real `AssetStore` on `FakeFileSystem`, `ManualTimeSource`, `FakeRemoteSource` and the fake
/// conditions and memory-pressure sources (ARCHITECTURE §14). Gated for the Mutex-backed fakes (ADR-051).
@available(macOS 15.0, iOS 18.0, *)
struct EngineHarness {
    let time: ManualTimeSource
    let fileSystem: FakeFileSystem
    let sink: ScriptedSnapshotSink
    let source: FakeRemoteSource
    let conditions: FakeDeviceConditionsSource
    let pressure: FakeMemoryPressureSource
    let tap: RecordingLogTap
    let store: AssetStore
    let engine: SyncEngine
    let configuration: EngineConfiguration

    /// The store root's base on the fake volume.
    static let base = URL(fileURLWithPath: "/fake-volume/Library/Application Support", isDirectory: true)

    /// Builds a harness; nothing is started. `storeTime`, when given, is the store's own clock (and the fake volume's):
    /// a test that advances it ahead of the engine's `time` lets the store's timers (a purge's grace wait) run before the
    /// engine's alarm for the same instant, the order a busy engine actor produces, without any wall-clock wait.
    static func make(
        disk: DiskImage = DiskImage(),
        time: ManualTimeSource = ManualTimeSource(),
        storeTime: ManualTimeSource? = nil,
        source: FakeRemoteSource = FakeRemoteSource(),
        conditions: DeviceConditions = .unrestricted,
        tuning: SyncTuning = SyncTuning(),
        storage: StoragePolicy = StoragePolicy(),
        network: NetworkPolicy = NetworkPolicy(),
        power: PowerPolicy = PowerPolicy(),
        refresh: RefreshPolicy = .oncePerAppVersion,
        retentionScope: AssetScope = .all,
        appVersion: String = "1.0+1",
        metadata: (any BlockingExecutor)? = nil,
        bulk: (any BlockingExecutor)? = nil,
        planner: (any SyncPlanning)? = nil,
        capacity: Int64 = 64 << 30,
        commitInterval: TimeInterval = 0,
        installInterval: TimeInterval = 0,
        seed: UInt64 = 0x5EED,
        fileSystem existing: FakeFileSystem? = nil,
        sink existingSink: ScriptedSnapshotSink? = nil,
        remote: (any RemoteSource)? = nil,
        factory: (any RemoteSourceFactory)? = nil,
        legacy: LegacyMigrationPolicy = LegacyMigrationPolicy(enabled: false),
        legacyDefaults: FakeLegacyDefaults = FakeLegacyDefaults()
    ) -> EngineHarness {
        let fileSystem = existing ?? FakeFileSystem(
            disk: disk,
            time: storeTime ?? time,
            configuration: FakeFileSystemConfiguration(importantCapacity: capacity, opportunisticCapacity: capacity)
        )
        let sink = existingSink ?? ScriptedSnapshotSink()
        let conditionsSource = FakeDeviceConditionsSource(initial: conditions)
        let pressure = FakeMemoryPressureSource()
        let tap = RecordingLogTap()
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: metadata ?? InlineBlockingExecutor(),
            bulkExecutor: bulk ?? InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: seed),
            conditions: conditionsSource,
            remoteSources: factory ?? FakeRemoteSourceFactory(source: remote ?? source),
            appVersion: FakeAppVersionSource(version: appVersion),
            legacyDefaults: legacyDefaults,
            memoryPressure: pressure,
            logTap: tap
        )
        let storeConfiguration = StoreConfiguration(
            location: .applicationSupport,
            policy: storage,
            legacy: legacy,
            limits: ManifestLimits(),
            commitMinimumInterval: commitInterval,
            snapshotInstallInterval: installInterval
        )
        var storeEnvironment = environment
        if let storeTime {
            storeEnvironment.time = storeTime
        }
        let store = AssetStore(configuration: storeConfiguration, environment: StoreEnvironment(environment: storeEnvironment, snapshotSink: sink))
        let configuration = EngineConfiguration(
            tuning: tuning,
            storage: storage,
            network: network,
            power: power,
            refresh: refresh,
            remote: RemoteConfiguration(),
            limits: ManifestLimits(),
            retentionScope: retentionScope
        )
        let engine: SyncEngine
        if let planner {
            engine = SyncEngine(store: store, environment: environment, configuration: configuration, planner: planner)
        } else {
            engine = SyncEngine(store: store, environment: environment, configuration: configuration)
        }
        return EngineHarness(
            time: time,
            fileSystem: fileSystem,
            sink: sink,
            source: source,
            conditions: conditionsSource,
            pressure: pressure,
            tap: tap,
            store: store,
            engine: engine,
            configuration: configuration
        )
    }

    /// Scripts the next manifest fetch to return `entries` and every entry's transfer to stage its bytes.
    func serve(_ entries: [(ManifestEntry, Data)], etag: String = "v1") async {
        await self.source.scriptManifest([.fetched(EngineFixture.manifestData(entries.map(\.0)), etag: EngineFixture.etag(etag))])
        for (entry, bytes) in entries {
            await self.source.script(entry.transferID, [.stage(bytes)])
        }
    }

    /// Scripts every entry's transfer to stage its bytes.
    func scriptTransfers(_ entries: [(ManifestEntry, Data)]) async {
        for (entry, bytes) in entries {
            await self.source.script(entry.transferID, [.stage(bytes)])
        }
    }

    /// Applies `entries` through a run whose transfers are not scripted to succeed: on-demand entries stay absent.
    static func onDemand(_ id: String, _ bytes: Data) -> ManifestEntry {
        EngineFixture.entry(id, bytes, policy: .onDemand)
    }

    /// Scripts the next manifest fetch only.
    func serveManifest(_ entries: [ManifestEntry], etag: String = "v1") async {
        await self.source.scriptManifest([.fetched(EngineFixture.manifestData(entries), etag: EngineFixture.etag(etag))])
    }

    /// Starts the engine and requires success.
    @discardableResult
    func start() async throws -> OpenReport {
        try await self.engine.start().get()
    }

    /// The store's planning view.
    func view() async throws -> StorePlanningView {
        try await self.store.planningView()
    }

    /// Whether the engine owns nothing and the environment observes nothing (R-SYN-14's census).
    func isQuiet() async -> Bool {
        let state = await self.engine.introspect()
        let observers = await self.conditions.activeObservers
        let transfers = await self.source.activeTransfers
        return state.isIdleSilent && state.waiters == 0 && state.interests == 0 && self.time.pendingSleepers == 0 && observers == 0 && transfers == 0
    }

    /// What one step of `drive` found, decided in one engine turn.
    private enum DriveStep: Sendable {
        /// The predicate holds.
        case done
        /// The clock moved to the earliest sleeper.
        case advanced
        /// The advance budget is spent while a sleeper was still due to be woken.
        case exhausted(EngineIntrospection)
        /// Nothing may be woken now: wait for a change of these, or for one more sleeper than `sleepers`.
        case wait(EngineIntrospection, fence: MonotonicInstant?, sleepers: Int)
    }

    /// Drives the manual clock until `predicate` holds. Each step advances the clock to the earliest sleeper (the
    /// engine's alarm, or a store wait in an engine-owned task) when it is at most `maxStep` away, earlier than `before`
    /// and earlier than the engine's clock fence (`SyncEngine.clockFence()`: a manifest fetch's deadline or a probe's
    /// watchdog while that work is in flight, which the fakes finish without the clock); otherwise it waits for whichever
    /// comes first: the predicate, any change of the engine's counters or of its fence, or one more sleeper (the other
    /// waits end on their cancellation). The predicate, the fence and the advance are decided in one engine turn, so the
    /// clock never jumps to a timeout of work the engine began a moment earlier (L4-R17). A sleeper further away than
    /// `maxStep`, or at `before` or later, is a timeout the test must not trigger yet (a breaker's cooldown before the
    /// run it blocks has settled). `advances` bounds the clock's moves, not the waits: how many intermediate states a
    /// wait happens to observe depends on scheduling, how often the clock must move does not (an engine that re-arms
    /// a timer for ever exhausts it). Never a wall-clock wait. A drive cancelled by the test's time limit throws
    /// `neverQuiesced` with the engine's introspection, so the overrun says where it stopped.
    func drive(
        advances: Int = 1_024,
        maxStep: TimeInterval = .infinity,
        before: MonotonicInstant? = nil,
        until predicate: @escaping @Sendable (EngineIntrospection) -> Bool
    ) async throws {
        let engine = self.engine
        let time = self.time
        var advanced = 0
        while true {
            let budgetLeft = advanced < advances
            let step = await engine.readForTests { engine -> DriveStep in
                let state = engine.introspect()
                if predicate(state) {
                    return .done
                }
                let fence = engine.clockFence()
                // Counted before the deadline is read: a sleeper registered after this count, even one the read below
                // misses, ends the wait for one more (a count read later could include it and wait for ever).
                let sleepers = time.pendingSleepers
                guard let deadline = time.nextDeadline, deadline <= time.monotonicNow().adding(seconds: maxStep),
                    before.map({ deadline < $0 }) ?? true, fence.map({ deadline < $0 }) ?? true
                else {
                    return .wait(state, fence: fence, sleepers: sleepers)
                }
                guard budgetLeft else {
                    return .exhausted(state)
                }
                time.advance(to: deadline)
                return .advanced
            }
            switch step {
            case .done:
                return
            case .advanced:
                advanced += 1
            case .exhausted(let state):
                throw EngineHarnessError.neverQuiesced(state)
            case .wait(let state, let fence, let waiting):
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await engine.awaitCondition { engine in
                            let now = engine.introspect()
                            return now != state || predicate(now) || engine.clockFence() != fence
                        }
                    }
                    group.addTask {
                        await time.waitForSleepers(atLeast: waiting + 1)
                    }
                    _ = await group.next()
                    group.cancelAll()
                }
                if Task.isCancelled {
                    throw EngineHarnessError.neverQuiesced(await engine.introspect())
                }
            }
        }
    }

    /// Runs `operation` while a driver wakes every sleeper on the manual clock (a purge's grace wait, a commit window,
    /// a backoff), then stops the driver and returns once it has ended. Its waits end on cancellation, after which it
    /// advances nothing: a driver that outlived the call could advance the clock to a sleeper registered afterwards
    /// (PROBE-C8C-5, close-out cycle 9). It never wakes a sleeper at or past the engine's clock fence
    /// (`SyncEngine.clockFence()`), deciding the advance in one engine turn: it waits for the fenced work, which the fakes
    /// finish without the clock, instead of timing it out because it had not been scheduled yet (L4-R17).
    func withClock<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        let time = self.time
        let engine = self.engine
        let driver = Task {
            while !Task.isCancelled {
                await time.waitForSleepers(atLeast: 1)
                guard !Task.isCancelled else {
                    return
                }
                // The fence check and the advance happen in one engine turn, and not once this driver is cancelled. The
                // sleepers are counted before the deadline is read, so one registered after the count ends the wait below.
                let fenced = await engine.readForTests { engine -> (fence: MonotonicInstant, sleepers: Int)? in
                    let sleepers = time.pendingSleepers
                    guard !Task.isCancelled, let deadline = time.nextDeadline else {
                        return nil
                    }
                    if let fence = engine.clockFence(), deadline >= fence {
                        return (fence, sleepers)
                    }
                    time.advance(to: deadline)
                    return nil
                }
                guard let fenced, !Task.isCancelled else {
                    continue
                }
                let (fence, waiting) = fenced
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await engine.awaitCondition { $0.clockFence() != fence }
                    }
                    group.addTask {
                        await time.waitForSleepers(atLeast: waiting + 1)
                    }
                    _ = await group.next()
                    group.cancelAll()
                }
            }
        }
        let value: T
        do {
            value = try await operation()
        } catch {
            driver.cancel()
            await driver.value
            throw error
        }
        driver.cancel()
        await driver.value
        return value
    }

    /// Drives the clock until the engine is idle-silent and the conditions source observes nothing.
    func settle(advances: Int = 256) async throws {
        try await self.drive(advances: advances) { $0.isIdleSilent }
        try await self.conditions.requireObservers(equalTo: 0)
    }

    /// Runs `sync(.force)` while driving the clock (store commit windows and the alarm need time to pass). The
    /// clock never jumps by half the manifest fetch deadline or more, so a fetch still in flight (the launch run's,
    /// which `sync` joins) is never timed out by the driver.
    func syncDriven(_ mode: SyncMode = .force) async throws -> SyncOutcome {
        let engine = self.engine
        let run = Task { await engine.sync(mode) }
        await engine.waitUntil { $0.groups >= 1 || $0.lifecycle != .running }
        try await self.drive(maxStep: self.configuration.tuning.manifestFetchDeadline / 2) { $0.groups == 0 }
        return await run.value
    }
}

/// Harness failures.
enum EngineHarnessError: Error {
    /// The engine kept owning work.
    case neverQuiesced(EngineIntrospection)
}

/// A factory whose `makeRemoteSource` waits until the test opens it, so a test can act while `start()` is in its
/// `.starting` phase after the store opened and the retention scope was pushed. An actor: no lock (C1); its waits are
/// resumed by `open()` and by nothing else, so every test that enters it opens it.
@available(macOS 15.0, iOS 18.0, *)
actor GatedSourceFactory: RemoteSourceFactory {
    private let base: FakeRemoteSourceFactory
    private var entered = false
    private var isOpen = false
    private var gate: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    init(source: FakeRemoteSource) {
        self.base = FakeRemoteSourceFactory(source: source)
    }

    func makeRemoteSource(configuration: RemoteConfiguration, staging: any StagingSink, log: LogRoute) async throws(AssetError) -> any RemoteSource {
        self.entered = true
        let waiting = self.enteredWaiters
        self.enteredWaiters.removeAll()
        for waiter in waiting {
            waiter.resume()
        }
        if !self.isOpen {
            // REENTRANCY: nothing is read after it but the immutable base factory.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.gate = continuation
            }
        }
        // REENTRANCY: nothing: the base factory attaches the staging sink and returns its source.
        return try await self.base.makeRemoteSource(configuration: configuration, staging: staging, log: log)
    }

    /// Suspends until `start()` asked for the source.
    func waitUntilEntered() async {
        guard !self.entered else {
            return
        }
        // REENTRANCY: nothing: resumed by `makeRemoteSource`.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.enteredWaiters.append(continuation)
        }
    }

    /// Lets `makeRemoteSource` return.
    func open() {
        self.isOpen = true
        self.gate?.resume()
        self.gate = nil
    }
}

extension SyncEngine {
    /// Test seam for the clock drivers (`EngineHarness.drive`, `withClock`, `EngineRegressionCycle6Tests.driving`;
    /// L4-R17): the earliest deadline that would time out work the test fakes finish without the clock, or `nil`. That
    /// is an in-flight manifest fetch's deadline (`FakeRemoteSource` answers at once) and a breaker probe's watchdog
    /// while the probe runs. A driver that woke such a deadline because the work had not been scheduled yet would turn a
    /// scheduling delay into a timeout: the test's outcome would depend on the host's load, not on the engine. A test
    /// that wants such a timeout moves the clock itself, once the work is held (`R-SYN-6: a manifest fetch past its
    /// deadline falls back to the applied manifest and leaves the sync due`).
    func clockFence() -> MonotonicInstant? {
        var fence: MonotonicInstant?
        if let fetch = self.state.manifestFetch, let at = self.state.heap.deadline(for: .manifest(fetch.sequence)) {
            fence = at
        }
        for origin in self.state.breakers.keys.sorted() {
            guard case .halfOpen(_, _, _?, let watchdog?)? = self.state.breakers[origin]?.state else {
                continue
            }
            fence = min(fence ?? watchdog, watchdog)
        }
        return fence
    }

    /// Test seam: the transfers whose cancelled attempt still counts as draining.
    func drainingTransfers() -> [TransferID] {
        self.state.draining.keys.sorted()
    }

    /// Test seam: the owned-task key of the running attempt of `transfer`.
    func activeDriver(_ transfer: TransferID) -> UInt64? {
        self.state.jobs[transfer]?.active?.driver
    }

    /// Test seam: whether owned task `key` still runs.
    func ownsTask(_ key: UInt64) -> Bool {
        self.state.tasks[key] != nil
    }

    /// Test seam: `true` when no run exists or the active one has settled.
    func runSettledOrGone() -> Bool {
        self.state.run.map { $0.settlement != nil } ?? true
    }
}

/// A blocking executor that runs every unit at once except the one submitted next after `holdNext()`, which waits
/// for `release()`: a test holds one store step (a publication's hash, a commit) at an exact point without counting the
/// units before it (a `SteppedBlockingExecutor` holds every unit while holding). An actor: no lock (C1); a held unit is
/// resumed by `release()` and by nothing else, so every test that holds one releases it.
actor NextUnitGate: BlockingExecutor {
    private var armed = false
    private var skipping = 0
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        if self.armed, self.skipping > 0 {
            self.skipping -= 1
        } else if self.armed {
            self.armed = false
            // REENTRANCY: nothing: `work` is the caller's value; only `release()` resumes the unit.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.held = continuation
                let waiting = self.heldWaiters
                self.heldWaiters.removeAll()
                for waiter in waiting {
                    waiter.resume()
                }
            }
        }
        return work()
    }

    /// Holds the next unit submitted after `skipped` more have run (a run's manifest decode, then its `apply`'s
    /// planning unit, share the bulk executor).
    func holdNext(skipping skipped: Int = 0) {
        self.armed = true
        self.skipping = max(0, skipped)
    }

    /// Suspends until a unit is held.
    func waitForHold() async {
        guard self.held == nil else {
            return
        }
        // REENTRANCY: nothing: resumed by `run` when it holds a unit.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.heldWaiters.append(continuation)
        }
    }

    /// Lets the held unit run.
    func release() {
        self.held?.resume()
        self.held = nil
    }
}

/// A `FakeRemoteSource` that records how many file-system operations had happened when each transfer started, so a
/// test orders a transfer's start against the store's commits (R-SYN-8). An actor: no lock (C1).
@available(macOS 15.0, iOS 18.0, *)
actor OperationStampingSource: RemoteSource, StagingAttachable {
    nonisolated let base: FakeRemoteSource
    nonisolated let fileSystem: FakeFileSystem
    /// `fileSystem.operations.count` at each transfer's first start.
    private(set) var stamps: [TransferID: Int] = [:]

    init(base: FakeRemoteSource, fileSystem: FakeFileSystem) {
        self.base = base
        self.fileSystem = fileSystem
    }

    nonisolated var originID: String {
        self.base.originID
    }

    nonisolated var capabilities: RemoteSourceCapabilities {
        self.base.capabilities
    }

    func attach(staging: any StagingSink) async {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.attach(staging: staging)
    }

    func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        try await self.base.fetchManifest(request)
    }

    func transfer(_ request: TransferRequest) async -> any TransferHandle {
        if self.stamps[request.id] == nil {
            self.stamps[request.id] = self.fileSystem.operations.count
        }
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        return await self.base.transfer(request)
    }

    func reattachedTransfers() async -> [ReattachedTransfer] {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.reattachedTransfers()
    }

    func cancelTransfer(_ name: StagingFileName) async {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.cancelTransfer(name)
    }

    func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.reclaimSourceCopies(report)
    }

    func sourceCopyBytes() async -> Int64 {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.sourceCopyBytes()
    }

    func handleBackgroundEvents(identifier: String) async {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.handleBackgroundEvents(identifier: identifier)
    }

    func invalidate() async {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.invalidate()
    }
}

/// Joins `task`, cancelling it when the caller is cancelled (a test past its time limit): a join on an operation the test
/// lets finish step by step (a run whose held transfers it releases) then ends instead of hanging the runner (L4-R17).
func joinCancelling<T: Sendable>(_ task: Task<T, Never>) async -> T {
    await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

/// Waits until `task` finished or the engine shows `predicate`, whichever comes first: the two outcomes a test cannot
/// otherwise tell apart when a call is either answered at once or registered (the `waitUntil` ends on cancellation).
@available(macOS 15.0, iOS 18.0, *)
func untilFinishedOrObserved<T: Sendable>(_ task: Task<T, Never>, _ engine: SyncEngine, _ predicate: @escaping @Sendable (EngineIntrospection) -> Bool) async {
    let (signals, signal) = AsyncStream.makeStream(of: Void.self)
    Task {
        _ = await task.value
        signal.yield()
    }
    let observed = Task {
        await engine.waitUntil(predicate)
        signal.yield()
    }
    var iterator = signals.makeAsyncIterator()
    _ = await iterator.next()
    observed.cancel()
}
