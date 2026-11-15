import Foundation
import Testing
@testable import ZTronAssetSwiftUI
import ZTronAssetTestSupport

/// How client events fold into the published state (`AssetLibrary.apply(_:)`), event by event on a library that was
/// never started, so every published value below comes from the event the test applied.
@Suite("Library published state")
struct LibraryStateTests {
    private static let progress = SyncProgress(fraction: 0.5, completedCount: 1, totalCount: 2, bytesReceived: 300, bytesExpected: 600)
    private static let expensive = DeviceConditions(
        network: NetworkConditions(satisfied: true, expensive: true, constrained: false),
        power: PowerConditions(lowPowerMode: false, thermal: .nominal)
    )

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a new library is idle and publishes nothing", .timeLimit(.minutes(1)))
    func initialState() async {
        let library = LibraryHarness.make().library
        #expect(library.phase == .idle)
        #expect(library.generation == nil)
        #expect(library.conditions == nil)
        #expect(library.syncActivity == .idle)
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("every catalog change the client announces is published, even when the generation number repeats", .timeLimit(.minutes(1)))
    func snapshotsAlwaysAnnounce() async {
        let library = LibraryHarness.make().library
        let changes = ChangeCounter(library)

        library.apply(.clientStarted(generation: 4))
        #expect(library.generation == 4)
        #expect(changes.count == 1)

        library.apply(.snapshotChanged(generation: 5))
        #expect(library.generation == 5)
        #expect(changes.count == 2)

        // A store reopened after a replaced root may report a generation the library already published; the lookups
        // behind it changed, so views must still be told.
        library.apply(.clientStarted(generation: 5))
        library.apply(.snapshotChanged(generation: 5))
        #expect(library.generation == 5)
        #expect(changes.count == 4)
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("conditions are published once per change, not once per event", .timeLimit(.minutes(1)))
    func conditionsAreDeduplicated() async {
        let library = LibraryHarness.make().library
        let changes = ChangeCounter(library)

        library.apply(.conditionsChanged(.unrestricted))
        library.apply(.conditionsChanged(.unrestricted))
        #expect(library.conditions == .unrestricted)
        #expect(changes.count == 1)

        library.apply(.conditionsChanged(LibraryStateTests.expensive))
        #expect(library.conditions == LibraryStateTests.expensive)
        #expect(changes.count == 2)
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a run is published as running, then with its progress, then with its outcome", .timeLimit(.minutes(1)))
    func runIsFollowed() async {
        let library = LibraryHarness.make().library
        let run = SyncRunID(rawValue: 1)

        library.apply(.syncStarted(run, .launch))
        #expect(library.syncActivity == .running(nil))

        library.apply(.syncProgress(run, LibraryStateTests.progress))
        #expect(library.syncActivity == .running(LibraryStateTests.progress))

        library.apply(.syncFinished(run, .failed(.offline)))
        #expect(library.syncActivity == .finished(.failed(.offline)))
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a progress event of a run whose outcome is published is ignored, also once the next run started; the next run's is not", .timeLimit(.minutes(1)))
    func staleProgressIsIgnored() async {
        let library = LibraryHarness.make().library
        let first = SyncRunID(rawValue: 1)
        let second = SyncRunID(rawValue: 2)
        let third = SyncRunID(rawValue: 3)
        library.apply(.syncFinished(first, .failed(.offline)))
        let changes = ChangeCounter(library)

        library.apply(.syncProgress(first, LibraryStateTests.progress))
        #expect(library.syncActivity == .finished(.failed(.offline)), "the outcome stays")
        #expect(changes.count == 0)

        // The next run's start does not make the finished run's late progress current.
        library.apply(.syncStarted(second, .explicit))
        library.apply(.syncProgress(first, LibraryStateTests.progress))
        #expect(library.syncActivity == .running(nil), "the finished run's progress was published as the started run's")
        library.apply(.syncProgress(second, LibraryStateTests.progress))
        #expect(library.syncActivity == .running(LibraryStateTests.progress))

        // Progress is applied whether or not this library saw the run start.
        library.apply(.syncFinished(second, .failed(.offline)))
        library.apply(.syncProgress(third, LibraryStateTests.progress))
        #expect(library.syncActivity == .running(LibraryStateTests.progress))
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a replacement engine's runs are followed although their identifiers start again", .timeLimit(.minutes(1)))
    func runIdentifiersMayRestart() async {
        let library = LibraryHarness.make().library
        let run = SyncRunID(rawValue: 1)
        library.apply(.syncFinished(run, .failed(.offline)))

        // After a reopen the replacement's first run carries the retired engine's first identifier.
        library.apply(.clientStarted(generation: 1))
        library.apply(.syncProgress(run, LibraryStateTests.progress))
        #expect(library.syncActivity == .running(LibraryStateTests.progress))
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a run whose engine a reopen replaced is published as failed with the replaced root, not left running", .timeLimit(.minutes(1)))
    func reopenEndsTheRetiredRun() async {
        let library = LibraryHarness.make().library
        library.apply(.syncProgress(SyncRunID(rawValue: 7), LibraryStateTests.progress))

        // The retired engine publishes no outcome for its run; the replacement's first event is all that follows.
        library.apply(.clientStarted(generation: 1))
        #expect(library.syncActivity == .finished(.failed(.storageUnavailable(.rootVanished))))

        // A finished run's outcome is left alone.
        library.apply(.syncFinished(SyncRunID(rawValue: 1), .failed(.offline)))
        library.apply(.clientStarted(generation: 2))
        #expect(library.syncActivity == .finished(.failed(.offline)))
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("equal progress is published once", .timeLimit(.minutes(1)))
    func equalProgressIsNotRepublished() async {
        let library = LibraryHarness.make().library
        let run = SyncRunID(rawValue: 3)
        library.apply(.syncProgress(run, LibraryStateTests.progress))
        let changes = ChangeCounter(library)
        library.apply(.syncProgress(run, LibraryStateTests.progress))
        #expect(changes.count == 0)
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("per-asset, breaker and maintenance events change nothing a view observes", .timeLimit(.minutes(1)))
    func unpublishedEvents() async {
        let library = LibraryHarness.make().library
        let changes = ChangeCounter(library)
        let maintenance = MaintenanceReport(gcBytes: 1, evictedBytes: 2, verifiedBytes: 3, corruptFound: 0, budgetExhausted: false)

        library.apply(.transferProgress("a", TransferProgress(received: 10, expected: 300)))
        library.apply(.assetAvailable("a", generation: 9))
        library.apply(.assetFailed("b", .notFound, .untilEntryChanges))
        library.apply(.assetRemoved("c", .evicted))
        library.apply(.circuitChanged(originID: "origin", .closed))
        library.apply(.maintenanceFinished(maintenance))

        #expect(changes.count == 0)
        #expect(library.generation == nil, "an asset's arrival is not a change of the catalog")
        #expect(library.phase == .idle)
        #expect(library.syncActivity == .idle)
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("the client's last event publishes the shut-down phase", .timeLimit(.minutes(1)))
    func shutDownEvent() async {
        let library = LibraryHarness.make().library
        library.apply(.clientShutDown)
        #expect(library.phase == .shutDown)
        await library.shutdown()
    }
}
