import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetTransport

/// R-NET-9: the live conditions source, event-driven: the current state first, then one full snapshot per change,
/// and nothing observed once the stream is terminated (R-SYN-14).
@Suite("Live device conditions")
struct ConditionsTests {
    /// A path observer the test drives: `send` delivers on the observation's queue, as `NWPathMonitor` does.
    @available(macOS 15.0, *)
    final class ScriptedPath: PathObserving {
        private struct State {
            var current: NetworkConditions
            var queue: DispatchQueue?
            var update: (@Sendable (NetworkConditions) -> Void)?
            var cancelled = false
            var reads = 0
        }

        private let state: Mutex<State>
        private let onStart: @Sendable () -> Void

        /// `onStart` runs inside `start`, before the first delivery is queued: what happens as observation begins.
        init(_ initial: NetworkConditions, onStart: @escaping @Sendable () -> Void = {}) {
            self.state = Mutex(State(current: initial))
            self.onStart = onStart
        }

        func start(queue: DispatchQueue, onUpdate: @escaping @Sendable (NetworkConditions) -> Void) {
            let current = self.state.withLock { state in
                state.queue = queue
                state.update = onUpdate
                return state.current
            }
            self.onStart()
            queue.async { onUpdate(current) }
        }

        var current: NetworkConditions {
            self.state.withLock { state in
                state.reads += 1
                return state.current
            }
        }

        /// How often the observation read `current` (only a notification needs it).
        var reads: Int {
            self.state.withLock { $0.reads }
        }

        func cancel() {
            self.state.withLock { $0.cancelled = true }
        }

        var isCancelled: Bool {
            self.state.withLock { $0.cancelled }
        }

        /// A path change.
        func send(_ conditions: NetworkConditions) {
            let (queue, update) = self.state.withLock { state in
                state.current = conditions
                return (state.queue, state.update)
            }
            if let queue, let update {
                queue.async { update(conditions) }
            }
        }
    }

    /// The live `NWPathMonitor` observer, wrapped to count its deliveries: the host's network may report a change
    /// at any time, so a test counts what was delivered instead of assuming nothing was.
    @available(macOS 15.0, *)
    final class CountingPath: PathObserving {
        private let inner: any PathObserving
        private let queue = Mutex<DispatchQueue?>(nil)
        private let deliveries = ReadCounter()

        init(_ inner: any PathObserving) {
            self.inner = inner
        }

        func start(queue: DispatchQueue, onUpdate: @escaping @Sendable (NetworkConditions) -> Void) {
            self.queue.withLock { $0 = queue }
            self.inner.start(queue: queue) { [deliveries] network in
                deliveries.increment()
                onUpdate(network)
            }
        }

        var current: NetworkConditions {
            self.inner.current
        }

        func cancel() {
            self.inner.cancel()
        }

        /// The deliveries so far and `read()`, both taken on the observation's serial queue, where every delivery
        /// and every notification runs: no event is half-way through while they are read.
        func settled<T>(_ read: () -> T) -> (deliveries: Int, value: T) {
            guard let queue = self.queue.withLock({ $0 }) else {
                return (0, read())
            }
            return queue.sync {
                (self.deliveries.count, read())
            }
        }
    }

    /// Counts calls from any thread.
    @available(macOS 15.0, *)
    final class ReadCounter: Sendable {
        private let value = Mutex(0)

        func increment() {
            self.value.withLock { $0 += 1 }
        }

        var count: Int {
            self.value.withLock { $0 }
        }
    }

