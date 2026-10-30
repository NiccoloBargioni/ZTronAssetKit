import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

extension EngineEventsTests {
    /// A run's end supersedes its undelivered progress (ADR-023, as a transfer's end does): a lagging subscriber receives
    /// run 1's `syncFinished` before run 2's `syncStarted`, and run 2's `syncStarted` before its `syncProgress`, which
    /// takes a fresh slot instead of run 1's old position (R-SYN-12, H-9; Stage 3, S3-CONC-03).
    @Test("R-SYN-12: a lagging subscriber receives a run's syncStarted before that run's syncProgress")
    func queueDeliversStartBeforeProgress() {
        var queue = SubscriberQueue()
        let run1 = SyncRunID(rawValue: 1)
        let run2 = SyncRunID(rawValue: 2)
        let half = SyncProgress(fraction: 0.5, completedCount: 1, totalCount: 2, bytesReceived: 1, bytesExpected: 2)
        _ = queue.publish(.syncStarted(run1, .explicit), sequence: 1)
        _ = queue.publish(.syncProgress(run1, half), sequence: 2)
        _ = queue.publish(.syncFinished(run1, .failed(.cancelled)), sequence: 3)
        _ = queue.publish(.syncStarted(run2, .explicit), sequence: 4)
        _ = queue.publish(.syncProgress(run2, half), sequence: 5)
        var delivered: [AssetEvent] = []
        while let event = queue.take() {
            delivered.append(event)
        }
        let finished = delivered.firstIndex(of: .syncFinished(run1, .failed(.cancelled)))
        let started = delivered.firstIndex(of: .syncStarted(run2, .explicit))
        let progress = delivered.firstIndex(of: .syncProgress(run2, half))
        #expect(finished != nil && started != nil && progress != nil, "\(delivered)")
        if let finished, let started, let progress {
            #expect(finished < started && started < progress, "run 1's end, run 2's start, then run 2's progress: \(delivered)")
        }
    }

    /// The same through the engine: a subscriber that reads nothing while two runs with fetches complete, then reads its
    /// backlog (R-SYN-12; Stage 3, S3-CONC-03).
    ///
    /// Hang guard (S3-R4): under TSan in the whole Sync bundle it took 31.2 to 32.5 s beside a second TSan process at a
    /// load of 20 to 35 (54 % of 60 s) and 14.0 s alone at a load of 13 to 18 (Stage 3 close-out cycle 7), over half
    /// its 60 s, so the guard is `.minutes(3)`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a subscriber stalled across two runs receives the second run's syncStarted before its syncProgress", .timeLimit(.minutes(3)))
    func engineDeliversStartBeforeProgress() async throws {
        let harness = EngineHarness.make()
        let first = EngineSyncTests.catalog(2, prefix: "a", seed: 1)
        await harness.serve(first)
        let engine = harness.engine
        let stalled = try await engine.subscribe().get()
        let launch = try await harness.startAndAwaitLaunchRun()
        #expect(launch.completeReport?.fetched == 2, "run 1: \(launch)")
        let second = EngineSyncTests.catalog(2, prefix: "b", seed: 50)
        await harness.serve(first + second, etag: "v2")
        let outcome = await engine.sync(.force)
        let run2 = try #require(outcome.completeReport, "run 2: \(outcome)")
        #expect(run2.fetched == 2)
        await engine.shutdown()
        var events: [AssetEvent] = []
        for await event in stalled {
            events.append(event)
        }
        let started = events.firstIndex { event in
            if case .syncStarted(let id, _) = event {
                return id == run2.runID
            }
            return false
        }
        let progress = events.firstIndex { event in
            if case .syncProgress(let id, _) = event {
                return id == run2.runID
            }
            return false
        }
        #expect(started != nil && progress != nil, "both delivered: \(events)")
        if let started, let progress {
            #expect(started < progress, "run \(run2.runID.rawValue)'s syncProgress at \(progress) precedes its syncStarted at \(started): \(events.map { String(describing: EventSlot($0)) })")
        }
    }

    /// A subscriber that registers while a run is in progress is first given the run's `syncStarted` and then the run's
    /// latest `syncProgress`, the one the rate limit last saw (sync.md §10.5, R-SYN-12's replay), so a progress bar
    /// opened mid-run starts from the run's state instead of waiting for its next event.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a subscriber that joins a run in progress receives the run's syncStarted and then its latest syncProgress", .timeLimit(.minutes(1)))
    func lateSubscriberGetsRunReplay() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(progressInterval: 0))
        let catalog = EngineSyncTests.catalog(2, prefix: "replay")
        let first = catalog[0].0
        let second = catalog[1].0
        await harness.serveManifest(catalog.map(\.0))
        await harness.source.script(first.transferID, [.stage(catalog[0].1)])
        await harness.source.script(second.transferID, [.hold, .stage(catalog[1].1)])
        try await harness.start()
        let engine = harness.engine
        let run = Task { await engine.sync(.force) }
        // The first asset commits and the run reports progress while the second waits in flight.
        await engine.awaitCondition { engine in
            engine.state.jobs[first.transferID] == nil && engine.state.jobs[second.transferID]?.state == .downloading
                && engine.state.progress.latestRun != nil
        }
        let expected = await engine.readForTests { ($0.state.run?.id, $0.state.progress.latestRun) }
        let runID = try #require(expected.0, "a run is in progress")
        let progress = try #require(expected.1, "the run reported progress")
        let stream = try await engine.subscribe().get()
        var replayed: [AssetEvent] = []
        for await event in stream {
            replayed.append(event)
            if case .syncProgress = event {
                break
            }
        }
        let started = replayed.firstIndex { if case .syncStarted(runID, _) = $0 { return true } else { return false } }
        let replayedProgress = replayed.firstIndex { if case .syncProgress(runID, _) = $0 { return true } else { return false } }
        #expect(started != nil && replayedProgress != nil, "\(replayed)")
        if let started, let replayedProgress {
            #expect(started < replayedProgress, "syncStarted comes first: \(replayed)")
            #expect(replayed[replayedProgress] == progress, "the run's latest progress is replayed: \(replayed[replayedProgress])")
        }
        await harness.source.release(second.transferID, with: .progress(received: 0, expected: nil))
        #expect(await EngineHarness.value(of: run).completeReport?.fetched == 2)
        await engine.shutdown()
    }
}

