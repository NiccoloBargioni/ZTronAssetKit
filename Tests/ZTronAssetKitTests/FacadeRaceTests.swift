import Foundation
import Testing
@testable import ZTronAssetKit
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Parks `ClientLifecycle` at a point of its test seam (`LifecycleSeamPoint`): the first `count` arrivals wait until
/// `open()`, later ones pass. The test's own waits end on its cancellation (the `CensusWaiting` pattern, ADR-050); a
/// parked arrival runs in the lifecycle's call, so a test always opens the hold before it can fail.
actor SeamHold {
    private var remaining: Int
    private var isOpen = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var waiters: [UInt64: (target: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var nextWaiterID: UInt64 = 0

    /// Holds the first `count` arrivals.
    init(holding count: Int = 1) {
        self.remaining = count
    }

    /// The seam: parks this arrival while holds remain and the hold is closed.
    func arrive() async {
        guard !self.isOpen, self.remaining > 0 else {
            return
        }
        self.remaining -= 1
        // REENTRANCY: nothing is re-read — a terminal wait, resumed once by `open()`.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.parked.append(continuation)
            self.notify()
        }
    }

    /// Suspends until `count` arrivals are parked, or until the caller is cancelled.
    func waitUntilParked(_ count: Int = 1) async {
        if self.parked.count >= count {
            return
        }
        self.nextWaiterID += 1
        let id = self.nextWaiterID
        // REENTRANCY: nothing is re-read — a terminal wait registered synchronously, resumed once by `notify()` or by
        // the cancellation hop (a no-op once resumed).
        await withTaskCancellationHandler {
            // REENTRANCY: as above.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if self.parked.count >= count || Task.isCancelled {
                    continuation.resume()
                } else {
                    self.waiters[id] = (count, continuation)
                }
            }
        } onCancel: {
            Task {
                await self.cancelWait(id)
            }
        }
    }

    /// Resumes every parked arrival; later arrivals pass.
    func open() {
        self.isOpen = true
        let parked = self.parked
        self.parked = []
        for continuation in parked {
            continuation.resume()
        }
    }

    private func cancelWait(_ id: UInt64) {
        self.waiters.removeValue(forKey: id)?.continuation.resume()
    }

    private func notify() {
        let count = self.parked.count
        for (id, waiter) in self.waiters where count >= waiter.target {
            self.waiters.removeValue(forKey: id)?.continuation.resume()
        }
    }
}

/// Interleavings of the facade's lifecycle placed deterministically through its test seam: a registration that lands
/// during shutdown, two reopens in a row, a memory-pressure stop during a reopen, and retention-scope changes racing
/// each other and a reopen.
@Suite("Facade races")
struct FacadeRaceTests {
    /// The prefetch groups the engine holds.
    static func prefetchGroups(_ engine: isolated SyncEngine) -> Int {
        engine.state.groups.values.filter { $0.kind == .prefetch }.count
    }