    @available(macOS 15.0, *)
    @Test("R-NET-9: the live conditions source yields the current state first, then on change, without polling", .timeLimit(.minutes(1)))
    func liveSourceIsEventDriven() async throws {
        let center = NotificationCenter()
        // The live path monitor and the live power reading, each counted: an observation that polled would read
        // power more often than events arrive.
        let path = CountingPath(LiveDeviceConditionsSource.livePathObserver())
        let reads = ReadCounter()
        let source = LiveDeviceConditionsSource(center: center, makePathObserver: { path }, power: {
            reads.increment()
            return LiveDeviceConditionsSource.processPower()
        })
        let stream = await source.conditions()
        var iterator = stream.makeAsyncIterator()
        let first = try #require(await iterator.next())
        let info = ProcessInfo.processInfo
        #expect(first.power == PowerConditions(lowPowerMode: info.isLowPowerModeEnabled, thermal: ConditionsMapping.thermal(info.thermalState)))
        // Each post on the injected center yields one full snapshot; no time passes and nothing polls.
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        let second = try #require(await iterator.next())
        #expect(second.power == first.power)
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        let third = try #require(await iterator.next())
        #expect(third.network == second.network)
        #expect(await source.activeObservations == 1)
        // One power reading per event and none in between: the path's deliveries (at least the first, more only if
        // the host's network changed meanwhile) plus the two posts.
        let settled = path.settled { reads.count }
        #expect(settled.deliveries >= 1)
        #expect(settled.value == settled.deliveries + 2)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-9: path changes reach the stream as full snapshots, power notifications carry the current path, and nothing is read between changes", .timeLimit(.minutes(1)))
    func pathSeam() async throws {
        let center = NotificationCenter()
        let wifi = NetworkConditions(satisfied: true, expensive: false, constrained: false)
        let cellular = NetworkConditions(satisfied: true, expensive: true, constrained: true)
        let path = ScriptedPath(wifi)
        let power = PowerConditions(lowPowerMode: true, thermal: .serious)
        // Every power reading is counted: an observation that polled would read more often than things change.
        let reads = ReadCounter()
        let source = LiveDeviceConditionsSource(center: center, makePathObserver: { path }, power: {
            reads.increment()
            return power
        })
        var iterator = await source.conditions().makeAsyncIterator()
        #expect(await iterator.next() == DeviceConditions(network: wifi, power: power))
        path.send(cellular)
        #expect(await iterator.next() == DeviceConditions(network: cellular, power: power))
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        #expect(await iterator.next() == DeviceConditions(network: cellular, power: power))
        // Another center's notifications are not observed.
        NotificationCenter().post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        path.send(wifi)
        #expect(await iterator.next() == DeviceConditions(network: wifi, power: power))
        // One reading for the first element, one per path change (2) and one per notification on `center` (1).
        #expect(reads.count == 4)
        #expect(path.reads == 1)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-9: the first element is the path observer's first delivery, even when a notification arrives as observation starts", .timeLimit(.minutes(1)))
    func pathStartsBeforeNotifications() async throws {
        let center = NotificationCenter()
        let wifi = NetworkConditions(satisfied: true, expensive: false, constrained: false)
        // A thermal notification delivered the moment the path observer starts, before its first delivery: had the
        // notification observers been registered first, it would read a path that has not reported yet.
        let path = ScriptedPath(wifi) {
            center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        }
        let power = PowerConditions(lowPowerMode: false, thermal: .fair)
        let reads = ReadCounter()
        let source = LiveDeviceConditionsSource(center: center, makePathObserver: { path }, power: {
            reads.increment()
            return power
        })
        var iterator = await source.conditions().makeAsyncIterator()
        #expect(await iterator.next() == DeviceConditions(network: wifi, power: power))
        // Nothing read the path before it reported, and the only power reading is the first element's.
        #expect(path.reads == 0)
        #expect(reads.count == 1)
        // Notifications registered after the start are observed as usual.
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        #expect(await iterator.next() == DeviceConditions(network: wifi, power: power))
        #expect(path.reads == 1 && reads.count == 2)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-9: terminating the conditions stream stops path monitoring and removes the observers", .timeLimit(.minutes(1)))
    func terminationStopsObservation() async throws {
        let center = NotificationCenter()
        let path = ScriptedPath(NetworkConditions(satisfied: false, expensive: false, constrained: false))
        let source = LiveDeviceConditionsSource(center: center, makePathObserver: { path })
        // Nothing is observed before `conditions()`.
        await source.waitForObservations(equalTo: 0)
        let consumer = Task {
            var count = 0
            for await _ in await source.conditions() {
                count += 1
            }
            return count
        }
        await source.waitForObservations(equalTo: 1)
        consumer.cancel()
        await source.waitForObservations(equalTo: 0)
        #expect(path.isCancelled)
        #expect(await consumer.value <= 1)
        // A second observation is independent and starts from the current state.
        var iterator = await source.conditions().makeAsyncIterator()
        #expect(await iterator.next()?.network.satisfied == false)
        #expect(await source.activeObservations == 1)
    }
}
