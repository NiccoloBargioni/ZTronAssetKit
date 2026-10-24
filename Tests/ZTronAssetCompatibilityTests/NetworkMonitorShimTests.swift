import Foundation
import Synchronization
import Testing
import ZTronAssetKit
import ZTronAssetTestSupport

/// The retries that ran, in order, and a stream that reports each run, so a test waits for a run without polling.
@available(macOS 15.0, iOS 18.0, *)
final class RetryLog: Sendable {
    private let runs = Mutex<[Int]>([])
    private let signal: AsyncStream<Int>.Continuation
    /// One element per run.
    let ran: AsyncStream<Int>

    init() {
        (self.ran, self.signal) = AsyncStream.makeStream(of: Int.self)
    }

    /// A retry that records `label`.
    func retry(_ label: Int) -> @Sendable () -> Void {
        { [self] in
            self.runs.withLock { $0.append(label) }
            self.signal.yield(label)
        }
    }

    /// Every label recorded so far.
    var recorded: [Int] {
        self.runs.withLock { $0 }
    }
}

/// R-CAR-6: `NetworkAvailabilityMonitor` over the module's reachability seam (RECON §5: connectivity retry for failed
/// on-demand fetches; `ZTronSVGView.swift:168-183`).
@Suite("Compatibility shims: network availability monitor")
struct NetworkMonitorShimTests {
    /// No usable path.
    static let offline = DeviceConditions(
        network: NetworkConditions(satisfied: false, expensive: false, constrained: false),
        power: DeviceConditions.unrestricted.power
    )

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-6: a retry registered while offline runs once connectivity returns, and only once", .timeLimit(.minutes(1)))
    func retryRunsWhenConnectivityReturns() async throws {
        let conditions = FakeDeviceConditionsSource(initial: NetworkMonitorShimTests.offline)
        let monitor = NetworkAvailabilityMonitor(conditions: conditions)
        let log = RetryLog()
        var runs = log.ran.makeAsyncIterator()

        let first = monitor.retryWhenAvailable(log.retry(1))
        #expect(await monitor.flush() == 1)
        try await conditions.requireObservers(equalTo: 1)
        #expect(log.recorded.isEmpty, "every report so far said offline")

        await conditions.send(.unrestricted)
        #expect(await runs.next() == 1)
        #expect(await monitor.flush() == 0, "a retry that ran is cleared")

        let second = monitor.retryWhenAvailable(log.retry(2))
        #expect(await monitor.flush() == 1)
        await conditions.send(NetworkMonitorShimTests.offline)
        await conditions.send(.unrestricted)
        #expect(await runs.next() == 2)
        #expect(log.recorded == [1, 2], "the first retry did not run again")
        #expect(first != second)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-6: a cancelled retry never runs, and cancelling a token that already ran or was cancelled changes nothing", .timeLimit(.minutes(1)))
    func cancelledRetryNeverRuns() async throws {
        let conditions = FakeDeviceConditionsSource(initial: NetworkMonitorShimTests.offline)
        let monitor = NetworkAvailabilityMonitor(conditions: conditions)
        let log = RetryLog()
        var runs = log.ran.makeAsyncIterator()

        let cancelled = monitor.retryWhenAvailable(log.retry(1))
        let kept = monitor.retryWhenAvailable(log.retry(2))
        monitor.cancelRetry(cancelled)
        #expect(await monitor.flush() == 1)
        try await conditions.requireObservers(equalTo: 1)

        await conditions.send(.unrestricted)
        #expect(await runs.next() == 2)
        // Pending retries run together, in registration order: had the cancelled one been pending, it would be first.
        #expect(log.recorded == [2])

        monitor.cancelRetry(kept)
        monitor.cancelRetry(cancelled)
        #expect(await monitor.flush() == 0)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-6: a retry registered while the client is idle still runs when connectivity returns", .timeLimit(.minutes(1)))
    func retryRunsWhileTheClientIsIdle() async throws {
        let iconBytes = CompatFixture.bytes(30)
        let icon = CompatFixture.asset("bo7.ri.icon", iconBytes)
        let harness = CompatHarness.make()
        await harness.serve([(icon, iconBytes)])
        try await harness.settleLaunch()
        // The launch run is over: the client has no work, so its engine observes nothing (R-SYN-14). This is the prior
        // art's moment: an on-demand fetch failed and the view registers a retry for when the network comes back.
        try await harness.conditions.requireObservers(equalTo: 0)
        await harness.conditions.send(NetworkMonitorShimTests.offline)
        let monitor = NetworkAvailabilityMonitor(conditions: harness.conditions)
        let log = RetryLog()
        var runs = log.ran.makeAsyncIterator()
        monitor.retryWhenAvailable(log.retry(1))
        #expect(await monitor.flush() == 1)
        try await harness.conditions.requireObservers(equalTo: 1)
        #expect(log.recorded.isEmpty)

        await harness.conditions.send(.unrestricted)

        #expect(await runs.next() == 1)
        await harness.client.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-6: a monitor observes nothing until a retry is registered, and its first report counts as the prior art's initial path update", .timeLimit(.minutes(1)))
    func firstReportCounts() async throws {
        let conditions = FakeDeviceConditionsSource(initial: .unrestricted)
        let monitor = NetworkAvailabilityMonitor(conditions: conditions)
        let log = RetryLog()
        var runs = log.ran.makeAsyncIterator()
        #expect(await monitor.flush() == 0)
        #expect(await conditions.activeObservers == 0, "inert until used")

        monitor.retryWhenAvailable(log.retry(1))
        #expect(await runs.next() == 1, "the first report says satisfied")

        monitor.retryWhenAvailable(log.retry(2))
        #expect(await monitor.flush() == 1)
        #expect(log.recorded == [1], "a later retry waits for the next report")
        await conditions.send(.unrestricted)
        #expect(await runs.next() == 2)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-6: releasing a monitor ends its observation", .timeLimit(.minutes(1)))
    func releasedMonitorStopsObserving() async throws {
        let conditions = FakeDeviceConditionsSource(initial: NetworkMonitorShimTests.offline)
        var monitor: NetworkAvailabilityMonitor? = NetworkAvailabilityMonitor(conditions: conditions)
        let log = RetryLog()
        monitor?.retryWhenAvailable(log.retry(1))
        #expect(await monitor?.flush() == 1)
        try await conditions.requireObservers(equalTo: 1)

        monitor = nil

        try await conditions.requireObservers(equalTo: 0)
        #expect(log.recorded.isEmpty)
    }
}
