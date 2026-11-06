import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
@testable import ZTronAssetTransport

/// Verifier probes (cycle 2, correctness lens). Not committed.

/// Wraps the fake driver and holds every priority write (and, on request, the next listing) until the probe releases
/// it; records the order writes were issued and landed.
@available(macOS 15.0, iOS 18.0, *)
actor GatedPriorityDriver: BackgroundSessionDriver {
    enum Event: Sendable, Equatable {
        case held(Int)
        case listing
        case done(Int)
    }

    nonisolated let base: FakeBackgroundSessionDriver
    nonisolated var identifier: BackgroundSessionIdentifier { self.base.identifier }
    nonisolated let events: AsyncStream<Event>
    private let sink: AsyncStream<Event>.Continuation
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var listingGate: CheckedContinuation<Void, Never>?
    private var holdListing = false
    private var nextWrite = 0
    private(set) var issued: [(id: Int, task: Int, value: Float, afterFinish: Bool)] = []
    private(set) var landed: [(id: Int, task: Int, value: Float)] = []
    var finished = false

    init(base: FakeBackgroundSessionDriver) {
        self.base = base
        (self.events, self.sink) = AsyncStream.makeStream(of: Event.self)
    }

    func activate() async -> AsyncStream<SessionEvent> { await self.base.activate() }

    func snapshot() async -> [BackgroundTaskSnapshot] {
        let listing = await self.base.snapshot()
        if self.holdListing {
            self.holdListing = false
            await withCheckedContinuation { continuation in
                self.listingGate = continuation
                self.sink.yield(.listing)
            }
        }
        return listing
    }

    func startDownload(_ request: URLRequest, name: StagingFileName, priority: Float, expectedBytes: Int64?, resumeData: ResumeData?) async {
        await self.base.startDownload(request, name: name, priority: priority, expectedBytes: expectedBytes, resumeData: resumeData)
    }

    func cancel(taskIdentifier: Int, producingResumeData: Bool) async -> ResumeData? {
        await self.base.cancel(taskIdentifier: taskIdentifier, producingResumeData: producingResumeData)
    }

    func setPriority(taskIdentifier: Int, _ priority: Float) async {
        self.nextWrite += 1
        let id = self.nextWrite
        self.issued.append((id, taskIdentifier, priority, self.finished))
        await withCheckedContinuation { continuation in
            self.gates[id] = continuation
            self.sink.yield(.held(id))
        }
        self.landed.append((id, taskIdentifier, priority))
        await self.base.setPriority(taskIdentifier: taskIdentifier, priority)
    }

    func invalidate() async { await self.base.invalidate() }

    func holdNextListing() { self.holdListing = true }
    func releaseListing() {
        self.listingGate?.resume()
        self.listingGate = nil
    }
    func release(_ id: Int) { self.gates.removeValue(forKey: id)?.resume() }
    func markFinished() { self.finished = true }
    func post(_ event: Event) { self.sink.yield(event) }
}

@Suite("S3D c2 verifier: correctness probes")
struct S3DC2CorrectProbeTests {
    @available(macOS 15.0, iOS 18.0, *)
    typealias Rig = BackgroundCoordinatorTests.Rig

    enum Action: Equatable, CustomStringConvertible {
        case request(Int, holdListing: Bool)
        case releaseListing(Int)
        case release(Int)
        case finish

        var description: String {
            switch self {
            case .request(let k, let hold): return "req\(k)\(hold ? "H" : "")"
            case .releaseListing(let k): return "relL\(k)"
            case .release(let id): return "rel\(id)"
            case .finish: return "fin"
            }
        }
    }

    struct Outcome {
        var branching: [Int]
        var failure: String?
        var writes: Int
    }