    /// The engine registered the group, then `shutdown()` ran before the lifecycle re-validated: the client never
    /// holds that group, so `awaitRegistration()` reports `.shutDown` (ARCHITECTURE §8), not a success.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: a prefetch whose engine registration lands while the client shuts down reports shutDown", .timeLimit(.minutes(1)))
    func registrationOverlappingShutdown() async throws {
        let harness = KitHarness.make()
        try await harness.startAndSettle()
        let client = harness.client
        let engine = await harness.engine()
        let hold = SeamHold()
        await client.lifecycle.setSeam { point in
            if case .registrationAnswered = point {
                await hold.arrive()
            }
        }
        let handle = client.prefetch(["a"])
        await hold.waitUntilParked()
        let registered = await engine.kitRead { FacadeRaceTests.prefetchGroups($0) }
        await client.shutdown()
        await hold.open()
        #expect(registered == 1, "setup: the engine registered the group before the shutdown")
        await #expect(throws: AssetError.shutDown) {
            try await handle.awaitRegistration()
        }
        #expect(await engine.introspect().groups == 0, "the shut-down engine holds no group")
    }

    /// Reopen A (generation 0 → 1) parks while re-registering the first group; generation 1's root vanishes too, and
    /// reopen B (1 → 2) leaves the parked group to its bind and registers the second with generation 2. When A
    /// resumes, its bind follows the first group to generation 2, and A's loop must not register the second group
    /// again: that copy's token would never be released, so generation 2 would keep the group's interest for life.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-11: two reopens in a row leave each prefetch group registered once with the newest engine", .timeLimit(.minutes(1)))
    func backToBackReopensRegisterOnce() async throws {
        let harness = KitHarness.make()
        let client = harness.client
        try await harness.startAndSettle()
        let first = client.prefetch(["g1"])
        let second = client.prefetch(["g2"])
        try await first.awaitRegistration()
        try await second.awaitRegistration()
        let hold = SeamHold()
        await client.lifecycle.setSeam { point in
            if case .registrationAnswered = point {
                await hold.arrive()
            }
        }
        try await harness.withClock { () async throws -> Void in
            try harness.vanishRoot()
            let reopenA = Task { () -> Result<PurgeResult, AssetError> in
                do throws(AssetError) {
                    return .success(try await client.purge(.all))
                } catch {
                    return .failure(error)
                }
            }
            await hold.waitUntilParked()
            let afterA = await client.lifecycle.current().generation
            // Generation 1 opens its store; its root vanishes as well, and the next mutating call runs reopen B.
            var failuresB: [AssetError] = []
            do throws(AssetError) {
                try await client.start()
            } catch {
                failuresB.append(error)
            }
            try harness.vanishRoot()
            do throws(AssetError) {
                _ = try await client.purge(.all)
            } catch {
                failuresB.append(error)
            }
            let afterB = await client.lifecycle.current().generation
            await hold.open()
            let resultA = await reopenA.value
            #expect(afterA == 1, "reopen A installed generation 1 before its loop parked")
            #expect(afterB == 2 && failuresB.isEmpty, "reopen B installed generation 2 while A was parked: \(afterB), \(failuresB)")
            #expect((try? resultA.get()) != nil, "A's purge was repeated on the newest engine: \(resultA)")
        }
        let engine = await harness.engine()
        let groups = await engine.kitRead { FacadeRaceTests.prefetchGroups($0) }
        #expect(groups == 2, "each live group is registered once with generation 2, got \(groups)")
        first.cancel()
        second.cancel()
        await engine.awaitCondition { FacadeRaceTests.prefetchGroups($0) == 0 }
        #expect(await engine.kitRead { FacadeRaceTests.prefetchGroups($0) } == 0, "releasing both handles leaves no group behind")
        await client.shutdown()
    }

    /// A memory warning while a reopen is about to shut the old engine down: the old engine's observer runs the facade's
    /// handler, which finds the only cache gone and stops the observer through the lifecycle. The reopen's first step,
    /// the old engine's shutdown, joins that observer, so the lifecycle must not make the handler wait for the reopen;
    /// before round 2 it did (in `current()`), and the observer waited for the reopen, the reopen for the shutdown and the
    /// shutdown for the observer, for good. The purge that met the replaced root is awaited only once generation 0 is
    /// shut down, so the test fails at its time limit instead of hanging.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CLN-11: a pressure event whose handler stops the observer while a reopen shuts that engine down leaves neither waiting for the other", .timeLimit(.minutes(1)))
    func pressureStopDuringReopen() async throws {
        let harness = KitHarness.make()
        let client = harness.client
        try await harness.startAndSettle()
        // A cache registered (epoch 1) and gone without unregistering: the next event's handler stops the observer.
        try await MainActor.run {
            let cache = RecordingCache()
            try client.register(cache)
        }
        try await harness.pressure.requireObservers(equalTo: 1)
        let old = await harness.engine()
        let reopenHold = SeamHold()
        let (recorded, record) = AsyncStream.makeStream(of: UInt64.self)
        await client.lifecycle.setSeam { point in
            switch point {
            case .reopenWillShutDownEngine:
                await reopenHold.arrive()
            case .pressureRecorded(let epoch):
                record.yield(epoch)
            case .registrationAnswered, .shutdownWillWaitForReopen, .replacementObservesPressure, .replacementBuilt:
                break
            }
        }
        try harness.vanishRoot()
        let purge = Task { () -> Result<PurgeResult, AssetError> in
            do throws(AssetError) {
                return .success(try await harness.withClock { () throws(AssetError) -> PurgeResult in
                    try await client.purge(.all)
                })
            } catch {
                return .failure(error)
            }
        }
        await reopenHold.waitUntilParked()
        // A caller asking for the current pair now waits for the reopen and gets its replacement.
        let lifecycle = client.lifecycle
        let pairDuringReopen = Task { await lifecycle.current().generation }
        // The reopen is running and generation 0 still serves: its observer takes the event and runs the handler.
        await harness.pressure.send(.warning)
        var epochs = recorded.makeAsyncIterator()
        let stopEpoch = await epochs.next()
        #expect(stopEpoch == 2, "the handler's stop was recorded with epoch 2, got \(String(describing: stopEpoch))")
        await reopenHold.open()
        await old.waitUntil { $0.lifecycle == .shutDown }
        guard await old.introspect().lifecycle == .shutDown else {
            Issue.record("the reopen's shutdown of generation 0 never finished: its pressure observer waits for the reopen")
            return
        }
        let result = await purge.value
        #expect((try? result.get()) != nil, "the purge was repeated on the replacement: \(result)")
        #expect(await client.lifecycle.current().generation == 1, "setup: one reopen")
        #expect(await pairDuringReopen.value == 1, "a caller during the reopen was handed the replacement")
        try await harness.pressure.requireObservers(equalTo: 0)
        let engine = await harness.engine()
        #expect(await engine.introspect().memoryPressureObserverActive == false, "the recorded stop holds on the replacement")
        // The relay and the lifecycle still agree: a cache registered now starts the replacement's observer.
        let kept = await MainActor.run { RecordingCache() }
        try await MainActor.run {
            try client.register(kept)
        }
        try await harness.pressure.requireObservers(equalTo: 1)
        #expect(await engine.introspect().memoryPressureObserverActive, "a new registration starts the replacement's observer")
        await client.shutdown()
    }

    /// `shutdown()` while a reopen runs: the shutdown waits for the reopen, which finds the client closed once the old
    /// engine is shut down and builds nothing (G-1); the call that met the replaced root and the calls that waited for
    /// the reopen report `.shutDown`, and generation 0 stays the last pair.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: a shutdown during a reopen builds no replacement, and the calls waiting for the reopen report shutDown", .timeLimit(.minutes(1)))
    func shutdownDuringReopen() async throws {
        let harness = KitHarness.make()
        let client = harness.client
        try await harness.startAndSettle()
        let old = await harness.engine()
        let reopenHold = SeamHold()
        let (shutdownWaits, signal) = AsyncStream.makeStream(of: Void.self)
        await client.lifecycle.setSeam { point in
            switch point {
            case .reopenWillShutDownEngine:
                await reopenHold.arrive()
            case .shutdownWillWaitForReopen:
                signal.yield()
            case .registrationAnswered, .pressureRecorded, .replacementObservesPressure, .replacementBuilt:
                break
            }
        }
        try harness.vanishRoot()
        let purge = Task { () -> Result<PurgeResult, AssetError> in
            do throws(AssetError) {
                return .success(try await harness.withClock { () throws(AssetError) -> PurgeResult in
                    try await client.purge(.all)
                })
            } catch {
                return .failure(error)
            }
        }
        await reopenHold.waitUntilParked()
        // Calls made while the reopen runs wait for it (the scope's request may also meet the shutdown at its entry).
        let lifecycle = client.lifecycle
        let pairDuringReopen = Task { await lifecycle.current().generation }
        let scopeDuringReopen = Task { await lifecycle.setRetentionScope(.tags(["late"])) }
        let shutdown = Task {
            await client.shutdown()
        }
        var waits = shutdownWaits.makeAsyncIterator()
        _ = await waits.next()
        await reopenHold.open()
        await shutdown.value
        let result = await purge.value
        var reportedShutDown = false
        if case .failure(.shutDown) = result {
            reportedShutDown = true
        }
        #expect(reportedShutDown, "the call that met the replaced root reports shutDown: \(result)")
        var scopeShutDown = false
        if case .failure(.shutDown) = await scopeDuringReopen.value {
            scopeShutDown = true
        }
        #expect(scopeShutDown, "a scope change waiting for the reopen reports shutDown")
        #expect(await pairDuringReopen.value == 0, "no replacement was built: the caller got the last pair")
        #expect(await client.lifecycle.current().generation == 0, "generation 0 stays the last pair")
        #expect(await old.introspect().lifecycle == .shutDown)
        await #expect(throws: AssetError.shutDown) {
            try await client.pin(["a"])
        }
    }

    /// L5-R13 (G-16): an `events` stream registers on its first pull and becomes a follower in that turn. A first pull
    /// made while a reopen is parked after building its replacement registers with the retired engine, which answers
    /// `.shutDown`, so the registration waits for the reopen, whose hand-over covers the follower. The consumer is
    /// cancelled meanwhile: the forwarder drops the stream it is handed, and gives its follower entry back once the
    /// registration returns, so neither the lifecycle nor the replacement keeps anything for it. `cancel()` runs the
    /// forwarder's `stop()` in a task of its own, so the test waits for its end (the forwarder's `stopped` seam) before it
    /// lets the reopen go on: the registration then returns to a stopped forwarder in every schedule, and the consumer
    /// receives nothing (L5-R21, L5-C2-05; before, a late stop let the pump hand the replacement's first event to the
    /// cancelled pull).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: an events stream cancelled while its first registration waits for a reopen leaves no follower and no subscriber", .timeLimit(.minutes(1)))
    func eventsStreamCancelledDuringItsRegistration() async throws {
        let harness = KitHarness.make()
        let client = harness.client
        try await harness.startAndSettle()
        let followers = FollowerGauge()
        await client.lifecycle.setFollowerObserver { count, recorded in
            followers.set(count, recorded: recorded)
        }
        let hold = SeamHold()
        await client.lifecycle.setSeam { point in
            if case .replacementBuilt = point {
                await hold.arrive()
            }
        }
        try harness.vanishRoot()
        let purge = Task { () -> Result<PurgeResult, AssetError> in
            do throws(AssetError) {
                return .success(try await harness.withClock { () throws(AssetError) -> PurgeResult in
                    try await client.purge(.all)
                })
            } catch {
                return .failure(error)
            }
        }
        await hold.waitUntilParked()
        // `client.events` with the forwarder's `stopped` seam.
        let (stops, stopped) = AsyncStream<Void>.makeStream()
        let stream = EventForwarder.stream(lifecycle: client.lifecycle, stopped: { stopped.yield() })
        let consumer = Task { () -> Int in
            var received = 0
            for await _ in stream {
                received += 1
            }
            return received
        }
        // The first pull recorded the follower; its registration waits for the parked reopen.
        await followers.wait(atLeast: 1)
        consumer.cancel()
        for await _ in stops {
            break
        }
        await hold.open()
        let received = await consumer.value
        let result = await purge.value
        #expect((try? result.get()) != nil, "setup: the purge was repeated on the replacement: \(result)")
        #expect(received == 0, "the cancelled consumer received nothing: \(received)")
        #expect(followers.count == 0, "the follower entry was given back once the registration returned")
        let replacement = await client.lifecycle.current()
        #expect(replacement.generation == 1, "setup: one reopen")
        await replacement.engine.waitUntil { $0.subscribers == 0 }
        #expect(await replacement.engine.introspect().subscribers == 0, "the stream handed to the stopped forwarder was released")
        await client.shutdown()
    }

    /// L5-R2's reopen path (L5-V3-05, PROBE-2): the reopen applies the newest memory-pressure request to its replacement
    /// while it is still `created`, so a `shutdown()` before the replacement's start shuts a `created` engine down that
    /// owns an observer. The reopen parks right after that request (`replacementObservesPressure`); the shutdown must
    /// still cancel and join the replacement's observer before it returns.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: a shutdown after a reopen applied the memory-pressure request to its unstarted replacement leaves no owned task and no observation", .timeLimit(.minutes(1)))
    func shutdownBeforeReplacementStart() async throws {
        let harness = KitHarness.make()
        let client = harness.client
        try await harness.startAndSettle()
        let cache = await MainActor.run { RecordingCache() }
        try await MainActor.run {
            try client.register(cache)
        }
        try await harness.pressure.requireObservers(equalTo: 1)
        let hold = SeamHold()
        await client.lifecycle.setSeam { point in
            if case .replacementObservesPressure = point {
                await hold.arrive()
            }
        }
        try harness.vanishRoot()
        let purge = Task { () -> Result<PurgeResult, AssetError> in
            do throws(AssetError) {
                return .success(try await harness.withClock { () throws(AssetError) -> PurgeResult in
                    try await client.purge(.all)
                })
            } catch {
                return .failure(error)
            }
        }
        await hold.waitUntilParked()
        let replacement = await client.lifecycle.current()
        let before = await replacement.engine.introspect()
        #expect(replacement.generation == 1, "setup: the reopen installed generation 1")
        #expect(before.lifecycle == .created && before.memoryPressureObserverActive, "setup: the unstarted replacement observes memory pressure: \(before)")
        try await harness.pressure.requireObservers(equalTo: 1)
        await client.shutdown()
        let after = await replacement.engine.introspect()
        await hold.open()
        let result = await purge.value
        #expect(after.lifecycle == .shutDown)
        #expect(after.ownedTasks == 0, "no owned task of the replacement outlives shutdown: \(after.ownedTasks)")
        #expect(!after.memoryPressureObserverActive, "the replacement's observer was stopped")
        var reportedShutDown = false
        if case .failure(.shutDown) = result {
            reportedShutDown = true
        }
        #expect(reportedShutDown, "the call that met the replaced root reports shutDown: \(result)")
        guard after.ownedTasks == 0 else {
            // The leftover observer ends only at the next event; end it so nothing outlives the test.
            await harness.pressure.send(.warning)
            return
        }
        try await harness.pressure.requireObservers(equalTo: 0)
        withExtendedLifetime(cache) {}
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-5: the retention scope set through the client is the replacement engine's after a reopen", .timeLimit(.minutes(1)))
    func retentionScopeSurvivesReopen() async throws {
        let harness = KitHarness.make()
        let client = harness.client
        try await harness.startAndSettle()
        let scope = AssetScope.tags(["paid"])
        try await client.setRetentionScope(scope)
        #expect(await harness.engine().kitRead { $0.state.retentionScope } == scope)
        try harness.vanishRoot()
        _ = try await harness.withClock { () throws(AssetError) -> PurgeResult in
            try await client.purge(.all)
        }
        #expect(await client.lifecycle.current().generation == 1, "setup: one reopen")
        #expect(await harness.engine().kitRead { $0.state.retentionScope } == scope, "the replacement engine serves the caller's scope")
        await client.shutdown()
    }

    /// Calls from tasks of mixed priority reach the engine in any order; the lifecycle records each request before
    /// applying it and applies the newest again when an older one landed last, so once every call returned the
    /// engine and the record agree, and a reopen does not change the scope in force.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-5: concurrent retention scope changes leave the engine on the newest recorded scope, which a reopen keeps", .timeLimit(.minutes(1)))
    func concurrentRetentionScopesConverge() async throws {
        let harness = KitHarness.make()
        let client = harness.client
        try await harness.startAndSettle()
        let failures = await withTaskGroup(of: AssetError?.self) { group in
            for index in 0..<48 {
                group.addTask(priority: index.isMultiple(of: 2) ? .low : .high) {
                    do throws(AssetError) {
                        try await client.setRetentionScope(.tags(["t\(index)"]))
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            var failures: [AssetError] = []
            for await failure in group {
                if let failure {
                    failures.append(failure)
                }
            }
            return failures
        }
        #expect(failures.isEmpty, "every call succeeded: \(failures)")
        let applied = await harness.engine().kitRead { $0.state.retentionScope }
        let recorded = await client.lifecycle.recordedRetentionScope
        #expect(applied == recorded, "the engine serves the newest recorded scope: \(applied) vs \(recorded)")
        try harness.vanishRoot()
        _ = try await harness.withClock { () throws(AssetError) -> PurgeResult in
            try await client.purge(.all)
        }
        #expect(await client.lifecycle.current().generation == 1, "setup: one reopen")
        #expect(await harness.engine().kitRead { $0.state.retentionScope } == applied, "the reopen kept the scope in force")
        await client.shutdown()
    }
}
