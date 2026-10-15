import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Regressions the level-4 verifiers found (WP-F fix round 1). Each test failed before its fix.
@Suite("Engine regressions")
struct EngineRegressionTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a resolve cancelled while its failed attempt is handled leaves no stale drain, so the next resolve downloads", .timeLimit(.minutes(1)))
    func cancelDuringFailureHandlingLeavesNoDrain() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(metadata: metadata)
        let bytes = EngineFixture.bytes(501)
        let entry = EngineHarness.onDemand("od", bytes)
        await harness.serveManifest([entry])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(entry.transferID, [.hold])
        let first = Task { await engine.awaitAsset("od", lane: .userInitiated) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(entry.transferID)
        let driver = try #require(await engine.activeDriver(entry.transferID))
        await metadata.setHolding(true)
        // The failure's handling reads the attempt's sidecar (a metadata unit) after the driver consumed the stream's
        // terminal element; the caller cancels while that read is held.
        await harness.source.release(entry.transferID, with: .failed(.transient(.timedOut, retryAfter: nil)))
        try await metadata.requireHeldUnits(atLeast: 1)
        first.cancel()
        #expect(await first.value == .failure(.cancelled))
        await metadata.setHolding(false)
        await engine.awaitCondition { !$0.ownsTask(driver) }
        let stale = await engine.drainingTransfers()
        #expect(stale.isEmpty, "an attempt whose stream already ended is never left draining")
        #expect(await engine.invariantViolations().isEmpty)
        await harness.source.script(entry.transferID, [.stage(bytes)])
        if stale.isEmpty {
            let location = try await engine.awaitAsset("od", lane: .userInitiated).get()
            #expect(location.byteSize == Int64(bytes.count))
            #expect(await harness.source.starts.count == 2)
        }
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run whose job is superseded while it publishes still settles once its asset's new content commits", .timeLimit(.minutes(1)))
    func supersededRunJobSettles() async throws {
        let bulk = NextUnitGate()
        let harness = EngineHarness.make(bulk: bulk)
        let old = EngineFixture.bytes(601)
        let new = EngineFixture.bytes(602)
        let v1 = EngineFixture.entry("x", old)
        let v2 = EngineFixture.entry("x", new)
        await harness.serveManifest([v1])
        await harness.source.script(v1.transferID, [.hold, .stage(old)])
        try await harness.start()
        let engine = harness.engine
        // The launch run's job for x@v1 holds its transfer; `sync` joins that run.
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(v1.transferID)
        let run = Task { await engine.sync(.force) }
        await engine.awaitCondition { !$0.state.syncJoiners.isEmpty }
        // x@v1's publication is held at its first store unit.
        await bulk.holdNext()
        await harness.source.release(v1.transferID, with: .progress(received: 0, expected: nil))
        await bulk.waitForHold()
        // ensureAvailable applies v2 (x changed) meanwhile and starts x@v2 itself (held at its transfer).
        await harness.serveManifest([v2], etag: "v2")
        await harness.source.script(v2.transferID, [.hold, .stage(new)])
        let ensure = Task { await engine.ensureAvailable(scope: .all) }
        await engine.awaitCondition { $0.state.jobs[v2.transferID]?.active?.handle != nil }
        // x@v1's publication finds x superseded; the run's interest follows x to x@v2.
        await bulk.release()
        await engine.waitForJobEnd(v1.transferID)
        await harness.source.release(v2.transferID, with: .progress(received: 0, expected: nil))
        let ensured = try await ensure.value.get()
        #expect(ensured.isComplete)
        await engine.waitUntil { $0.jobsByState.isEmpty }
        let settled = await engine.runSettledOrGone()
        #expect(settled, "every job ended, so the run settles")
        guard settled else {
            await engine.shutdown()
            _ = await run.value
            return
        }
        let outcome = await run.value
        #expect(outcome.completeReport?.fetched == 1, "the run counts x, committed at its new content: \(outcome)")
        #expect(await engine.invariantViolations().isEmpty)
        #expect(await harness.source.starts.count == 2, "x@v2 is fetched once, for the run and ensureAvailable together")
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a waiter whose asset changed content while its shared job published follows the new content", .timeLimit(.minutes(1)))
    func unboundWaiterFollowsNewContent() async throws {
        let bulk = NextUnitGate()
        let harness = EngineHarness.make(bulk: bulk)
        let shared = EngineFixture.bytes(651)
        let changed = EngineFixture.bytes(652)
        let y = EngineHarness.onDemand("y", shared)
        let z = EngineHarness.onDemand("z", shared)
        let z2 = EngineHarness.onDemand("z", changed)
        await harness.serveManifest([y, z])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        // y and z share one job (one content); its transfer is held.
        await harness.source.script(y.transferID, [.hold, .stage(shared)])
        let first = Task { await engine.awaitAsset("y", lane: .userInitiated) }
        let second = Task { await engine.awaitAsset("z", lane: .userInitiated) }
        await engine.waitUntil { $0.waiters == 2 && $0.running == 1 }
        await engine.waitForHandle(y.transferID)
        await bulk.holdNext()
        await harness.source.release(y.transferID, with: .progress(received: 0, expected: nil))
        await bulk.waitForHold()
        // A run applies v2, where z has new content, while the shared publication is held.
        await harness.serveManifest([y, z2], etag: "v2")
        await harness.source.script(z2.transferID, [.stage(changed)])
        _ = try #require(await engine.sync(.force).completeReport)
        await bulk.release()
        let bound = try await first.value.get()
        #expect(bound.byteSize == Int64(shared.count))
        let followed = await second.value
        #expect(followed.map(\.byteSize) == .success(Int64(changed.count)), "z follows its new content, got \(followed)")
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-10: ensureAvailable's apply announces pruned ids and stops their jobs, as a run's apply does", .timeLimit(.minutes(1)))
    func ensureAvailableApplyFollowsPrunes() async throws {
        let harness = EngineHarness.make()
        let keepBytes = EngineFixture.bytes(701)
        let goneBytes = EngineFixture.bytes(702)
        let keep = EngineFixture.entry("keep", keepBytes)
        let gone = EngineFixture.entry("gone", goneBytes)
        let later = EngineHarness.onDemand("later", EngineFixture.bytes(703))
        await harness.serveManifest([keep, gone, later])
        await harness.scriptTransfers([(keep, keepBytes), (gone, goneBytes)])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        // A prefetch of the on-demand asset holds its transfer.
        await harness.source.script(later.transferID, [.hold])
        let group = try await engine.registerGroup(["later"], lane: .prefetch).get()
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(later.transferID)
        let probe = EventProbe(stream: try await engine.subscribe().get())
        await harness.serveManifest([keep], etag: "v2")
        let report = try await engine.ensureAvailable(scope: .all).get()
        #expect(report.isComplete && report.manifestFresh)
        let controls = await harness.source.controlLog
        #expect(controls.contains(FakeControlRecord(transfer: later.transferID, control: .cancel)), "the pruned asset's transfer is cancelled")
        await engine.waitForJobEnd(later.transferID)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.releaseGroup(group)
        await engine.shutdown()
        _ = await probe.next { $0 == .clientShutDown }
        let events = await probe.received
        #expect(events.contains(.assetRemoved("gone", .pruned)))
        #expect(events.contains(.assetRemoved("later", .pruned)))
        #expect(events.contains { if case .snapshotChanged = $0 { return true } else { return false } })
        await probe.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-5: a retention scope set while start is in progress reaches the store", .timeLimit(.minutes(1)))
    func retentionScopeDuringStart() async throws {
        let source = FakeRemoteSource()
        let factory = GatedSourceFactory(source: source)
        let harness = EngineHarness.make(source: source, factory: factory)
        let keptBytes = EngineFixture.bytes(801)
        let otherBytes = EngineFixture.bytes(802)
        let kept = EngineFixture.entry("kept", keptBytes)
        let other = EngineFixture.entry("other", otherBytes)
        await harness.serve([(kept, keptBytes), (other, otherBytes)])
        let engine = harness.engine
        let start = Task { await engine.start() }
        // `start()` opened the store and pushed the scope in force (`.all`); it now waits for the source.
        await factory.waitUntilEntered()
        #expect((try? await engine.setRetentionScope(.identifiers(["kept"])).get()) != nil)
        await factory.open()
        _ = try await start.value.get()
        _ = await engine.sync(.force)
        let report = try await harness.store.adoptionReport()
        #expect(report.excludedRemotePaths == [other.remotePath], "the store excludes what the engine's scope excludes")
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: a caller cancelled while start runs gets cancelled, never shutDown", .timeLimit(.minutes(1)))
    func cancelledDuringStart() async throws {
        let source = FakeRemoteSource()
        let factory = GatedSourceFactory(source: source)
        let harness = EngineHarness.make(source: source, factory: factory)
        let engine = harness.engine
        let start = Task { await engine.start() }
        await factory.waitUntilEntered()
        let due = Task { await engine.isSyncDue() }
        await engine.awaitCondition { $0.state.startJoiners.count >= 2 }
        due.cancel()
        #expect(await due.value == .failure(.cancelled))
        await factory.open()
        _ = try await start.value.get()
        let after = await engine.isSyncDue()
        #expect((try? after.get()) != nil, "the engine still serves: \(after)")
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-2: an identifier a run's fetched manifest lists is never answered notFound before the run applies it", .timeLimit(.minutes(1)))
    func newestManifestAnswersUnknownWaiter() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(metadata: metadata)
        let firstBytes = EngineFixture.bytes(901)
        let lateBytes = EngineFixture.bytes(902)
        let first = EngineFixture.entry("first", firstBytes)
        let late = EngineFixture.entry("late", lateBytes)
        await harness.serve([(first, firstBytes)])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        // Unknown in the applied manifest and in a fresh one: answered notFound and cached.
        #expect(await engine.awaitAsset("late", lane: .userInitiated) == .failure(.notFound))
        await harness.serveManifest([first, late], etag: "v2")
        // Two attempts at most: when the waiter's job commits after the run planned "late", the run fetches it again
        // (its plan is a snapshot; a known, harmless re-download, reported as an open issue of this round).
        await harness.source.script(late.transferID, [.stage(lateBytes), .stage(lateBytes)])
        await metadata.setHolding(true)
        // The run fetches v2 (which lists "late") and is held at its free-space read, before `apply`.
        let run = Task { await engine.sync(.force) }
        try await metadata.requireHeldUnits(atLeast: 1)
        let resolve = Task { await engine.awaitAsset("late", lane: .userInitiated) }
        // Either answered at once or registered while the run still holds v2 unapplied.
        await untilFinishedOrObserved(resolve, engine) { $0.waiters >= 1 }
        await metadata.setHolding(false)
        let result = await resolve.value
        #expect(result.map(\.byteSize) == .success(Int64(lateBytes.count)), "answered from the newest manifest, got \(result)")
        _ = await run.value
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-13: runs that keep failing offline while the path reads satisfied run again only after a network edge, never on a timer", .timeLimit(.minutes(1)))
    func offlineRunWaitsForAnEdge() async throws {
        let harness = EngineHarness.make()
        let engine = harness.engine
        let debounce = harness.configuration.tuning.pendingRunDebounce
        let bytes = EngineFixture.bytes(1_001)
        let entry = EngineFixture.entry("e", bytes)
        await harness.source.scriptManifest([.fail(.offline(.noConnection)), .fail(.offline(.noConnection))])
        let probe = EventProbe(stream: try await engine.subscribe().get())
        try await harness.start()
        #expect(await engine.sync(.force) == .failed(.offline))
        // One debounced retry covers a path monitor that reported a moment early; it fails offline too. The clock moves
        // by the debounce only (never to the manifest fetch's deadline).
        await engine.awaitCondition { $0.state.heap.deadline(for: .pendingRun) != nil }
        harness.time.advance(by: debounce)
        let retried = await probe.next { event in
            if case .syncFinished(let id, _) = event {
                return id.rawValue == 2
            }
            return false
        }
        guard case .syncFinished(_, .failed(.offline))? = retried else {
            Issue.record("expected one debounced retry that fails offline, got \(String(describing: retried))")
            await engine.shutdown()
            return
        }
        #expect(await harness.source.manifestRequests.count == 2)
        let now = harness.time.monotonicNow()
        #expect(harness.time.nextDeadline.map { $0 > now.adding(seconds: 3_600) } ?? true, "no timer brings the run back")
        harness.time.advance(by: 3_600)
        #expect(await harness.source.manifestRequests.count == 2)
        // A real edge (unsatisfied, then satisfied) starts the pending run after its debounce.
        await harness.serveManifest([entry])
        await harness.source.script(entry.transferID, [.stage(bytes)])
        let offline = DeviceConditions(network: NetworkConditions(satisfied: false, expensive: false, constrained: false), power: DeviceConditions.unrestricted.power)
        await harness.conditions.send(offline)
        await engine.awaitCondition { $0.state.conditions?.network.satisfied == false }
        await harness.conditions.send(.unrestricted)
        await engine.awaitCondition { $0.state.heap.deadline(for: .pendingRun) != nil }
        harness.time.advance(by: debounce)
        let finished = await probe.next { event in
            if case .syncFinished(let id, _) = event {
                return id.rawValue == 3
            }
            return false
        }
        guard case .syncFinished(_, .complete(let report))? = finished else {
            Issue.record("expected the pending run to complete, got \(String(describing: finished))")
            await engine.shutdown()
            return
        }
        #expect(report.trigger == .conditionsChanged && report.fetched == 1 && report.manifestFresh)
        #expect(await harness.source.manifestRequests.count == 3)
        await probe.stop()
        await engine.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a resolve that joins a job blocked for lack of space is answered at once, as a new job would be", .timeLimit(.minutes(1)))
    func joinerOfBlockedJobFailsFast() async throws {
        // The volume holds both entries but not the 5,000 bytes a's ENOSPC asks for, so a parks (F-20: on a volume that
        // holds the transfer the ENOSPC is transient and retried instead).
        let harness = EngineHarness.make(capacity: StoragePolicy().reserveFreeBytes + 4_096)
        let aBytes = EngineFixture.bytes(1_101)
        let bBytes = EngineFixture.bytes(1_102)
        let a = EngineFixture.entry("a", aBytes)
        let b = EngineFixture.entry("b", bBytes)
        await harness.serveManifest([a, b])
        await harness.source.script(a.transferID, [.fail(.insufficientSpace(requiredBytes: 5_000))])
        await harness.source.script(b.transferID, [.hold, .stage(bBytes)])
        try await harness.start()
        let engine = harness.engine
        // The launch run: a is blocked for lack of space (its figures read), b still downloads, so the run is open.
        await engine.awaitCondition { engine in
            engine.state.jobs[a.transferID]?.lastError != nil && engine.state.jobs[b.transferID]?.active?.handle != nil
        }
        let resolve = Task { await engine.awaitAsset("a", lane: .userInitiated) }
        await untilFinishedOrObserved(resolve, engine) { $0.waiters >= 1 }
        await harness.source.release(b.transferID, with: .progress(received: 0, expected: nil))
        await engine.waitUntil { $0.groups == 0 }
        let waiting = await engine.introspect().waiters
        #expect(waiting == 0, "the joiner was answered")
        if waiting > 0 {
            resolve.cancel()
        }
        let result = await resolve.value
        guard case .failure(.insufficientSpace(let required, _)) = result else {
            Issue.record("expected insufficientSpace, got \(result)")
            await engine.shutdown()
            return
        }
        #expect(required == 5_000)
        #expect(await engine.invariantViolations().isEmpty)
        await engine.shutdown()
    }
}
