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
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a subscriber stalled across two runs receives the second run's syncStarted before its syncProgress", .timeLimit(.minutes(1)))
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
}
