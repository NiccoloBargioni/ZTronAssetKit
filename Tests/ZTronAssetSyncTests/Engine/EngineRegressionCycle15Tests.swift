import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A source that holds the next manifest fetch until the test releases it; every other call goes to the fake. A test
/// orders a fetch that has already passed the engine's throttle check against a transfer's 429 that arrives meanwhile.
/// Its waits end on cancellation, and the held fetch ends on its own task's cancellation or the source's invalidation (a
/// shutdown), so no wait outlives the test (L4-R17). An actor: no lock (C1).
@available(macOS 15.0, iOS 18.0, *)
actor HeldManifestSource: RemoteSource, StagingAttachable {
    nonisolated let base: FakeRemoteSource
    private var armed = false
    private var held: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var heldWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var lastKey: UInt64 = 0

    init(base: FakeRemoteSource) {
        self.base = base
    }

    nonisolated var originID: String {
        self.base.originID
    }

    nonisolated var capabilities: RemoteSourceCapabilities {
        self.base.capabilities
    }

    /// Holds the next manifest fetch until `release()`.
    func holdNext() {
        self.armed = true
    }

    /// Suspends until a fetch is held; ends on the caller's cancellation.
    func waitForHeldFetch() async {
        self.lastKey += 1
        let key = self.lastKey
        // REENTRANCY: nothing: a terminal test wait, resumed once by a held fetch or by the caller's cancellation.
        await withTaskCancellationHandler {
            // REENTRANCY: as above.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if !self.held.isEmpty || Task.isCancelled {
                    continuation.resume()
                } else {
                    self.heldWaiters[key] = continuation
                }
            }
        } onCancel: {
            Task {
                // REENTRANCY: nothing: the hop resumes only this wait.
                await self.resumeWaiter(key)
            }
        }
    }

    /// Lets every held fetch proceed.
    func release() {
        let held = self.held
        self.held.removeAll()
        for key in held.keys.sorted() {
            held[key]?.resume()
        }
    }

    private func resumeWaiter(_ key: UInt64) {
        self.heldWaiters.removeValue(forKey: key)?.resume()
    }

    private func resumeHeld(_ key: UInt64) {
        self.held.removeValue(forKey: key)?.resume()
    }

    func attach(staging: any StagingSink) async {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.attach(staging: staging)
    }

    func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        if self.armed {
            self.armed = false
            self.lastKey += 1
            let key = self.lastKey
            // REENTRANCY: nothing: resumed once by `release()`, `invalidate()` or the fetch task's cancellation; the
            // fetch then goes to the base source.
            await withTaskCancellationHandler {
                // REENTRANCY: as above.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if Task.isCancelled {
                        continuation.resume()
                        return
                    }
                    self.held[key] = continuation
                    let waiters = self.heldWaiters
                    self.heldWaiters.removeAll()
                    for waiter in waiters.keys.sorted() {
                        waiters[waiter]?.resume()
                    }
                }
            } onCancel: {
                Task {
                    // REENTRANCY: nothing: the hop resumes only this fetch.
                    await self.resumeHeld(key)
                }
            }
        }
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        return try await self.base.fetchManifest(request)
    }

    func transfer(_ request: TransferRequest) async -> any TransferHandle {
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.transfer(request)
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
        self.release()
        // REENTRANCY: nothing: a pass-through to the base source; no state is read afterwards.
        await self.base.invalidate()
    }
}

/// Pins from close-out cycle 15 of the level-4 close-out (`docs/adr-drafts/f.md`, F-35).
@Suite("Engine regressions, close-out cycle 15")
struct EngineRegressionCycle15Tests {
    /// Whether the engine has applied everything it began: no run, no store work, no deadline at or before the clock, and
    /// no owned task but the alarm, the conditions watcher and a memory-pressure observer (each of which acts only on a
    /// deadline, an element or an event). A test moves the clock only from such a state, so the move never races a step
    /// the engine has not applied yet (L4-R17).
    static func quiet(_ engine: isolated SyncEngine) -> Bool {
        let now = engine.environment.time.monotonicNow()
        let allowed = [engine.state.alarm?.task, engine.state.watcher?.task, engine.state.pressure.task].compactMap { $0 }
        return engine.state.run == nil && engine.state.storeWorkRuns == 0 && (engine.state.heap.first.map { $0.at > now } ?? true)
            && engine.state.tasks.keys.allSatisfy { allowed.contains($0) }
    }

