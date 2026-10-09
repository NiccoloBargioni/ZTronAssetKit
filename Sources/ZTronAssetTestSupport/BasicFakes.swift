import Foundation
import ZTronAssetModel

/// Runs every unit inline on the caller (ADR-003): deterministic op order, no thread hops, TSan-clean. Not a
/// cooperative-pool-safe executor for production; tests only.
public struct InlineBlockingExecutor: BlockingExecutor {
    /// Creates the executor.
    public init() {}

    /// Runs `work` on the caller.
    public func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        work()
    }
}

/// A fixed seed (ADR-024): every derived draw is a pure function of it, so a failing test replays from the printed
/// seed. A struct with no lock and no availability gate.
public struct SeededRandom: RandomSource {
    /// The seed.
    public let seed: UInt64

    /// Creates a source.
    public init(seed: UInt64) {
        self.seed = seed
    }
}

/// A fixed app version (R-SYN-9 tests).
public struct FakeAppVersionSource: AppVersionSource {
    /// The version returned.
    public let version: String

    /// Creates a source.
    public init(version: String = "1.0+1") {
        self.version = version
    }

    /// The fixed version.
    public func currentAppVersion() async -> String {
        self.version
    }
}

/// Hands the engine a prepared source (usually a `FakeRemoteSource`) instead of selecting a tier.
///
/// The engine calls it inside `start()`, right after the store opened, with the store's staging sink; a source that
/// is `StagingAttachable` receives that sink before it is returned, so its transfers write real staging files.
public struct FakeRemoteSourceFactory: RemoteSourceFactory {
    /// The source returned.
    public let source: any RemoteSource

    /// Creates a factory.
    public init(source: any RemoteSource) {
        self.source = source
    }

    /// Attaches `staging` to an attachable source, then returns the prepared source. The prepared source was built
    /// by the test, so `log` is not handed over (a fake source logs nothing).
    public func makeRemoteSource(
        configuration: RemoteConfiguration,
        staging: any StagingSink,
        log: LogRoute
    ) async throws(AssetError) -> any RemoteSource {
        if let attachable = self.source as? any StagingAttachable {
            await attachable.attach(staging: staging)
        }
        return self.source
    }
}

/// Reachability and power on demand (R-NET-9, R-SYN-13 tests). An actor: no lock, no availability gate.
///
/// Each `conditions()` call is one observation whose first element is the current state; `send` reaches every
/// live observation; a terminated observation is removed (one hop), and `activeObservers` is the census P-14
/// tests assert on. Because removal takes a hop, tests wait for it with `waitForObservers(equalTo:)`, which is
/// event-driven, never polled, and ends when its caller is cancelled (L2 follow-up; `requireObservers(equalTo:)`
/// throws then).
public actor FakeDeviceConditionsSource: DeviceConditionsSource, CensusWaiting {
    private var current: DeviceConditions
    private var observers: [UInt64: AsyncStream<DeviceConditions>.Continuation] = [:]
    private var nextObserver: UInt64 = 0
    /// Waits for a number of live observations (`CensusWaiting`).
    var censusWaiters = CensusWaiters()

    /// Creates a source with an initial state.
    public init(initial: DeviceConditions = .unrestricted) {
        self.current = initial
    }

    /// Starts one observation (`.bufferingNewest(1)`).
    public func conditions() -> AsyncStream<DeviceConditions> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceConditions.self, bufferingPolicy: .bufferingNewest(1))
        self.nextObserver += 1
        let id = self.nextObserver
        self.observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                // REENTRANCY: TS1 — nothing: this task is not the actor; removeObserver re-reads the table on the
                // actor, and a second removal of the same id is a no-op.
                await self?.removeObserver(id)
            }
        }
        continuation.yield(self.current)
        self.notifyCountWaiters()
        return stream
    }

    /// Publishes a new state to every live observation.
    public func send(_ conditions: DeviceConditions) {
        self.current = conditions
        for continuation in self.observers.values {
            continuation.yield(conditions)
        }
    }

    /// Live observations.
    public var activeObservers: Int {
        self.observers.count
    }

    /// Suspends until exactly `count` observations are live (returns at once if they are), or until the calling task
    /// is cancelled (a test past its time limit), when it returns with the census unchanged so the caller's following
    /// expectations fail instead of the run hanging. Event-driven: resumed by the registration or removal that reaches
    /// the count.
    public func waitForObservers(equalTo count: Int) async {
        // REENTRANCY: TS2 — nothing: a terminal wait (l2fu-1); no state is read afterwards.
        _ = await self.awaitCensus(target: count, met: { self.observers.count == $0 }, registered: nil)
    }

    /// Suspends until exactly `count` observations are live; throws `CancellationError` when the calling task is
    /// cancelled first, so a test past its time limit ends at once instead of running on with another census.
    public func requireObservers(equalTo count: Int) async throws(CancellationError) {
        // REENTRANCY: TS2 — nothing: a terminal wait (l2fu-1); no state is read afterwards.
        guard await self.awaitCensus(target: count, met: { self.observers.count == $0 }, registered: nil) else {
            throw CancellationError()
        }
    }

    /// Test seam for the wait itself: `true` once exactly `count` observations are live, `false` when the calling task
    /// was cancelled first; `registered` runs on the actor once the wait is registered.
    package func waitForObservers(equalTo count: Int, registered: @escaping @Sendable () -> Void) async -> Bool {
        // REENTRANCY: TS2 — nothing: a terminal wait (l2fu-1); no state is read afterwards.
        await self.awaitCensus(target: count, met: { self.observers.count == $0 }, registered: registered)
    }

    private func removeObserver(_ id: UInt64) {
        self.observers.removeValue(forKey: id)
        self.notifyCountWaiters()
    }

    private func notifyCountWaiters() {
        let live = self.observers.count
        self.censusWaiters.resume { $0 == live }
    }
}

