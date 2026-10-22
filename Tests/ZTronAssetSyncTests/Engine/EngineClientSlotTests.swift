import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Orchestrator ruling L5-R19 (level 5 close-out; L5-C2-00, R-SYN-12): client lifecycle events are never coalesced with
/// each other. `clientStarted` and `clientShutDown` shared the subscriber queue's terminal `.client` slot, so a
/// subscriber that had not read its `clientStarted` when the engine shut down received only `clientShutDown`; the
/// facade hides a retired engine's `clientShutDown` (`docs/adr-drafts/g.md` G-2), so a consumer then got none of that
/// engine's lifecycle events. `clientShutDown` has a terminal slot of its own, one more constant slot per subscriber,
/// and is still the last event.
@Suite("Engine client slot")
struct EngineClientSlotTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-12: a subscriber that reads nothing between clientStarted and clientShutDown receives both, clientStarted first", .timeLimit(.minutes(1)))
    func unreadClientStartedSurvivesShutdown() async throws {
        let harness = EngineHarness.make()
        await harness.serveManifest([])
        let engine = harness.engine
        // Registered before `start()` (nothing to replay yet), and read only after the shutdown.
        let stream = try await engine.subscribe().get()
        let report = try await harness.start()
        await engine.shutdown()
        var events: [AssetEvent] = []
        for await event in stream {
            events.append(event)
        }
        let lifecycle = events.filter { event in
            switch event {
            case .clientStarted, .clientShutDown:
                return true
            default:
                return false
            }
        }
        #expect(lifecycle == [.clientStarted(generation: report.generation), .clientShutDown], "both lifecycle events, in publication order: \(events)")
        #expect(events.last == .clientShutDown, "clientShutDown is still the last event: \(events)")
    }
}