    // MARK: A manifest 429 never moves the origin's throttle deadline earlier (R-SYN-5, R-SYN-13, R-SYN-14; cycle-14 verifier)

    /// A run's manifest fetch passes the throttle check, and while it is in flight a prefetch transfer answers 429 with a
    /// 60 s retry-after: the origin is throttled until then, the job parked, the `.throttle` deadline at that end. The
    /// fetch then answers 429 with a 1 s retry-after. The origin's throttle kept the later end, but the manifest path
    /// scheduled the deadline, and reported the run's block, at its own earlier end; at that end the alarm found the
    /// throttle still in force and dropped the deadline, so nothing re-admitted the parked job at the real end, and the
    /// pending run, armed at that (by then past) end, started a run that planned the parked job, settled blocked by the
    /// throttle and re-armed itself at once: 300 runs and manifest requests without the clock moving (the cycle-14
    /// correctness verifier's PROBE-THROTTLEEARLY).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a manifest 429 shorter than the origin's throttle leaves the throttle's deadline at its end, where its parked job resumes and no run repeats", .timeLimit(.minutes(1)))
    func manifestThrottleKeepsTheLaterEnd() async throws {
        let fake = FakeRemoteSource()
        let held = HeldManifestSource(base: fake)
        let harness = EngineHarness.make(source: fake, remote: held)
        let bytes = EngineFixture.bytes(4_343)
        let onDemand = EngineHarness.onDemand("asset", bytes)
        let standard = EngineFixture.entry("asset", bytes)
        try #require(onDemand.transferID == standard.transferID, "setup: one transfer for both policies")
        await harness.serveManifest([onDemand])
        let engine = harness.engine
        let time = harness.time
        let origin = fake.originID
        try await harness.start()
        // The launch run applies the on-demand entry and downloads nothing.
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        // The next fetch passes the throttle check (nothing is throttled yet) and is held; it then answers 429 with a 1 s
        // retry-after. The fetch after it makes the entry standard, so a run plans it.
        await fake.scriptManifest([
            .fail(.transient(.throttled, retryAfter: .seconds(1))),
            .fetched(EngineFixture.manifestData([standard]), etag: EngineFixture.etag("v2")),
        ])
        await held.holdNext()
        let run = Task { await engine.sync(.force) }
        await held.waitForHeldFetch()
        // Meanwhile a prefetch caller's transfer answers 429 with a 60 s retry-after.
        await fake.script(onDemand.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(bytes)])
        let caller = Task { await engine.awaitAsset(onDemand.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[onDemand.transferID]?.state.isThrottleParked == true }
        let parked = await engine.readForTests { engine in
            (engine.state.throttles[origin], engine.state.heap.deadline(for: .throttle(origin)))
        }
        let throttleEnd = try #require(parked.0, "setup: the transfer's 429 throttles the origin")
        try #require(parked.1 == throttleEnd, "setup: the throttle's deadline is at its end")
        // The held fetch's 429 arrives, its own end earlier than the origin's.
        await held.release()
        let outcome = await joinCancelling(run)
        let after = await engine.readForTests { engine in
            (engine.state.throttles[origin], engine.state.heap.deadline(for: .throttle(origin)), engine.state.heap.deadline(for: .pendingRun))
        }
        #expect(after.0 == throttleEnd, "the origin's throttle keeps its later end")
        #expect(after.1 == throttleEnd, "the throttle's deadline stays at the throttle's end \(throttleEnd): \(String(describing: after.1))")
        #expect(after.2 == throttleEnd, "the pending run waits for the throttle's end: \(String(describing: after.2))")
        if case .blocked(.throttled(let until), _) = outcome {
            #expect(until == throttleEnd, "the run reports the throttle's end \(throttleEnd), not \(until)")
        } else {
            Issue.record("the run is blocked by the throttle: \(outcome)")
        }
        // The clock reaches the throttle's deadline once the engine is quiet, and the alarm fires it.
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        let first = try #require(after.1, "the throttle's deadline")
        time.advance(to: first)
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        // A parked job that nothing would re-admit is an invariant violation (the deadline the alarm dropped).
        let midway = await engine.invariantViolations()
        #expect(midway.isEmpty, "\(midway)")
        let baseRuns = await engine.readForTests { $0.state.lastRunID }
        let baseRequests = await fake.manifestRequests.count
        // The clock passes the throttle's end. A run that settles blocked by a throttle whose end has passed starts the
        // next one at once, again and again without the clock moving: the wait ends after 20 of them.
        time.advance(to: throttleEnd.adding(seconds: 1))
        await engine.awaitCondition { engine in
            let resumed = engine.state.jobs[onDemand.transferID].map { !$0.state.isThrottleParked } ?? true
            return (resumed && EngineRegressionCycle15Tests.quiet(engine)) || engine.state.lastRunID >= baseRuns + 20
        }
        let end = await engine.readForTests { engine in
            (engine.state.jobs[onDemand.transferID]?.state, engine.state.lastRunID - baseRuns, engine.state.throttles[origin])
        }
        let requests = await fake.manifestRequests.count
        #expect(end.0.map { !$0.isThrottleParked } ?? true, "the job is still parked by a throttle that ended: \(String(describing: end.0))")
        #expect(end.1 == 0, "runs started after the throttle's end with nothing new to do: \(end.1)")
        #expect(requests - baseRequests == 0, "manifest requests after the throttle's end: \(requests - baseRequests)")
        #expect(requests == 3, "the launch run's, the throttled one and the pending run's: \(requests)")
        #expect(end.2 == nil, "the throttle ended")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
        let located = await joinCancelling(caller)
        #expect(try located.get().id == onDemand.identifier, "the prefetch caller gets its asset")
    }