/// Memory-pressure events on demand (R-CLN-11 tests). An actor: no lock, no availability gate. Same observation
/// semantics and census as `FakeDeviceConditionsSource`, without an initial element (pressure is an event, not a
/// state).
public actor FakeMemoryPressureSource: MemoryPressureSource, CensusWaiting {
    private var observers: [UInt64: AsyncStream<MemoryPressureLevel>.Continuation] = [:]
    private var nextObserver: UInt64 = 0
    /// Waits for a number of live observations (`CensusWaiting`).
    var censusWaiters = CensusWaiters()

    /// Creates a source with no observation.
    public init() {}

    /// Starts one observation (`.bufferingNewest(1)`).
    public func pressureEvents() -> AsyncStream<MemoryPressureLevel> {
        let (stream, continuation) = AsyncStream.makeStream(of: MemoryPressureLevel.self, bufferingPolicy: .bufferingNewest(1))
        self.nextObserver += 1
        let id = self.nextObserver
        self.observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                // REENTRANCY: TS1 — nothing: this task is not the actor; removeObserver re-reads the table on the
                // actor, and a second removal of the same id is a no-op.
                await self?.removeObserver(id)
            }
        }
        self.notifyCountWaiters()
        return stream
    }

    /// Delivers one event to every live observation.
    public func send(_ level: MemoryPressureLevel) {
        for continuation in self.observers.values {
            continuation.yield(level)
        }
    }

    /// Live observations (the engine's observer exists only while a cache is registered).
    public var activeObservers: Int {
        self.observers.count
    }

    /// Suspends until exactly `count` observations are live; event-driven. Returns with the census unchanged when the
    /// calling task is cancelled first (a test past its time limit), so the caller's following expectations fail.
    public func waitForObservers(equalTo count: Int) async {
        // REENTRANCY: TS2 — nothing: a terminal wait (l2fu-1); no state is read afterwards.
        _ = await self.awaitCensus(target: count, met: { self.observers.count == $0 }, registered: nil)
    }

    /// Suspends until exactly `count` observations are live; throws `CancellationError` when the calling task is
    /// cancelled first, so a test past its time limit ends at once.
    public func requireObservers(equalTo count: Int) async throws(CancellationError) {
        // REENTRANCY: TS2 — nothing: a terminal wait (l2fu-1); no state is read afterwards.
        guard await self.awaitCensus(target: count, met: { self.observers.count == $0 }, registered: nil) else {
            throw CancellationError()
        }
    }

    /// Test seam for the wait itself: `true` once exactly `count` observations are live, `false` when the calling task
    /// was cancelled first; `registered` runs on the actor once the wait is registered.
    package func waitForObservers(equalTo count: Int, registered: @escaping @Sendable () -> Void) async -> Bool {
        // REENTRANCY: TS2 — nothing: a terminal wait (l2fu-1); no state is read afterwards.
        await self.awaitCensus(target: count, met: { self.observers.count == $0 }, registered: registered)
    }

    private func removeObserver(_ id: UInt64) {
        self.observers.removeValue(forKey: id)
        self.notifyCountWaiters()
    }

    private func notifyCountWaiters() {
        let live = self.observers.count
        self.censusWaiters.resume { $0 == live }
    }
}
