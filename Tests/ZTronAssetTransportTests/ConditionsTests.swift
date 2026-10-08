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

        init(_ initial: NetworkConditions) {
            self.state = Mutex(State(current: initial))
        }

        func start(queue: DispatchQueue, onUpdate: @escaping @Sendable (NetworkConditions) -> Void) {
            let current = self.state.withLock { state in
                state.queue = queue
                state.update = onUpdate
                return state.current
            }
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

    @Test("R-NET-9: the live conditions source yields the current state first, then on change, without polling", .timeLimit(.minutes(1)))
    func liveSourceIsEventDriven() async throws {
        let center = NotificationCenter()
        let source = LiveDeviceConditionsSource(center: center)
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