    /// One schedule: `choices` picks among the enabled actions at each step (missing choices pick 0).
    @available(macOS 15.0, iOS 18.0, *)
    static func runSchedule(_ choices: [Int], requests: Int, withFinish: Bool, values: [AssetPriority], seq: String, random: UInt64? = nil) async throws -> Outcome {
        var rng = random ?? 0
        let rig = try Rig("s3dc2-sched-\(seq)")
        defer { rig.cleanUp() }
        let gated = GatedPriorityDriver(base: rig.driver)
        let coordinator = BackgroundTransferCoordinator(
            driver: gated,
            staging: rig.staging,
            options: rig.options,
            policy: BackgroundCoordinatorTests.policy,
            appKey: nil,
            requestTimeout: 30,
            log: .tapOnly(nil)
        )
        var events = gated.events.makeAsyncIterator()
        let job1 = rig.job(1)
        let h1 = try #require(await coordinator.start(job1) as? BackgroundTransferHandle)
        var handles: [BackgroundTransferHandle] = [h1]
        var current = h1
        var nextRequest = 0
        var pendingWrites: [Int: Int] = [:]  // write id -> request
        var listing: Int?  // request whose listing is held
        var running: [Int: Task<Void, Never>] = [:]
        var finished = false
        var branching: [Int] = []
        var trace: [String] = []
        var step = 0

        func handle(_ event: GatedPriorityDriver.Event?, of request: Int) -> String? {
            switch event {
            case .held(let id):
                pendingWrites[id] = request
                trace.append("held\(id)<-r\(request)")
            case .listing:
                listing = request
                trace.append("listing<-r\(request)")
            case .done(let k):
                if k != request { return "done(\(k)) but expected event of r\(request)" }
                trace.append("done\(k)")
            case nil:
                return "event stream ended"
            }
            return nil
        }

        while true {
            if Task.isCancelled { return Outcome(branching: branching, failure: "cancelled", writes: 0) }
            var enabled: [Action] = []
            if nextRequest < requests, !finished {
                enabled.append(.request(nextRequest, holdListing: false))
                if listing == nil {
                    enabled.append(.request(nextRequest, holdListing: true))
                }
            }
            if let listing {
                enabled.append(.releaseListing(listing))
            }
            for id in pendingWrites.keys.sorted() {
                enabled.append(.release(id))
            }
            if withFinish, !finished {
                enabled.append(.finish)
            }
            if enabled.isEmpty {
                break
            }
            var choice = step < choices.count ? choices[step] : 0
            if random != nil {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                choice = Int((rng >> 33) % UInt64(enabled.count))
            }
            branching.append(enabled.count)
            let action = enabled[choice]
            trace.append(action.description)
            step += 1
            switch action {
            case .request(let k, let hold):
                nextRequest += 1
                if k > 0 {
                    let joined = try #require(await coordinator.start(rig.job(UInt32(k + 1))) as? BackgroundTransferHandle)
                    if joined.name != h1.name { return Outcome(branching: branching, failure: "join did not join", writes: 0) }
                    handles.append(joined)
                    current = joined
                }
                if hold {
                    await gated.holdNextListing()
                }
                let token = current.token
                let name = current.name
                let value = values[k]
                running[k] = Task {
                    await coordinator.setPriority(value, of: name, token: token)
                    await gated.post(.done(k))
                }
                if let failure = handle(await events.next(), of: k) { return Outcome(branching: branching, failure: failure + " " + trace.joined(separator: " "), writes: 0) }
            case .releaseListing(let k):
                listing = nil
                await gated.releaseListing()
                if let failure = handle(await events.next(), of: k) { return Outcome(branching: branching, failure: failure + " " + trace.joined(separator: " "), writes: 0) }
            case .release(let id):
                let k = pendingWrites.removeValue(forKey: id)!
                await gated.release(id)
                if let failure = handle(await events.next(), of: k) { return Outcome(branching: branching, failure: failure + " " + trace.joined(separator: " "), writes: 0) }
            case .finish:
                finished = true
                await rig.driver.complete(job1.partialName, body: TransportFixtures.payload(4_000))
                let terminal = await run(current).terminal
                if terminal != BackgroundInterleavingTests.staged(job1) {
                    return Outcome(branching: branching, failure: "terminal \(String(describing: terminal)) " + trace.joined(separator: " "), writes: 0)
                }
                await gated.markFinished()
            }
        }
        for (_, task) in running {
            await task.value
        }
        let landed = await gated.landed
        let issued = await gated.issued
        let live = await coordinator.liveTransfers()
        let baseLast = await rig.driver.priorityChanges.last?.priority
        var failure: String?
        if finished {
            if issued.contains(where: { $0.afterFinish }) {
                failure = "write issued after the terminal: \(issued.map { "\($0.value)\($0.afterFinish ? "*" : "")" })"
            } else if !live.isEmpty {
                failure = "live after terminal: \(live)"
            }
        } else {
            let newest = values[requests - 1].urlSessionTaskPriority
            if landed.last?.value != newest || baseLast != newest {
                failure = "OS task ends at \(String(describing: landed.last?.value)) (base \(String(describing: baseLast))), newest request \(newest); landed \(landed.map(\.value))"
            } else if live.map(\.priority) != [newest] {
                failure = "liveTransfers \(live.map(\.priority)) != [\(newest)]"
            }
        }
        if let f = failure {
            failure = f + " | schedule: " + trace.joined(separator: " ")
        }
        withExtendedLifetime(handles) {}
        return Outcome(branching: branching, failure: failure, writes: landed.count)
    }

