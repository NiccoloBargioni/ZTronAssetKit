import Foundation
import Synchronization
import Testing
@testable import ZTronAssetKit
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

// Close-out cycle 2, correctness lens: the verifier's own probes (scratch only, never committed).

/// Every event a reading consumer received, with condition waits that end on cancellation.
@available(macOS 15.0, iOS 18.0, *)
actor ProbeLog {
    private(set) var events: [AssetEvent] = []
    private(set) var ended = false
    private var waiters: [UInt64: (met: @Sendable ([AssetEvent], Bool) -> Bool, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var last: UInt64 = 0

    func append(_ event: AssetEvent) {
        self.events.append(event)
        self.notify()
    }

    func end() {
        self.ended = true
        self.notify()
    }

    private func notify() {
        let waiting = self.waiters
        for (id, waiter) in waiting where waiter.met(self.events, self.ended) {
            self.waiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    func wait(until met: @escaping @Sendable ([AssetEvent], Bool) -> Bool) async {
        if met(self.events, self.ended) {
            return
        }
        self.last += 1
        let id = self.last
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if met(self.events, self.ended) || Task.isCancelled {
                    continuation.resume()
                } else {
                    self.waiters[id] = (met, continuation)
                }
            }
        } onCancel: {
            Task {
                await self.cancelWait(id)
            }
        }
    }

    private func cancelWait(_ id: UInt64) {
        self.waiters.removeValue(forKey: id)?.continuation.resume()
    }
}

/// Cores a seam saw.
@available(macOS 15.0, iOS 18.0, *)
actor CoreBox {
    private(set) var cores: [ClientCore] = []

    func add(_ core: ClientCore) {
        self.cores.append(core)
    }
}

/// A one-shot signal with a cancellable wait.
@available(macOS 15.0, iOS 18.0, *)
actor ProbeSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        self.fired = true
        let waiting = self.waiters
        self.waiters = []
        waiting.forEach { $0.resume() }
    }

    func wait() async {
        if self.fired {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.waiters.append(continuation)
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
enum Probes {
    static func onDemand(_ id: String, _ seed: UInt64) -> (ManifestEntry, Data) {
        let bytes = KitFixture.bytes(seed, count: 64)
        return (KitFixture.entry(id, bytes, policy: .onDemand), bytes)
    }

    static func harness(_ entries: [(ManifestEntry, Data)]) async -> KitHarness {
        let harness = KitHarness.make()
        let manifest = KitFixture.manifestData(entries.map(\.0))
        await harness.source.scriptManifest((0..<24).map { .fetched(manifest, etag: KitFixture.etag("p\($0)")) })
        return harness
    }

    static func read(_ stream: AsyncStream<AssetEvent>, into log: ProbeLog) -> Task<Void, Never> {
        Task {
            for await event in stream {
                await log.append(event)
            }
            await log.end()
        }
    }

    static func isAvailable(_ event: AssetEvent, _ id: AssetID) -> Bool {
        if case .assetAvailable(let subject, _) = event, subject == id {
            return true
        }
        return false
    }

    static func isStarted(_ event: AssetEvent) -> Bool {
        if case .clientStarted = event {
            return true
        }
        return false
    }

    /// Replaces the root and lets `purge(.all)` reopen; returns the pair serving afterwards.
    static func reopen(_ harness: KitHarness) async throws -> ClientCore {
        try harness.vanishRoot()
        let client = harness.client
        _ = try await harness.withClock { () throws(AssetError) -> PurgeResult in
            try await client.purge(.all)
        }
        return await client.lifecycle.current()
    }

    static func resolve(_ harness: KitHarness, _ entry: (ManifestEntry, Data)) async throws {
        await harness.source.script(entry.0.transferID, [.stage(entry.1)])
        let client = harness.client
        let id = entry.0.identifier
        _ = try await harness.withClock { () throws(AssetError) -> URL in
            try await client.resolve(id)
        }
    }

    static func launchGeneration(_ core: ClientCore) async -> UInt64? {
        await core.engine.kitRead { $0.state.launch?.report.generation }
    }

    static func drain(_ iterator: inout AsyncStream<AssetEvent>.Iterator) async -> [AssetEvent] {
        var events: [AssetEvent] = []
        while let event = await iterator.next() {
            events.append(event)
        }
        return events
    }

    static func endsWithOneShutdown(_ events: [AssetEvent]) -> Bool {
        events.last == .clientShutDown && events.filter { $0 == .clientShutDown }.count == 1
    }
}

@Suite("Verifier probes, close-out cycle 2, correctness lens")
struct VerifierProbesC2Correct {
    /// PROBE-C2-1 (L5-C1-00's class, own shape): a `subscribe()` stream that is not pulled across TWO reopens, each
    /// replacement publishing a marker, then read: both markers, in generation order, the final replacement's
    /// clientStarted before its marker, no clientShutDown before the real one, and no follower or subscriber left.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-1: two reopens before a subscribe() stream's first pull", .timeLimit(.minutes(1)))
    func twoReopensBeforeFirstPull() async throws {
        let x1 = Probes.onDemand("x1", 9_101)
        let x2 = Probes.onDemand("x2", 9_102)
        let harness = await Probes.harness([x1, x2])
        let client = harness.client
        let gauge = FollowerGauge()
        await client.lifecycle.setFollowerObserver { gauge.set($0) }
        try await harness.startAndSettle()
        let old = await client.lifecycle.current()
        let stream = try await harness.withClock { () throws(AssetError) -> AsyncStream<AssetEvent> in
            try await client.subscribe()
        }
        let g1 = try await Probes.reopen(harness)
        let g1Subscribers = await g1.engine.introspect().subscribers
        try await Probes.resolve(harness, x1)
        let g2 = try await Probes.reopen(harness)
        let g2Subscribers = await g2.engine.introspect().subscribers
        let started2 = await Probes.launchGeneration(g2)
        try await Probes.resolve(harness, x2)
        print("PROBE-C2-1 generations old=\(old.generation) g1=\(g1.generation) g2=\(g2.generation) subscribers g1=\(g1Subscribers) g2=\(g2Subscribers) followers=\(gauge.count)")
        var iterator = stream.makeAsyncIterator()
        var received: [AssetEvent] = []
        while let event = await iterator.next() {
            received.append(event)
            if Probes.isAvailable(event, "x2") {
                break
            }
        }
        print("PROBE-C2-1 received=\(received)")
        let i1 = received.firstIndex { Probes.isAvailable($0, "x1") }
        let i2 = received.firstIndex { Probes.isAvailable($0, "x2") }
        let s2 = started2.flatMap { received.firstIndex(of: .clientStarted(generation: $0)) }
        #expect(i1 != nil, "PROBE-C2-1: generation 1's marker reached the unpulled stream")
        #expect(i2 != nil, "PROBE-C2-1: generation 2's marker reached the unpulled stream")
        #expect(s2 != nil, "PROBE-C2-1: generation 2's clientStarted reached the unpulled stream")
        if let i1, let i2, let s2 {
            #expect(i1 < s2 && s2 < i2, "PROBE-C2-1: generation order")
        }
        #expect(!received.contains(.clientShutDown), "PROBE-C2-1: no retired clientShutDown forwarded")
        await client.shutdown()
        received += await Probes.drain(&iterator)
        #expect(Probes.endsWithOneShutdown(received), "PROBE-C2-1: one clientShutDown, last: \(received.suffix(3))")
        await gauge.wait(atMost: 0)
        for core in [old, g1, g2] {
            await core.engine.awaitNoSubscribers()
        }
        print("PROBE-C2-1 idle: followers=\(gauge.count) subscribers=\(await old.engine.introspect().subscribers),\(await g1.engine.introspect().subscribers),\(await g2.engine.introspect().subscribers)")
    }

    /// PROBE-C2-2 (L5-C1-04's class): an `events` stream whose first pull registers while a reopen is parked at
    /// `replacementBuilt` (the old engine already shut down): the follower is recorded during the park, the hand-over
    /// covers it, and the reader receives the replacement's clientStarted and a marker the replacement publishes.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-2: an events stream's first pull while a reopen is parked at replacementBuilt", .timeLimit(.minutes(1)))
    func eventsFirstPullWhileParkedAtBuilt() async throws {
        try await Self.eventsFirstPullWhileParked(atBuilt: true)
    }

    /// PROBE-C2-3: the same, parked at `reopenWillShutDownEngine` (the old engine still running): the registration is
    /// the old engine's, and the hand-over carries the reader to the replacement.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-3: an events stream's first pull while a reopen is parked before the old engine's shutdown", .timeLimit(.minutes(1)))
    func eventsFirstPullWhileParkedBeforeShutdown() async throws {
        try await Self.eventsFirstPullWhileParked(atBuilt: false)
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func eventsFirstPullWhileParked(atBuilt: Bool) async throws {
        let label = atBuilt ? "PROBE-C2-2" : "PROBE-C2-3"
        let x = Probes.onDemand("x", 9_201)
        let harness = await Probes.harness([x])
        let client = harness.client
        let gauge = FollowerGauge()
        await client.lifecycle.setFollowerObserver { gauge.set($0) }
        try await harness.startAndSettle()
        let old = await client.lifecycle.current()
        let hold = SeamHold()
        let box = CoreBox()
        await client.lifecycle.setSeam { point in
            switch point {
            case .replacementBuilt(let core):
                await box.add(core)
                if atBuilt {
                    await hold.arrive()
                }
            case .reopenWillShutDownEngine:
                if !atBuilt {
                    await hold.arrive()
                }
            default:
                break
            }
        }
        try harness.vanishRoot()
        let purge = Task { () -> Bool in
            do throws(AssetError) {
                _ = try await harness.withClock { () throws(AssetError) -> PurgeResult in
                    try await client.purge(.all)
                }
                return true
            } catch {
                return false
            }
        }
        await hold.waitUntilParked()
        let log = ProbeLog()
        let reader = Probes.read(client.events, into: log)
        await gauge.wait(atLeast: 1)
        let oldSubscribersWhileParked = await old.engine.introspect().subscribers
        print("\(label) parked: followers=\(gauge.count) oldSubscribers=\(oldSubscribersWhileParked)")
        await hold.open()
        #expect(await purge.value, "\(label) setup: the purge was repeated on the replacement")
        let replacement = await client.lifecycle.current()
        let started = await Probes.launchGeneration(replacement)
        try await Probes.resolve(harness, x)
        await log.wait { events, ended in ended || events.contains { Probes.isAvailable($0, "x") } }
        let received = await log.events
        print("\(label) received=\(received) replacementLaunchGeneration=\(String(describing: started))")
        let s = started.flatMap { received.firstIndex(of: .clientStarted(generation: $0)) }
        let a = received.firstIndex { Probes.isAvailable($0, "x") }
        #expect(s != nil, "\(label): the replacement's clientStarted reached the reader")
        #expect(a != nil, "\(label): the replacement's marker reached the reader")
        if let s, let a {
            #expect(s < a, "\(label): order")
        }
        #expect(!received.contains(.clientShutDown), "\(label): no retired clientShutDown forwarded")
        await client.shutdown()
        await log.wait { _, ended in ended }
        await reader.value
        let all = await log.events
        #expect(Probes.endsWithOneShutdown(all), "\(label): one clientShutDown, last: \(all.suffix(3))")
        await gauge.wait(atMost: 0)
        let built = await box.cores
        for core in [old, replacement] + built {
            await core.engine.awaitNoSubscribers()
        }
        print("\(label) idle: followers=\(gauge.count) built=\(built.map(\.generation))")
    }

    /// PROBE-C2-4: the client's shutdown while a reopen is parked at `replacementBuilt`, with an unpulled
    /// `subscribe()` stream and a reading `events` stream: each ends with exactly one clientShutDown, and nothing is
    /// left: no follower, no subscriber on the old engine or on the replacement that was built and never installed.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-4: shutdown while a reopen is parked at replacementBuilt", .timeLimit(.minutes(1)))
    func shutdownWhileParkedAtBuilt() async throws {
        let x = Probes.onDemand("x", 9_301)
        let harness = await Probes.harness([x])
        let client = harness.client
        let gauge = FollowerGauge()
        await client.lifecycle.setFollowerObserver { gauge.set($0) }
        try await harness.startAndSettle()
        let old = await client.lifecycle.current()
        let unpulled = try await harness.withClock { () throws(AssetError) -> AsyncStream<AssetEvent> in
            try await client.subscribe()
        }
        let log = ProbeLog()
        let reader = Probes.read(client.events, into: log)
        await log.wait { events, ended in ended || !events.isEmpty }
        let hold = SeamHold()
        let box = CoreBox()
        let waiting = ProbeSignal()
        await client.lifecycle.setSeam { point in
            switch point {
            case .replacementBuilt(let core):
                await box.add(core)
                await hold.arrive()
            case .shutdownWillWaitForReopen:
                await waiting.fire()
            default:
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
        await hold.waitUntilParked()
        let shutdown = Task {
            await client.shutdown()
        }
        await waiting.wait()
        await hold.open()
        let purged = await purge.value
        await shutdown.value
        print("PROBE-C2-4 purge=\(purged)")
        #expect((try? purged.get()) == nil, "PROBE-C2-4: the purge reports the shutdown")
        var iterator = unpulled.makeAsyncIterator()
        let drained = await Probes.drain(&iterator)
        await log.wait { _, ended in ended }
        await reader.value
        let read = await log.events
        print("PROBE-C2-4 unpulled=\(drained) reader=\(read)")
        #expect(Probes.endsWithOneShutdown(drained), "PROBE-C2-4: the unpulled stream ends with one clientShutDown")
        #expect(Probes.endsWithOneShutdown(read), "PROBE-C2-4: the reader ends with one clientShutDown")
        await gauge.wait(atMost: 0)
        let built = await box.cores
        for core in [old] + built {
            await core.engine.awaitNoSubscribers()
        }
        print("PROBE-C2-4 idle: followers=\(gauge.count) built=\(built.map(\.generation)) builtLifecycle=\(await built.first?.engine.introspect().lifecycle as Any)")
    }

    /// PROBE-C2-5: many unpulled `subscribe()` streams and a shutdown released together with a reopen parked at
    /// `replacementBuilt`, so the shutdown can land inside the hand-over loop (some forwarders handed the never-installed
    /// replacement's stream, some not). Every stream ends with exactly one clientShutDown and nothing is left.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-5: shutdown racing the hand-over loop over many followers", .timeLimit(.minutes(2)))
    func shutdownRacingTheHandOver() async throws {
        var handedCounts: [Int] = []
        for round in 0..<6 {
            let x = Probes.onDemand("x", 9_400 + UInt64(round))
            let harness = await Probes.harness([x])
            let client = harness.client
            let gauge = FollowerGauge()
            await client.lifecycle.setFollowerObserver { gauge.set($0) }
            try await harness.startAndSettle()
            let old = await client.lifecycle.current()
            var streams: [AsyncStream<AssetEvent>] = []
            for _ in 0..<40 {
                streams.append(try await harness.withClock { () throws(AssetError) -> AsyncStream<AssetEvent> in
                    try await client.subscribe()
                })
            }
            let hold = SeamHold()
            let box = CoreBox()
            await client.lifecycle.setSeam { point in
                if case .replacementBuilt(let core) = point {
                    await box.add(core)
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
            let shutdown = Task {
                await client.shutdown()
            }
            // Released at once: the shutdown and the hand-over race.
            await hold.open()
            _ = await purge.value
            await shutdown.value
            let built = await box.cores
            let handed = await built.first?.engine.introspect().subscribers ?? -1
            handedCounts.append(handed)
            for (index, stream) in streams.enumerated() {
                var iterator = stream.makeAsyncIterator()
                let events = await Probes.drain(&iterator)
                if !Probes.endsWithOneShutdown(events) {
                    Issue.record("PROBE-C2-5 round \(round) stream \(index): \(events)")
                }
            }
            streams = []
            await gauge.wait(atMost: 0)
            for core in [old] + built {
                await core.engine.awaitNoSubscribers()
            }
        }
        print("PROBE-C2-5 handed streams of the never-installed replacement per round: \(handedCounts)")
    }

    /// PROBE-C2-6 (L5-C1-01's shape): the reworked R-STO-9 setup. Generation 0 now always downloads the asset before the
    /// root vanishes (the formerly racy interleaving), and the replacement downloads it exactly once from the baseline.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-6: the R-STO-9 setup always takes the interleaving that used to flake", .timeLimit(.minutes(1)))
    func reworkedRSTO9Interleaving() async throws {
        let bytes = KitFixture.bytes(161)
        let entry = KitFixture.entry("a", bytes)
        let harness = KitHarness.make()
        let client = harness.client
        await harness.serve([(entry, bytes)])
        let probe = EventProbe(stream: try await harness.withClock { () throws(AssetError) in
            try await client.subscribe()
        })
        await harness.serve([(entry, bytes)])
        try await harness.startAndSettle()
        let core = await client.lifecycle.current()
        try harness.vanishRoot()
        let store = core.store
        await #expect(throws: StoreError.storageUnavailable(.rootVanished)) {
            try await harness.withClock { () throws(StoreError) in
                try await store.markSyncDue()
            }
        }
        let manifest = KitFixture.manifestData([entry])
        await harness.source.scriptManifest([.fetched(manifest, etag: KitFixture.etag("v2")), .fetched(manifest, etag: KitFixture.etag("v3"))])
        await harness.source.script(entry.transferID, [.stage(bytes)])
        let before = await harness.source.starts.filter { $0.id == entry.transferID }.count
        let startsBefore = await harness.source.starts.count
        let outcome = await harness.syncDriven(.force)
        let total = await harness.source.starts.filter { $0.id == entry.transferID }.count
        let after = await harness.source.starts.dropFirst(startsBefore).filter { $0.id == entry.transferID }.count
        print("PROBE-C2-6 outcome=\(outcome) startsOfABeforeBaseline=\(before) startsOfATotal=\(total) startsOfAAfterBaseline=\(after)")
        let finishedOutcome = outcome
        _ = await probe.next { event in
            if case .syncFinished(_, let value) = event {
                return value == finishedOutcome
            }
            return false
        }
        let finishes = await probe.received.compactMap { event -> SyncOutcome? in
            if case .syncFinished(_, let value) = event {
                return value
            }
            return nil
        }
        let equalCount = finishes.filter { $0 == outcome }.count
        probeLog("PROBE-C2-6 syncFinished outcomes the stream carried: \(finishes.count), equal to the returned outcome: \(equalCount)")
        for value in finishes {
            probeLog("PROBE-C2-6   \(value)")
        }
        #expect(before >= 1, "PROBE-C2-6: generation 0 downloaded the asset (the interleaving that failed the old count)")
        #expect(after == 1, "PROBE-C2-6: the replacement downloaded it once")
        await client.shutdown()
        await probe.stop()
    }

    /// PROBE-C2-7: an unpulled `subscribe()` stream and a reopen parked after the install (at
    /// `replacementObservesPressure`), during which a call reaches the replacement: the stream the hand-over gave the
    /// forwarder before the install carries that call's terminal event and the replacement's clientStarted.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-7: an unpulled subscribe() stream and a call served while the reopen is parked after the install", .timeLimit(.minutes(1)))
    func unpulledStreamAndCallDuringPostInstallPark() async throws {
        let x = Probes.onDemand("x", 9_501)
        let harness = await Probes.harness([x])
        let client = harness.client
        let gauge = FollowerGauge()
        await client.lifecycle.setFollowerObserver { gauge.set($0) }
        try await harness.startAndSettle()
        let old = await client.lifecycle.current()
        let stream = try await harness.withClock { () throws(AssetError) -> AsyncStream<AssetEvent> in
            try await client.subscribe()
        }
        let hold = SeamHold()
        await client.lifecycle.setSeam { point in
            if case .replacementObservesPressure = point {
                await hold.arrive()
            }
        }
        try harness.vanishRoot()
        let purge = Task { () -> Bool in
            do throws(AssetError) {
                _ = try await harness.withClock { () throws(AssetError) -> PurgeResult in
                    try await client.purge(.all)
                }
                return true
            } catch {
                return false
            }
        }
        await hold.waitUntilParked()
        let replacement = await client.lifecycle.current()
        let subscribersWhileParked = await replacement.engine.introspect().subscribers
        try await Probes.resolve(harness, x)
        await hold.open()
        #expect(await purge.value, "PROBE-C2-7 setup: the purge was repeated on the replacement")
        let started = await Probes.launchGeneration(replacement)
        var iterator = stream.makeAsyncIterator()
        var received: [AssetEvent] = []
        while let event = await iterator.next() {
            received.append(event)
            if Probes.isAvailable(event, "x") {
                break
            }
        }
        print("PROBE-C2-7 generation=\(replacement.generation) subscribersWhileParked=\(subscribersWhileParked) received=\(received)")
        let s = started.flatMap { received.firstIndex(of: .clientStarted(generation: $0)) }
        #expect(s != nil, "PROBE-C2-7: the replacement's clientStarted reached the stream")
        #expect(received.contains { Probes.isAvailable($0, "x") }, "PROBE-C2-7: the call's terminal event reached the stream")
        #expect(!received.contains(.clientShutDown), "PROBE-C2-7: no retired clientShutDown")
        await client.shutdown()
        received += await Probes.drain(&iterator)
        #expect(Probes.endsWithOneShutdown(received))
        await gauge.wait(atMost: 0)
        for core in [old, replacement] {
            await core.engine.awaitNoSubscribers()
        }
    }

    /// PROBE-C2-8: an unpulled `subscribe()` stream dropped while a reopen is parked at `replacementBuilt`: its follower
    /// entry goes at once, the hand-over hands it nothing (or a stream it drops), and the replacement keeps no subscriber.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-8: an unpulled subscribe() stream dropped during a parked reopen leaves nothing", .timeLimit(.minutes(1)))
    func droppedUnpulledStreamDuringPark() async throws {
        let x = Probes.onDemand("x", 9_601)
        let harness = await Probes.harness([x])
        let client = harness.client
        let gauge = FollowerGauge()
        await client.lifecycle.setFollowerObserver { gauge.set($0) }
        try await harness.startAndSettle()
        let old = await client.lifecycle.current()
        var stream: AsyncStream<AssetEvent>? = try await harness.withClock { () throws(AssetError) -> AsyncStream<AssetEvent> in
            try await client.subscribe()
        }
        #expect(stream != nil)
        await gauge.wait(atLeast: 1)
        let hold = SeamHold()
        await client.lifecycle.setSeam { point in
            if case .replacementBuilt = point {
                await hold.arrive()
            }
        }
        try harness.vanishRoot()
        let purge = Task { () -> Bool in
            do throws(AssetError) {
                _ = try await harness.withClock { () throws(AssetError) -> PurgeResult in
                    try await client.purge(.all)
                }
                return true
            } catch {
                return false
            }
        }
        await hold.waitUntilParked()
        stream = nil
        await gauge.wait(atMost: 0)
        await hold.open()
        #expect(await purge.value)
        let replacement = await client.lifecycle.current()
        await replacement.engine.awaitNoSubscribers()
        await old.engine.awaitNoSubscribers()
        print("PROBE-C2-8 followers=\(gauge.count) replacementSubscribers=\(await replacement.engine.introspect().subscribers)")
        await client.shutdown()
    }
}

@Suite("Verifier probes, close-out cycle 2, correctness lens: the client slot")
struct VerifierProbesC2CorrectClientSlot {
    /// PROBE-C2-9: an intermediate generation's clientStarted. A `subscribe()` stream on generation 0 (whose snapshot
    /// generation was raised by a few installs), not read across two reopens. Generation 1 publishes clientStarted, then
    /// a marker, then its retirement's clientShutDown, which shares the engine queue's `.client` slot and supersedes the
    /// unread clientStarted; the forwarder hides that retired clientShutDown. An oracle reading generation 1 directly
    /// shows what generation 1 published. `pullBetween` is the control: the consumer reads up to generation 1's marker
    /// before the second reopen.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-9: an intermediate generation's clientStarted across two reopens", .timeLimit(.minutes(1)), arguments: [false, true])
    func intermediateGenerationsClientStarted(pullBetween: Bool) async throws {
        let label = pullBetween ? "PROBE-C2-9 control" : "PROBE-C2-9"
        let warm = (0..<4).map { Probes.onDemand("w\($0)", 9_700 + UInt64($0)) }
        let x1 = Probes.onDemand("x1", 9_711)
        let x2 = Probes.onDemand("x2", 9_712)
        let harness = await Probes.harness(warm + [x1, x2])
        let client = harness.client
        let oracle = ProbeLog()
        let readers = CoreBox()
        await client.lifecycle.setSeam { point in
            if case .replacementBuilt(let core) = point, core.generation == 1 {
                await readers.add(core)
                if case .success(let stream) = await core.engine.subscribe() {
                    _ = Probes.read(stream, into: oracle)
                }
            }
        }
        try await harness.startAndSettle()
        for entry in warm {
            try await Probes.resolve(harness, entry)
        }
        let stream = try await harness.withClock { () throws(AssetError) -> AsyncStream<AssetEvent> in
            try await client.subscribe()
        }
        var iterator = stream.makeAsyncIterator()
        var received: [AssetEvent] = []
        let g1 = try await Probes.reopen(harness)
        let g1Started = await Probes.launchGeneration(g1)
        try await Probes.resolve(harness, x1)
        if pullBetween {
            while let event = await iterator.next() {
                received.append(event)
                if Probes.isAvailable(event, "x1") {
                    break
                }
            }
        }
        let g2 = try await Probes.reopen(harness)
        let g2Started = await Probes.launchGeneration(g2)
        try await Probes.resolve(harness, x2)
        while let event = await iterator.next() {
            received.append(event)
            if Probes.isAvailable(event, "x2") {
                break
            }
        }
        await oracle.wait { _, ended in ended }
        let published = await oracle.events
        print("\(label) g1 launch generation=\(String(describing: g1Started)) g2 launch generation=\(String(describing: g2Started))")
        print("\(label) generation 1 published (oracle): \(published.map { "\($0)" }.filter { $0.contains("client") || $0.contains("assetAvailable") || $0.contains("snapshotChanged") })")
        print("\(label) consumer received: \(received.map { "\($0)" }.filter { $0.contains("client") || $0.contains("assetAvailable") || $0.contains("snapshotChanged") })")
        let oraclePublishedStarted = g1Started.map { published.contains(.clientStarted(generation: $0)) } ?? false
        let lastWarm = received.lastIndex { event in warm.contains { Probes.isAvailable(event, $0.0.identifier) } } ?? -1
        let firstOfGeneration1 = received.firstIndex { Probes.isAvailable($0, "x1") } ?? received.count
        let resetBetween = received[(lastWarm + 1)..<firstOfGeneration1].contains { Probes.isStarted($0) }
        #expect(oraclePublishedStarted, "\(label): generation 1 published its clientStarted")
        #expect(resetBetween, "\(label): the consumer reads generation 1's events after generation 0's with no clientStarted between them")
        await client.shutdown()
        received += await Probes.drain(&iterator)
        #expect(Probes.endsWithOneShutdown(received))
    }
}

@Suite("Verifier probes, close-out cycle 2, correctness lens: the backwards generation")
struct VerifierProbesC2CorrectBackwards {
    /// PROBE-C2-10: the consequence of PROBE-C2-9 that the L5-R3 decision to forward clientStarted exists for (B-17: a
    /// replacement's snapshot generation restarts from its index files and can be smaller than the mirror's). Every
    /// commit installs a snapshot (`snapshotInstallInterval` 0), the consumer reads generation 0's events up to a high
    /// snapshot generation, then two reopens run while it reads nothing. It then reads generation 1's events, whose
    /// snapshot generations are smaller, with no clientStarted announcing the reset.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-10: a backwards snapshot generation with no reset announced", .timeLimit(.minutes(1)))
    func backwardsGenerationWithoutReset() async throws {
        let warm = (0..<6).map { Probes.onDemand("w\($0)", 9_800 + UInt64($0)) }
        let x1 = Probes.onDemand("x1", 9_811)
        let x2 = Probes.onDemand("x2", 9_812)
        let entries = warm + [x1, x2]
        let harness = KitHarness.make(tuning: SyncTuning(snapshotInstallInterval: 0))
        let manifest = KitFixture.manifestData(entries.map(\.0))
        await harness.source.scriptManifest((0..<24).map { .fetched(manifest, etag: KitFixture.etag("b\($0)")) })
        let client = harness.client
        try await harness.startAndSettle()
        let stream = try await harness.withClock { () throws(AssetError) -> AsyncStream<AssetEvent> in
            try await client.subscribe()
        }
        var iterator = stream.makeAsyncIterator()
        var received: [AssetEvent] = []
        for entry in warm {
            try await Probes.resolve(harness, entry)
        }
        while let event = await iterator.next() {
            received.append(event)
            if Probes.isAvailable(event, warm[warm.count - 1].0.identifier) {
                break
            }
        }
        _ = try await Probes.reopen(harness)
        try await Probes.resolve(harness, x1)
        _ = try await Probes.reopen(harness)
        try await Probes.resolve(harness, x2)
        while let event = await iterator.next() {
            received.append(event)
            if Probes.isAvailable(event, "x2") {
                break
            }
        }
        func generation(_ event: AssetEvent) -> UInt64? {
            switch event {
            case .snapshotChanged(let generation), .assetAvailable(_, let generation):
                return generation
            default:
                return nil
            }
        }
        var newest: UInt64 = 0
        var backwards: [String] = []
        for event in received {
            if case .clientStarted = event {
                newest = 0
                continue
            }
            if let value = generation(event) {
                if value < newest {
                    backwards.append("\(event) after generation \(newest)")
                }
                newest = max(newest, value)
            }
        }
        print("PROBE-C2-10 received: \(received.map { "\($0)" }.filter { $0.contains("client") || $0.contains("assetAvailable") || $0.contains("snapshotChanged") })")
        print("PROBE-C2-10 backwards without a clientStarted before them: \(backwards)")
        #expect(backwards.isEmpty, "PROBE-C2-10: every snapshot generation that goes back follows a clientStarted")
        await client.shutdown()
        received += await Probes.drain(&iterator)
    }
}

@Suite("Verifier probes, close-out cycle 2, correctness lens: the backwards generation, unread")
struct VerifierProbesC2CorrectBackwardsUnread {
    /// PROBE-C2-11: PROBE-C2-9's unread `subscribe()` stream, with generation 0's snapshot generation raised first by
    /// purges (each installs a snapshot), so generation 1's events carry smaller snapshot generations than generation 0's.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-11: an unread stream sees the snapshot generation go back with no reset announced", .timeLimit(.minutes(1)))
    func backwardsGenerationUnread() async throws {
        let x1 = Probes.onDemand("x1", 9_911)
        let x2 = Probes.onDemand("x2", 9_912)
        let harness = await Probes.harness([x1, x2])
        let client = harness.client
        try await harness.startAndSettle()
        for round in 0..<6 {
            _ = try await harness.withClock { () throws(AssetError) -> PurgeResult in
                try await client.purge(.all)
            }
            print("PROBE-C2-11 step purge \(round) generation \(String(describing: await (await client.lifecycle.current()).engine.kitRead { $0.state.generation }))")
        }
        let stream = try await harness.withClock { () throws(AssetError) -> AsyncStream<AssetEvent> in
            try await client.subscribe()
        }
        print("PROBE-C2-11 step subscribed")
        _ = try await Probes.reopen(harness)
        print("PROBE-C2-11 step reopen 1")
        try await Probes.resolve(harness, x1)
        print("PROBE-C2-11 step x1")
        _ = try await Probes.reopen(harness)
        print("PROBE-C2-11 step reopen 2")
        try await Probes.resolve(harness, x2)
        print("PROBE-C2-11 step x2")
        var iterator = stream.makeAsyncIterator()
        var received: [AssetEvent] = []
        while let event = await iterator.next() {
            received.append(event)
            print("PROBE-C2-11 read \(event)")
            if Probes.isAvailable(event, "x2") {
                break
            }
        }
        var newest: UInt64 = 0
        var backwards: [String] = []
        for event in received {
            if case .clientStarted = event {
                newest = 0
                continue
            }
            var value: UInt64?
            switch event {
            case .snapshotChanged(let generation), .assetAvailable(_, let generation):
                value = generation
            default:
                value = nil
            }
            if let value {
                if value < newest {
                    backwards.append("\(event) after generation \(newest)")
                }
                newest = max(newest, value)
            }
        }
        print("PROBE-C2-11 received: \(received.map { "\($0)" }.filter { $0.contains("client") || $0.contains("assetAvailable") || $0.contains("snapshotChanged") })")
        print("PROBE-C2-11 backwards without a clientStarted before them: \(backwards)")
        #expect(backwards.isEmpty, "PROBE-C2-11: every snapshot generation that goes back follows a clientStarted: \(backwards)")
        await client.shutdown()
        received += await Probes.drain(&iterator)
    }
}

@available(macOS 15.0, iOS 18.0, *)
actor DoneFlag {
    private(set) var value: Bool?
    func set(_ value: Bool) {
        self.value = value
    }
}

func probeLog(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

@Suite("Verifier probes, close-out cycle 2, correctness lens: diagnosis")
struct VerifierProbesC2CorrectDiagnosis {
    /// PROBE-C2-12 (diagnosis of PROBE-C2-11's hang): purges on generation 0, a reopen, then a resolve on generation 1;
    /// the engine's state is dumped if the resolve has not returned after a few seconds (a diagnostic real-time wait).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-12: a resolve after purges and a reopen", .timeLimit(.minutes(1)), arguments: [0, 1, 6])
    func resolveAfterPurgesAndReopen(purges: Int) async throws {
        let x1 = Probes.onDemand("x1", 9_921)
        let harness = await Probes.harness([x1])
        let client = harness.client
        try await harness.startAndSettle()
        for _ in 0..<purges {
            _ = try await harness.withClock { () throws(AssetError) -> PurgeResult in
                try await client.purge(.all)
            }
        }
        probeLog("PROBE-C2-12 purges=\(purges) purged")
        let g1 = try await Probes.reopen(harness)
        probeLog("PROBE-C2-12 purges=\(purges) reopened to \(g1.generation)")
        let flag = DoneFlag()
        let resolve = Task {
            do {
                try await Probes.resolve(harness, x1)
                await flag.set(true)
            } catch {
                probeLog("PROBE-C2-12 purges=\(purges) resolve threw \(error)")
                await flag.set(false)
            }
        }
        try? await Task.sleep(for: .seconds(5))
        let done = await flag.value
        let dump = await g1.engine.kitRead { engine -> String in
            let s = engine.state
            return "lifecycle=\(s.lifecycle) jobs=\(s.jobs.count) waiters=\(s.waiters.count) unknownWaiters=\(s.unknownWaiters.count) run=\(s.run != nil) manifestFetch=\(s.manifestFetch != nil) applied=\(s.applied.entries.map(\.identifier)) introspect=\(engine.introspect())"
        }
        let pending = harness.time.pendingSleepers
        probeLog("PROBE-C2-12 purges=\(purges) resolved=\(String(describing: done)) generation=\(g1.generation) sleepers=\(pending) \(dump)")
        if done == nil {
            Issue.record("PROBE-C2-12 purges=\(purges): the resolve did not return within 5 s: \(dump)")
            resolve.cancel()
            return
        }
        await client.shutdown()
    }
}

@Suite("Verifier probes, close-out cycle 2, correctness lens: diagnosis 2")
struct VerifierProbesC2CorrectDiagnosis2 {
    /// PROBE-C2-13: what a resolve does on a store whose root vanished while the store has not noticed (a purge of an
    /// empty store touched nothing). Dumps the job, the fake source's log for the asset and the store's reason.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-13: a resolve on an undetected vanished root", .timeLimit(.minutes(1)))
    func resolveOnUndetectedVanishedRoot() async throws {
        let x1 = Probes.onDemand("x1", 9_931)
        let harness = await Probes.harness([x1])
        let client = harness.client
        try await harness.startAndSettle()
        let core = await client.lifecycle.current()
        try harness.vanishRoot()
        let reasonBefore = await core.store.unavailableReason
        await harness.source.script(x1.0.transferID, [.stage(x1.1)])
        let flag = DoneFlag()
        let resolve = Task {
            do {
                _ = try await harness.withClock { () throws(AssetError) -> URL in
                    try await client.resolve("x1")
                }
                await flag.set(true)
            } catch {
                probeLog("PROBE-C2-13 resolve threw \(error)")
                await flag.set(false)
            }
        }
        try? await Task.sleep(for: .seconds(4))
        let done = await flag.value
        let now = await client.lifecycle.current()
        let reasonAfter = await core.store.unavailableReason
        let dump = await core.engine.kitRead { engine -> String in
            let s = engine.state
            let jobs = s.jobs.values.map { "\($0.transfer) state=\($0.state) attempts=\($0.attempts) active=\($0.active != nil)" }
            return "lifecycle=\(s.lifecycle) jobs=\(jobs) waiters=\(s.waiters.count) introspect=\(engine.introspect())"
        }
        let events = harness.source.transportLog.events.map { "\($0)" }
        let active = await harness.source.activeTransfers
        probeLog("PROBE-C2-13 resolved=\(String(describing: done)) generationAfter=\(now.generation) reasonBefore=\(String(describing: reasonBefore)) reasonAfter=\(String(describing: reasonAfter)) activeTransfers=\(active)")
        probeLog("PROBE-C2-13 engine: \(dump)")
        probeLog("PROBE-C2-13 transport log: \(events)")
        if done == nil {
            Issue.record("PROBE-C2-13: the resolve did not return within 4 s")
            resolve.cancel()
            return
        }
        await client.shutdown()
    }
}

@Suite("Verifier probes, close-out cycle 2, correctness lens: diagnosis 3")
struct VerifierProbesC2CorrectDiagnosis3 {
    /// PROBE-C2-14: PROBE-C2-13 with enough scripted attempts for every retry: how a resolve on an undetected vanished
    /// root ends, and whether anything reopens.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-14: how a resolve on an undetected vanished root ends", .timeLimit(.minutes(1)))
    func resolveOnUndetectedVanishedRootEnds() async throws {
        let x1 = Probes.onDemand("x1", 9_941)
        let harness = await Probes.harness([x1])
        let client = harness.client
        try await harness.startAndSettle()
        let core = await client.lifecycle.current()
        try harness.vanishRoot()
        await harness.source.script(x1.0.transferID, Array(repeating: .stage(x1.1), count: 12))
        let result: Result<URL, AssetError>
        do throws(AssetError) {
            result = .success(try await harness.withClock { () throws(AssetError) -> URL in
                try await client.resolve("x1")
            })
        } catch {
            result = .failure(error)
        }
        let now = await client.lifecycle.current()
        let reason = await core.store.unavailableReason
        let starts = await harness.source.starts.filter { $0.id == x1.0.transferID }.count
        probeLog("PROBE-C2-14 result=\(result) generationAfter=\(now.generation) storeReason=\(String(describing: reason)) attempts=\(starts)")
        await client.shutdown()
    }
}

@Suite("Verifier probes, close-out cycle 2, correctness lens: diagnosis 4")
struct VerifierProbesC2CorrectDiagnosis4 {
    /// PROBE-C2-15: an undetected vanished root met by `sync(.force)` (a standard asset to download), then by a resolve:
    /// whether the sync's failure flags the store and reopens, and what each call returns.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-15: sync and resolve on an undetected vanished root", .timeLimit(.minutes(1)))
    func syncOnUndetectedVanishedRoot() async throws {
        let bytes = KitFixture.bytes(9_951, count: 64)
        let a = KitFixture.entry("a", bytes)
        let x1 = Probes.onDemand("x1", 9_952)
        let harness = KitHarness.make()
        let manifest = KitFixture.manifestData([a, x1.0])
        await harness.source.scriptManifest((0..<24).map { .fetched(manifest, etag: KitFixture.etag("s\($0)")) })
        await harness.source.script(a.transferID, [.stage(bytes)])
        let client = harness.client
        try await harness.startAndSettle()
        let core = await client.lifecycle.current()
        try harness.vanishRoot()
        await harness.source.script(a.transferID, Array(repeating: .stage(bytes), count: 12))
        let outcome = await harness.syncDriven(.force)
        let afterSync = await client.lifecycle.current()
        let reasonAfterSync = await core.store.unavailableReason
        probeLog("PROBE-C2-15 sync outcome=\(outcome) generationAfter=\(afterSync.generation) storeReason=\(String(describing: reasonAfterSync))")
        await harness.source.script(x1.0.transferID, Array(repeating: .stage(x1.1), count: 12))
        let result: Result<URL, AssetError>
        do throws(AssetError) {
            result = .success(try await harness.withClock { () throws(AssetError) -> URL in
                try await client.resolve("x1")
            })
        } catch {
            result = .failure(error)
        }
        let afterResolve = await client.lifecycle.current()
        probeLog("PROBE-C2-15 resolve=\(result) generationAfter=\(afterResolve.generation) storeReason=\(String(describing: await core.store.unavailableReason))")
        await client.shutdown()
    }
}

@Suite("Verifier probes, close-out cycle 2, correctness lens: shutdown inside the hand-over")
struct VerifierProbesC2CorrectMidHandOver {
    /// PROBE-C2-16: the client's shutdown placed inside the hand-over loop: 60 unread `subscribe()` streams, the reopen
    /// parked at `replacementBuilt`, released, and the shutdown started once the never-installed replacement holds at least
    /// five handed streams (a condition on its subscriber count). Every stream ends with exactly one clientShutDown, the
    /// replacement was never installed, and nothing is left once the streams ended.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-16: shutdown inside the hand-over loop", .timeLimit(.minutes(1)))
    func shutdownInsideTheHandOver() async throws {
        let x = Probes.onDemand("x", 9_961)
        let harness = await Probes.harness([x])
        let client = harness.client
        let gauge = FollowerGauge()
        await client.lifecycle.setFollowerObserver { gauge.set($0) }
        try await harness.startAndSettle()
        let old = await client.lifecycle.current()
        var streams: [AsyncStream<AssetEvent>] = []
        for _ in 0..<60 {
            streams.append(try await harness.withClock { () throws(AssetError) -> AsyncStream<AssetEvent> in
                try await client.subscribe()
            })
        }
        let hold = SeamHold()
        let box = CoreBox()
        await client.lifecycle.setSeam { point in
            if case .replacementBuilt(let core) = point {
                await box.add(core)
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
        let built = try #require(await box.cores.first)
        await hold.open()
        await built.engine.waitUntil { $0.subscribers >= 5 }
        await client.shutdown()
        let purged = await purge.value
        let handed = await built.engine.introspect().subscribers
        let installed = await client.lifecycle.current().generation
        probeLog("PROBE-C2-16 handed=\(handed) of 60, installed generation=\(installed), purge=\(purged), builtLifecycle=\(await built.engine.introspect().lifecycle)")
        #expect(handed >= 5 && handed < 60, "PROBE-C2-16 setup: the shutdown landed inside the hand-over (\(handed) handed)")
        #expect(installed == old.generation, "PROBE-C2-16: nothing was installed")
        var bad = 0
        for stream in streams {
            var iterator = stream.makeAsyncIterator()
            let events = await Probes.drain(&iterator)
            if !Probes.endsWithOneShutdown(events) {
                bad += 1
                probeLog("PROBE-C2-16 bad stream: \(events)")
            }
        }
        streams = []
        #expect(bad == 0, "PROBE-C2-16: every stream ends with one clientShutDown")
        await gauge.wait(atMost: 0)
        await old.engine.awaitNoSubscribers()
        await built.engine.awaitNoSubscribers()
        probeLog("PROBE-C2-16 idle: followers=\(gauge.count) oldSubscribers=\(await old.engine.introspect().subscribers) builtSubscribers=\(await built.engine.introspect().subscribers) builtOwnedTasks=\(await built.engine.introspect().ownedTasks)")
    }
}

@Suite("Verifier probes, close-out cycle 2, correctness lens: a slow events consumer")
struct VerifierProbesC2CorrectSlowEvents {
    /// PROBE-C2-17: PROBE-C2-9 for an `events` stream that IS being read, one event behind: its first pull registered it
    /// on generation 0 and returned; generation 0 then publishes two markers, so the pump holds the first in `offer` and
    /// does not reach the stream generation 1's hand-over gave it while generation 1 starts, publishes a marker and is
    /// retired by a second reopen. Generation 1's clientStarted is superseded in that unread stream by its retired
    /// clientShutDown, which the forwarder hides.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C2-17: a slow events consumer and an intermediate generation's clientStarted", .timeLimit(.minutes(1)))
    func slowEventsConsumerLosesIntermediateClientStarted() async throws {
        let w0 = Probes.onDemand("w0", 9_971)
        let w1 = Probes.onDemand("w1", 9_972)
        let x1 = Probes.onDemand("x1", 9_973)
        let x2 = Probes.onDemand("x2", 9_974)
        let harness = await Probes.harness([w0, w1, x1, x2])
        let client = harness.client
        let oracle = ProbeLog()
        await client.lifecycle.setSeam { point in
            if case .replacementBuilt(let core) = point, core.generation == 1 {
                if case .success(let stream) = await core.engine.subscribe() {
                    _ = Probes.read(stream, into: oracle)
                }
            }
        }
        try await harness.startAndSettle()
        var iterator = client.events.makeAsyncIterator()
        var received: [AssetEvent] = []
        if let first = await iterator.next() {
            received.append(first)
        }
        try await Probes.resolve(harness, w0)
        try await Probes.resolve(harness, w1)
        let g1 = try await Probes.reopen(harness)
        let g1Started = await Probes.launchGeneration(g1)
        try await Probes.resolve(harness, x1)
        _ = try await Probes.reopen(harness)
        try await Probes.resolve(harness, x2)
        while let event = await iterator.next() {
            received.append(event)
            if Probes.isAvailable(event, "x2") {
                break
            }
        }
        await oracle.wait { _, ended in ended }
        let published = await oracle.events
        let summary = received.map { "\($0)" }.filter { $0.contains("client") || $0.contains("assetAvailable") }
        probeLog("PROBE-C2-17 generation 1 published: \(published.map { "\($0)" }.filter { $0.contains("client") || $0.contains("assetAvailable") })")
        probeLog("PROBE-C2-17 consumer received: \(summary)")
        let w1Index = received.firstIndex { Probes.isAvailable($0, "w1") } ?? -1
        let x1Index = received.firstIndex { Probes.isAvailable($0, "x1") } ?? received.count
        let announced = w1Index < x1Index && received[(w1Index + 1)..<x1Index].contains { Probes.isStarted($0) }
        #expect(g1Started.map { published.contains(.clientStarted(generation: $0)) } == true, "PROBE-C2-17: generation 1 published its clientStarted")
        #expect(announced, "PROBE-C2-17: a clientStarted precedes generation 1's events in the consumer's stream")
        await client.shutdown()
        received += await Probes.drain(&iterator)
        #expect(Probes.endsWithOneShutdown(received))
    }
}