    // MARK: A throttle deadline that fires before the throttle's end is kept (R-SYN-5, R-SYN-14; cycle-14 verifier)

    /// Only the `.throttle` deadline re-admits the jobs a throttle parked (`unblockOrigin(.throttled)` when it fires at
    /// the throttle's end). One that fired before the end, with the throttle still in force, was dropped, leaving those
    /// jobs parked for ever (the mechanism of the test above). The alarm now keeps it at the throttle's end. An earlier
    /// deadline is put into the heap directly, the state the manifest path left until close-out cycle 15; before that, the
    /// invariant check is shown to name a parked job whose deadline is gone.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a throttle deadline that fires before the origin's throttle ends is kept at the throttle's end, where its parked job resumes", .timeLimit(.minutes(1)))
    func earlyThrottleDeadlineIsKept() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(4_344)
        let onDemand = EngineHarness.onDemand("asset", bytes)
        await harness.serveManifest([onDemand])
        let engine = harness.engine
        let time = harness.time
        let origin = harness.source.originID
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        await harness.source.script(onDemand.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(60))), .stage(bytes)])
        let caller = Task { await engine.awaitAsset(onDemand.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[onDemand.transferID]?.state.isThrottleParked == true }
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        // The invariant check names a parked job that nothing will re-admit: the state a dropped deadline leaves.
        let unwakeable = await engine.violations { $0.heap.remove(.throttle(origin)) }
        #expect(unwakeable.contains("nothing will re-admit the 1 jobs the throttle parked"), "\(unwakeable)")
        let (early, recorded) = await engine.readForTests { engine -> (MonotonicInstant, MonotonicInstant?) in
            let early = engine.environment.time.monotonicNow().adding(seconds: 1)
            engine.state.heap.schedule(.throttle(origin), at: early)
            engine.rearm()
            return (early, engine.state.throttles[origin])
        }
        let throttleEnd = try #require(recorded, "setup: the transfer's 429 throttles the origin")
        try #require(early < throttleEnd, "setup: the deadline comes before the throttle's end")
        time.advance(to: early)
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        let kept = await engine.readForTests { engine in
            (engine.state.heap.deadline(for: .throttle(origin)), engine.state.jobs[onDemand.transferID]?.state.isThrottleParked, engine.invariantViolations())
        }
        #expect(kept.0 == throttleEnd, "the throttle's deadline is kept at its end \(throttleEnd): \(String(describing: kept.0))")
        #expect(kept.1 == true, "the job stays parked until the throttle's end")
        #expect(kept.2.isEmpty, "\(kept.2)")
        // At the throttle's end the job resumes and the caller gets its asset.
        time.advance(to: throttleEnd)
        await engine.awaitCondition { EngineRegressionCycle15Tests.quiet($0) }
        let job = await engine.readForTests { $0.state.jobs[onDemand.transferID]?.state }
        #expect(job == nil, "the job resumed at the throttle's end: \(String(describing: job))")
        await engine.shutdown()
        let located = await joinCancelling(caller)
        #expect(try located.get().id == onDemand.identifier, "the prefetch caller gets its asset")
    }
}
