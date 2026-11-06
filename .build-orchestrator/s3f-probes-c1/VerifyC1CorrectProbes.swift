import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Independent close-out verification probes (s3f, cycle 1, correctness lens). Scratch only, never committed.
@Suite("VerifyC1Correct probes")
struct VerifyC1CorrectProbes {
    // MARK: S3F-1 (S3-CONC-04), own variant: a user-lane group, no waiter

    /// A user-lane group (no waiter, so no fail-fast answer) keeps a job whose attempt failed offline before the
    /// engine's first reading after an idle teardown; the first satisfied reading must retry it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-V1: a user-lane group's job that failed offline before the first reading is retried by that reading", .timeLimit(.minutes(1)))
    func userGroupOfflineBeforeFirstReading() async throws {
        let rig = try await FirstReadingRig.make()
        let engine = rig.engine
        let id = rig.entry.transferID
        await rig.source.script(id, [.fail(.offline(.noConnection)), .stage(rig.bytes)])
        let group = try await engine.registerGroup([rig.entry.identifier], lane: .userInitiated).get()
        await rig.awaitHeldObservation()
        await engine.awaitCondition { $0.state.jobs[id]?.state == .failed(.whenOnline) }
        #expect(await engine.readForTests { $0.state.conditions == nil }, "the failure came before any reading")
        #expect(await rig.source.starts.count == 1)
        await rig.gated.release()
        await engine.awaitCondition { $0.state.conditions != nil }
        let after = await engine.readForTests { $0.state.jobs[id]?.state }
        try #require(after != .failed(.whenOnline), "PROBE-V1 FAIL: satisfied first reading left the job \(String(describing: after))")
        await engine.waitUntil { $0.jobsByState.isEmpty }
        #expect(await rig.source.starts.count == 2, "one retry")
        let present = await engine.awaitAsset(rig.entry.identifier, lane: .userInitiated)
        #expect((try? present.get()) != nil, "\(present)")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    /// Regression hunt for the S3F-1 fix: a first satisfied reading is an edge; with nothing failed it must not start
    /// anything extra, and a pending run must not be started early by it. Here: a user resolve succeeds before the first
    /// reading; the reading must re-queue nothing (one start in total) and leave no invariant violation.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-V1b: a first satisfied reading with nothing failed starts nothing extra", .timeLimit(.minutes(1)))
    func firstReadingWithNothingFailed() async throws {
        let rig = try await FirstReadingRig.make()
        let engine = rig.engine
        let id = rig.entry.transferID
        await rig.source.script(id, [.stage(rig.bytes)])
        let answer = await engine.awaitAsset(rig.entry.identifier, lane: .userInitiated)
        #expect((try? answer.get()) != nil, "\(answer)")
        await rig.gated.release()
        await engine.waitUntil { $0.jobsByState.isEmpty && !$0.watcherActive }
        #expect(await rig.source.starts.count == 1, "no extra start")
        let violations = await engine.readForTests { $0.invariantViolations() }
        #expect(violations.isEmpty, "\(violations)")
        await engine.shutdown()
    }

    // MARK: S3F-3 (S3-CONF-03), own variant: a healthy asset beside the capped one, standard policy

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-V3: a run over a healthy asset and one failed at the integrity cap reports exactly the capped one and writes no stamp", .timeLimit(.minutes(1)))
    func integrityCapBesideHealthy() async throws {
        let harness = EngineHarness.make()
        let good = EngineFixture.bytes(9_301)
        let corrupt = EngineHarness.onDemand("capped", EngineFixture.bytes(9_302))
        let healthy = EngineFixture.entry("healthy", good)
        await harness.serveManifest([corrupt, healthy])
        await harness.source.script(healthy.transferID, [.stage(good)])
        await harness.source.script(corrupt.transferID, Array(repeating: FakeTransferStep.stage(EngineFixture.bytes(9_303)), count: 8))
        try await harness.start()
        let first = await harness.engine.sync(.force)
        _ = first
        let engine = harness.engine
        await engine.awaitCondition { $0.state.jobs[healthy.transferID] == nil && $0.state.run == nil }
        for _ in 0..<harness.configuration.storage.maxIntegrityAttempts + 2 {
            _ = await engine.awaitAsset("capped", lane: .userInitiated)
            await engine.awaitCondition { $0.state.jobs[corrupt.transferID] == nil }
            harness.time.advance(by: 700)
            await EngineFailurePathTests.settleDue(engine, time: harness.time)
        }
        guard case .failed(.integrity)? = try await harness.view().records["capped"]?.residency else {
            Issue.record("PROBE-V3 setup: the record is not failed(.integrity)")
            await engine.shutdown()
            return
        }
        let stampBefore = try await harness.view().stamp
        let outcome = await engine.sync(.force)
        guard case .completeWithFailures(let report) = outcome else {
            Issue.record("PROBE-V3 FAIL: a run over an integrity-capped asset ended \(outcome)")
            await engine.shutdown()
            return
        }
        #expect(report.failures.map(\.id) == ["capped"], "\(report.failures)")
        #expect(report.failures.first?.failureClass == .integrity)
        #expect(try await harness.view().stamp == stampBefore, "no stamp")
        let healthyResidency = try await harness.view().records["healthy"]?.residency
        if case .present? = healthyResidency {} else {
            Issue.record("PROBE-V3: the healthy asset is \(String(describing: healthyResidency))")
        }
        await engine.shutdown()
    }

    // MARK: S3F-6 (S3-CONC-03), own variant: three runs, the middle one without progress

    @Test("PROBE-V6: a lagging subscriber across three runs gets every run's end before the next run's start and its start before its progress")
    func threeRunsOrder() {
        var queue = SubscriberQueue()
        let runs = (1...3).map { SyncRunID(rawValue: UInt64($0)) }
        func progress(_ fraction: Double) -> SyncProgress {
            SyncProgress(fraction: fraction, completedCount: 1, totalCount: 2, bytesReceived: 1, bytesExpected: 2)
        }
        var sequence: UInt64 = 0
        func publish(_ event: AssetEvent) {
            sequence += 1
            _ = queue.publish(event, sequence: sequence)
        }
        publish(.syncStarted(runs[0], .explicit))
        publish(.syncProgress(runs[0], progress(0.25)))
        publish(.syncProgress(runs[0], progress(0.5)))
        publish(.syncFinished(runs[0], .failed(.cancelled)))
        publish(.syncStarted(runs[1], .explicit))
        publish(.syncFinished(runs[1], .failed(.cancelled)))
        publish(.syncStarted(runs[2], .explicit))
        publish(.syncProgress(runs[2], progress(0.75)))
        var delivered: [AssetEvent] = []
        while let event = queue.take() {
            delivered.append(event)
        }
        func index(_ match: (AssetEvent) -> Bool) -> Int? {
            delivered.firstIndex(where: match)
        }
        for (position, run) in runs.enumerated() {
            let started = index { if case .syncStarted(let id, _) = $0 { return id == run }; return false }
            let finished = index { if case .syncFinished(let id, _) = $0 { return id == run }; return false }
            let progressed = delivered.indices.filter { if case .syncProgress(let id, _) = delivered[$0] { return id == run }; return false }
            for at in progressed {
                #expect(started.map { $0 < at } == true, "PROBE-V6 FAIL: run \(position + 1)'s progress before its start: \(delivered)")
                if let finished {
                    #expect(at < finished, "PROBE-V6 FAIL: run \(position + 1)'s progress after its end: \(delivered)")
                }
            }
            if position + 1 < runs.count, let finished {
                let next = index { if case .syncStarted(let id, _) = $0 { return id == runs[position + 1] }; return false }
                #expect(next.map { finished < $0 } == true, "PROBE-V6 FAIL: run \(position + 2) starts before run \(position + 1) ends: \(delivered)")
            }
        }
        #expect(delivered.contains(.syncProgress(runs[2], progress(0.75))), "run 3's progress is delivered: \(delivered)")
    }

    // MARK: S3F-4 (S3-PERF-01) concurrency hunt: cancellations and calls during the settle's yields

    /// 3 x shutdownStepsPerTurn + 7 waiters; while the shutdown settles over several turns, half the callers are
    /// cancelled and new calls arrive. Every caller ends exactly once (a double resume traps), with shutDown or
    /// cancelled; new calls are refused; the engine owns nothing afterwards.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-V4: cancellations and new calls racing a multi-turn shutdown settle resume every caller once", .timeLimit(.minutes(3)))
    func shutdownSettleRaces() async throws {
        let count = 3 * SyncEngine.shutdownStepsPerTurn + 7
        let entries = (0..<count).map { EngineHarness.onDemand(String(format: "s%04d", $0), EngineFixture.bytes(UInt64(8_100 + $0), count: 32)) }
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 1))
        try await EngineSingleFlightTests.applied(entries, harness: harness)
        let engine = harness.engine
        let group = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count }
        let callers = entries.map { entry in
            Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) }
        }
        await engine.awaitCondition { $0.state.waiters.count == count }
        let stream = try await engine.subscribe().get()
        let shutdown = Task { await engine.shutdown() }
        await engine.awaitCondition { $0.state.lifecycle == .shuttingDown }
        for (index, caller) in callers.enumerated() where index % 2 == 1 {
            caller.cancel()
        }
        let late = await engine.awaitAsset(entries[0].identifier, lane: .userInitiated)
        let lateGroup = await engine.registerGroup([entries[1].identifier], lane: .prefetch)
        await engine.releaseGroup(group)
        await shutdown.value
        var answers: [String: Int] = [:]
        for caller in callers {
            let answer = await caller.value
            answers[String(describing: answer), default: 0] += 1
        }
        let allowed: Set<String> = [String(describing: Result<AssetLocation, AssetError>.failure(.shutDown)), String(describing: Result<AssetLocation, AssetError>.failure(.cancelled))]
        #expect(Set(answers.keys).isSubset(of: allowed), "PROBE-V4: answers \(answers)")
        #expect(answers.values.reduce(0, +) == count)
        #expect(late == .failure(.shutDown), "a call during the settle: \(late)")
        if case .success = lateGroup {
            Issue.record("PROBE-V4 FAIL: a registration during shutdown succeeded")
        }
        var events: [AssetEvent] = []
        for await event in stream {
            events.append(event)
        }
        #expect(events.last == .clientShutDown, "clientShutDown last: \(events.suffix(3))")
        let census = await engine.introspect()
        #expect(census.ownedTasks == 0 && census.waiters == 0 && census.interests == 0, "\(census)")
    }

    // MARK: S3F-5 (S3-PERF-02) hunt: the proportional follow against the full one

    /// After an apply that changes, drops, re-paths and keeps members of a waiting prefetch group (some downloading),
    /// no job outside verifying or committing holds an id the copy maps to another transfer, every invariant holds, and
    /// the changed members' new content is wanted by the group.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-V5: an apply under a waiting group leaves every job following the copy", .timeLimit(.minutes(1)))
    func followMatchesFullWalk() async throws {
        let count = 40
        let v1 = (0..<count).map { EngineHarness.onDemand(String(format: "f%03d", $0), EngineFixture.bytes(UInt64(7_000 + $0), count: 64)) }
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 2))
        try await EngineSingleFlightTests.applied(v1, harness: harness)
        let engine = harness.engine
        _ = try await engine.registerGroup(v1.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count && !$0.state.inFlight.isEmpty }
        let downloading = await engine.readForTests { Set($0.state.inFlight) }
        var v2: [ManifestEntry] = []
        for (index, entry) in v1.enumerated() {
            switch index {
            case 0..<10:
                v2.append(EngineHarness.onDemand(entry.identifier.rawValue, EngineFixture.bytes(UInt64(17_000 + index), count: 64)))
            case 10..<15:
                continue
            case 15..<20:
                // Same checksum, new remote path and size field: the same transfer.
                v2.append(ManifestEntry(
                    identifier: entry.identifier,
                    fileExtension: entry.fileExtension,
                    remotePath: "moved/\(entry.identifier.rawValue)",
                    localPathComponents: entry.localPathComponents,
                    byteSize: entry.byteSize,
                    checksum: entry.checksum,
                    tags: ["t"],
                    policy: entry.policy
                ))
            default:
                v2.append(entry)
            }
        }
        // Two ids share the content of f030 (a new id for an existing transfer).
        v2.append(EngineHarness.onDemand("f999", EngineFixture.bytes(7_030, count: 64)))
        await harness.serveManifest(v2, etag: "v2")
        let syncTask = Task { await engine.sync(.force) }
        let outcome = await syncTask.value
        #expect(outcome.completeReport != nil, "\(outcome)")
        let check = await engine.readForTests { engine -> (bad: [String], violations: [String], jobs: Int, wanted: Int) in
            var bad: [String] = []
            for (transfer, job) in engine.state.jobs.sorted(by: { $0.key < $1.key }) {
                switch job.state {
                case .verifying, .committing:
                    continue
                default:
                    break
                }
                for asset in job.assets.sorted() where engine.state.applied.entry(for: asset)?.transferID != transfer {
                    bad.append("\(transfer.rawValue.prefix(12)) holds \(asset.rawValue)")
                }
            }
            let wanted = engine.state.jobs.values.reduce(0) { $0 + $1.assets.count }
            return (bad, engine.invariantViolations(), engine.state.jobs.count, wanted)
        }
        #expect(check.bad.isEmpty, "PROBE-V5 FAIL: jobs left not following the copy: \(check.bad)")
        #expect(check.violations.isEmpty, "PROBE-V5: \(check.violations)")
        // 35 ids remain from the group (10 changed, 5 re-pathed, 20 kept); f999 was never in the group.
        #expect(check.wanted == 35, "PROBE-V5: assets wanted \(check.wanted), jobs \(check.jobs), downloading at the apply \(downloading.count)")
        await engine.shutdown()
    }

    // MARK: S3F-15 (S3-B-077) hunt: more retries falling due than one alarm turn takes

    /// 3 x dueDeadlinesPerTurn + 5 group members fail transiently together and fall due at one instant; each is retried
    /// exactly once more and delivered, over several alarm turns, with no clock advance after the one that makes them due.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-V7: retries falling due together beyond one alarm turn are all retried once without another clock advance", .timeLimit(.minutes(3)))
    func dueRetriesBeyondOneTurn() async throws {
        let count = 3 * SyncEngine.dueDeadlinesPerTurn + 5
        let entries = (0..<count).map { EngineHarness.onDemand(String(format: "r%04d", $0), EngineFixture.bytes(UInt64(5_100 + $0), count: 24)) }
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 64))
        try await EngineSingleFlightTests.applied(entries, harness: harness)
        let engine = harness.engine
        for (index, entry) in entries.enumerated() {
            await harness.source.script(entry.transferID, [.fail(.transient(.timedOut, retryAfter: nil)), .stage(EngineFixture.bytes(UInt64(5_100 + index), count: 24))])
        }
        let group = try await engine.registerGroup(entries.map(\.identifier), lane: .prefetch).get()
        await engine.waitUntil { !$0.jobsByState.isEmpty && $0.jobsByState.keys.allSatisfy { $0 == .failed } }
        let waiting = await engine.readForTests { engine in
            engine.state.jobs.values.filter { if case .failed(.at) = $0.state { return true }; return false }.count
        }
        print("PROBE-V7: \(waiting) retries wait for the clock")
        harness.time.advance(by: 3_600)
        await engine.waitUntil { $0.jobsByState.isEmpty }
        let starts = await harness.source.starts.count
        #expect(starts == 2 * count, "PROBE-V7: starts \(starts) for \(count) members")
        #expect(waiting > SyncEngine.dueDeadlinesPerTurn, "PROBE-V7 setup: \(waiting) due together")
        let violations = await engine.readForTests { $0.invariantViolations() }
        #expect(violations.isEmpty, "\(violations)")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }
}