    /// Replay-based DFS over every schedule.
    @available(macOS 15.0, iOS 18.0, *)
    static func explore(_ tag: String, requests: Int, withFinish: Bool, values: [AssetPriority], cap: Int) async throws -> (runs: Int, failures: [String], maxWrites: Int, exhausted: Bool) {
        var choices: [Int] = []
        var runs = 0
        var failures: [String] = []
        var maxWrites = 0
        while runs < cap {
            if Task.isCancelled { break }
            let outcome = try await runSchedule(choices, requests: requests, withFinish: withFinish, values: values, seq: "\(tag)-\(runs)")
            runs += 1
            maxWrites = max(maxWrites, outcome.writes)
            if let failure = outcome.failure {
                failures.append(failure)
                if failures.count >= 5 { break }
            }
            // Next schedule: the full choice vector of this run, incremented from the end.
            var full = outcome.branching.indices.map { $0 < choices.count ? choices[$0] : 0 }
            var i = full.count - 1
            while i >= 0, full[i] + 1 >= outcome.branching[i] {
                i -= 1
            }
            if i < 0 {
                return (runs, failures, maxWrites, true)
            }
            full[i] += 1
            choices = Array(full[...i])
        }
        return (runs, failures, maxWrites, false)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("probe: every schedule of two overlapping attaches' priority requests ends at the newest", .timeLimit(.minutes(10)))
    func exhaustiveTwoAttaches() async throws {
        let result = try await Self.explore("two", requests: 2, withFinish: false, values: [.userInitiated, .bulk], cap: 50_000)
        print("PROBE exhaustiveTwoAttaches runs=\(result.runs) exhausted=\(result.exhausted) maxWrites=\(result.maxWrites) failures=\(result.failures.count)")
        for failure in result.failures { print("PROBE-FAIL \(failure)") }
        #expect(result.failures.isEmpty)
        #expect(result.exhausted)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("probe: every schedule of two attaches with a terminal anywhere issues no write after it", .timeLimit(.minutes(10)))
    func exhaustiveTwoWithFinish() async throws {
        let result = try await Self.explore("twofin", requests: 2, withFinish: true, values: [.userInitiated, .bulk], cap: 50_000)
        print("PROBE exhaustiveTwoWithFinish runs=\(result.runs) exhausted=\(result.exhausted) maxWrites=\(result.maxWrites) failures=\(result.failures.count)")
        for failure in result.failures { print("PROBE-FAIL \(failure)") }
        #expect(result.failures.isEmpty)
        #expect(result.exhausted)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("probe: every schedule of three attaches (with and without a terminal)", .timeLimit(.minutes(10)), arguments: [false, true])
    func exhaustiveThree(_ withFinish: Bool) async throws {
        let result = try await Self.explore("three-\(withFinish)", requests: 3, withFinish: withFinish, values: [.userInitiated, .prefetch, .bulk], cap: 40_000)
        print("PROBE exhaustiveThree finish=\(withFinish) runs=\(result.runs) exhausted=\(result.exhausted) maxWrites=\(result.maxWrites) failures=\(result.failures.count)")
        for failure in result.failures { print("PROBE-FAIL \(failure)") }
        #expect(result.failures.isEmpty)
        #expect(result.exhausted)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("probe: random schedules of three/four attaches end at the newest; with a terminal, no write after it", .timeLimit(.minutes(10)))
    func randomManyAttaches() async throws {
        var failures: [String] = []
        var maxWrites = 0
        var runs = 0
        let valueSets: [[AssetPriority]] = [[.userInitiated, .prefetch, .bulk], [.userInitiated, .bulk, .userInitiated, .bulk], [.bulk, .userInitiated, .prefetch, .userInitiated]]
        for seed in 1...1_500 {
            if Task.isCancelled { break }
            let values = valueSets[seed % valueSets.count]
            let outcome = try await Self.runSchedule([], requests: values.count, withFinish: seed % 4 == 0, values: values, seq: "random-\(seed)", random: UInt64(seed) &* 0x9E37_79B9_7F4A_7C15)
            runs += 1
            maxWrites = max(maxWrites, outcome.writes)
            if let failure = outcome.failure {
                failures.append("seed \(seed): \(failure)")
                if failures.count >= 5 { break }
            }
        }
        print("PROBE randomManyAttaches runs=\(runs) maxWrites=\(maxWrites) failures=\(failures.count)")
        for failure in failures { print("PROBE-FAIL \(failure)") }
        #expect(failures.isEmpty)
    }

    /// FIFO across kinds: a pause made after a held priority change reaches the driver only after it, and the attach
    /// then ends paused, which ends the control task.
    /// A replaced handle's buffered control reaches the coordinator while the joining handle's request lists the
    /// tasks: it must not supersede that request.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("probe: a replaced handle's late priority request never supersedes the current attach's request", .timeLimit(.minutes(1)))
    func staleHandleNeverSupersedes() async throws {
        let rig = try Rig("s3dc2-stale-supersede")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let first = try #require(await coordinator.start(rig.job(1)) as? BackgroundTransferHandle)
        let second = try #require(await coordinator.start(rig.job(2)) as? BackgroundTransferHandle)
        #expect(second.name == first.name)
        await rig.driver.holdNextSnapshot(.afterListing)
        let current = Task { await coordinator.setPriority(.userInitiated, of: second.name, token: second.token) }
        await rig.awaitSignal("snapshot")
        await coordinator.setPriority(.bulk, of: first.name, token: first.token)
        await rig.driver.releaseSnapshot()
        await current.value
        let changes = await rig.driver.priorityChanges.map(\.priority)
        #expect(changes == [0.75], "the current attach's promotion must land: \(changes)")
        #expect(await coordinator.liveTransfers().map(\.priority) == [0.75])
        withExtendedLifetime([first, second]) {}
    }

    /// D-10 timeline: the engine's shutdown calls `handle.cancel()` and later `remote.invalidate()`. A cancel queued
    /// behind a priority change still listing is delivered only after `invalidate()`, so it reaches no OS task.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("probe: a shutdown cancel queued behind a listing priority change reaches no OS task once invalidated", .timeLimit(.minutes(1)))
    func shutdownCancelQueuedBehindPriority() async throws {
        let rig = try Rig("s3dc2-shutdown-cancel")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let handle = try #require(await coordinator.start(rig.job(1)) as? BackgroundTransferHandle)
        await rig.driver.holdNextSnapshot(.afterListing)
        handle.setPriority(.userInitiated)
        await rig.awaitSignal("snapshot")
        handle.cancel()
        await coordinator.invalidate()
        await rig.driver.releaseSnapshot()
        let controlTask = handle.controlTask
        await withTaskCancellationHandler { await controlTask.value } onCancel: { controlTask.cancel() }
        let cancellations = await rig.driver.cancellations.map(\.producingResumeData)
        print("PROBE shutdownCancelQueuedBehindPriority cancellations=\(cancellations) priorityChanges=\(await rig.driver.priorityChanges.map(\.priority))")
        #expect(cancellations == [false], "the shutdown cancel never reached the OS task: \(cancellations)")
    }

    /// The mechanism behind the S2-19 test's TSan failure: `SessionDelegate` yields the terminal and calls
    /// `finish()` on the delegate queue; `finish()` releases the stream's lock and only then runs `onTermination`
    /// (where `ForegroundSession` ends the `transfer` interval). A reader that was not suspended at that moment reads
    /// the buffered terminal and the end of the stream while `onTermination` is still running.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("probe: a reader can see the end of an AsyncStream before its onTermination handler finished", .timeLimit(.minutes(1)))
    func readerSeesEndBeforeOnTermination() async {
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(4))
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let ended = Mutex(false)
        continuation.onTermination = { _ in
            entered.signal()
            release.wait()
            ended.withLock { $0 = true }
        }
        // The delegate queue: terminal element, then finish (which blocks inside onTermination here).
        let finisher = Thread {
            continuation.yield(1)
            continuation.finish()
        }
        finisher.start()
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                entered.wait()
                resume.resume()
            }
        }
        var got: [Int] = []
        for await element in stream {
            got.append(element)
        }
        let endedWhenReaderReturned = ended.withLock { $0 }
        release.signal()
        print("PROBE readerSeesEndBeforeOnTermination got=\(got) onTerminationDoneWhenReaderReturned=\(endedWhenReaderReturned)")
        #expect(got == [1])
        #expect(endedWhenReaderReturned, "the reader returned while onTermination (interval.end()) was still running")
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("probe: a pause queued behind a held priority change is delivered after it; the control task ends", .timeLimit(.minutes(1)))
    func pauseAfterPriorityInOrder() async throws {
        let rig = try Rig("s3dc2-pause-fifo")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let job = rig.job(1)
        let handle = try #require(await coordinator.start(job) as? BackgroundTransferHandle)
        await rig.driver.holdNextSnapshot(.afterListing)
        handle.setPriority(.userInitiated)
        await rig.awaitSignal("snapshot")
        handle.pause()
        // A whole listing runs meanwhile; the pause must not have reached the driver.
        _ = await coordinator.liveTransfers()
        #expect(await rig.driver.cancellations.isEmpty, "pause overtook the held priority change")
        await rig.driver.releaseSnapshot()
        let terminal = await run(handle).terminal
        #expect(terminal == .paused(resumable: false) || terminal == .paused(resumable: true), "terminal \(String(describing: terminal))")
        let controlTask = handle.controlTask
        await withTaskCancellationHandler { await controlTask.value } onCancel: { controlTask.cancel() }
        #expect(!Task.isCancelled)
        #expect(await rig.driver.priorityChanges.map(\.priority) == [0.75])
        #expect(await rig.driver.cancellations.map(\.producingResumeData) == [true])
    }

    /// Relay: the wait of the later handler consumes the earlier wake's finish (it began first); the oldest handler
    /// runs then, and the later one only after its own wake's events.
    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("probe: overlapping wakes whose waits begin in reverse order still call each handler after its own wake's events", .timeLimit(.minutes(1)))
    func reverseWaitOrder() async throws {
        let rig = try Rig("s3dc2-reverse-waits")
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        let first = rig.job(1, seed: 1)
        let second = rig.job(2, seed: 2)
        let handles = [await coordinator.start(first), await coordinator.start(second)]
        let relay = BackgroundEventsRelay()
        let ours = BackgroundCoordinatorTests.identifier.rawValue
        let staging = rig.staging
        var calls: [String] = []
        #expect(relay.accept(identifier: ours) { calls.append("first staged: \(staging.contents[first.partialName] != nil)") })
        #expect(relay.accept(identifier: ours) { calls.append("second staged: \(staging.contents[second.partialName] != nil)") })
        // Wake 1's events end before either wait begins.
        await rig.driver.complete(first.partialName, body: TransportFixtures.payload(4_000, seed: 1))
        await rig.driver.finishEvents()
        // The second handler's task waits first and consumes wake 1's finish.
        await coordinator.awaitBackgroundEvents()
        relay.complete(identifier: ours)
        #expect(calls == ["first staged: true"], "\(calls)")
        let firstTask = Task { @MainActor in
            await coordinator.awaitBackgroundEvents()
            relay.complete(identifier: ours)
        }
        await rig.driver.complete(second.partialName, body: TransportFixtures.payload(4_000, seed: 2))
        await rig.driver.finishEvents()
        await firstTask.value
        #expect(calls == ["first staged: true", "second staged: true"], "\(calls)")
        #expect(!relay.hasHandler(for: ours))
        withExtendedLifetime(handles) {}
    }

    /// Many handlers, completions interleaved with accepts: each runs exactly once, oldest first, never more
    /// completions than handlers.
    @MainActor
    @Test("probe: relay calls each of many handlers exactly once, oldest first")
    func relayManyHandlers() {
        let relay = BackgroundEventsRelay()
        let ours = BackgroundCoordinatorTests.identifier.rawValue
        var calls: [Int] = []
        var accepted = 0
        var completed = 0
        var rng = UInt64(0x5eed)
        for _ in 0..<2_000 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            if (rng >> 33) % 2 == 0 || completed == accepted {
                let n = accepted
                #expect(relay.accept(identifier: ours) { calls.append(n) })
                accepted += 1
            } else {
                relay.complete(identifier: ours)
                completed += 1
            }
            #expect(relay.hasHandler(for: ours) == (accepted > completed))
        }
        while completed < accepted {
            relay.complete(identifier: ours)
            completed += 1
        }
        relay.complete(identifier: ours)
        #expect(calls == Array(0..<accepted))
        #expect(!relay.hasHandler(for: ours))
        #expect(!relay.accept(identifier: "com.apple.other") {})
    }
}
