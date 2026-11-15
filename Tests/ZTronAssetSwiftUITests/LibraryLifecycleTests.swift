import Combine
import Foundation
import Testing
@testable import ZTronAssetKit
@testable import ZTronAssetSwiftUI
import ZTronAssetSync
import ZTronAssetTestSupport

/// `start()`, the self-start of the first asynchronous call, and `shutdown()`, on a library built by the chain over a
/// real client on fakes: what a root view's `.task { await assets.start() }` and the views below it see.
@Suite("Library lifecycle")
struct LibraryLifecycleTests {
    /// Records every phase a library publishes, the current one first.
    @MainActor
    private static func phases(of library: AssetLibrary) -> (history: () -> [AssetLibrary.Phase], stop: () -> Void) {
        final class Recorder {
            var values: [AssetLibrary.Phase] = []
        }
        let recorder = Recorder()
        let observation = library.$phase.sink { recorder.values.append($0) }
        return ({ recorder.values }, { observation.cancel() })
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("start opens the store and publishes ready, the generation and the conditions", .timeLimit(.minutes(1)))
    func startPublishesState() async throws {
        let bytes = LibraryFixture.bytes(1)
        let entry = LibraryFixture.entry("page-1", bytes)
        let harness = LibraryHarness.make()
        await harness.serve([(entry, bytes)])
        let changes = ChangeCounter(harness.library)

        await harness.startAndSettle()

        #expect(harness.library.phase == .ready)
        #expect(changes.count >= 2, "an ObservableObject: SwiftUI saw starting and ready")
        _ = try #require(await published(harness.library.$generation) { $0 != nil }, "no generation was published")
        let conditions = try #require(await published(harness.library.$conditions) { $0 != nil })
        #expect(conditions == .unrestricted)
        #expect(harness.library.lookup("page-1")?.byteSize == Int64(bytes.count), "the launch sync's asset is served")
        await harness.library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("concurrent starts share one start: the phase goes idle, starting, ready once", .timeLimit(.minutes(1)))
    func startIsSingleFlight() async {
        let harness = LibraryHarness.make()
        await harness.serveManifest([])
        let (history, stop) = LibraryLifecycleTests.phases(of: harness.library)
        let library = harness.library

        async let first: Void = library.start()
        async let second: Void = library.start()
        _ = await (first, second)
        await library.start()

        #expect(history() == [.idle, .starting, .ready])
        #expect(harness.fileSystem.operations.filter { $0.kind == .acquireExclusiveLock }.count == 1, "the store was opened once")
        stop()
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a start that fails is published, not thrown, and only start() asks the client again", .timeLimit(.minutes(1)))
    func failedStartIsPublished() async {
        let harness = LibraryHarness.make()
        harness.fileSystem.addFault(FaultRule(operation: .acquireExclusiveLock, occurrence: .every, error: .wouldBlock))
        let (history, stop) = LibraryLifecycleTests.phases(of: harness.library)
        let library = harness.library

        await library.start()
        #expect(library.phase == .failed(.storageUnavailable(.locked)))
        #expect(history() == [.idle, .starting, .failed(.storageUnavailable(.locked))])

        // A view that reacts to the failure by asking for an asset must not flip the phase back and forth.
        await #expect(throws: AssetError.storageUnavailable(.locked)) {
            try await library.availability(scope: .all)
        }
        #expect(history().count == 3, "an asynchronous call after a failure starts nothing: \(history())")
        #expect(library.lookup("page-1") == nil)

        await library.start()
        let failed = AssetLibrary.Phase.failed(.storageUnavailable(.locked))
        #expect(history() == [.idle, .starting, failed, .starting, failed], "start() asked the client again")
        stop()
        await library.shutdown()
        #expect(library.phase == .shutDown)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("the first asynchronous call starts the library, as it starts the client", .timeLimit(.minutes(1)))
    func firstAsyncCallStarts() async throws {
        let bytes = LibraryFixture.bytes(2)
        let entry = LibraryFixture.entry("page-1", bytes)
        let harness = LibraryHarness.make()
        await harness.serve([(entry, bytes)])
        #expect(harness.library.phase == .idle)

        let url = try await harness.library.resolve("page-1")

        #expect(url.pathExtension == "png")
        #expect(await published(harness.library.$phase) { $0 == .ready } == .ready)
        #expect(await published(harness.library.$generation) { $0 != nil } != nil, "the state is being published")
        await harness.library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-SYN-15: after shutdown the phase is shutDown, lookups answer nil and every call fails with shutDown", .timeLimit(.minutes(1)))
    func shutdownIsFinal() async throws {
        let bytes = LibraryFixture.bytes(3)
        let entry = LibraryFixture.entry("page-1", bytes)
        let harness = LibraryHarness.make()
        await harness.serve([(entry, bytes)])
        await harness.startAndSettle()
        let library = harness.library
        #expect(library.lookup("page-1") != nil, "setup: the asset is served before the shutdown")

        await library.shutdown()

        #expect(library.phase == .shutDown)
        #expect(library.lookup("page-1") == nil)
        #expect(library.locate("page-1", kind: .image) == nil)
        await #expect(throws: AssetError.shutDown) {
            try await library.resolve("page-1")
        }
        await #expect(throws: AssetError.shutDown) {
            try await library.url(for: "page-1", kind: .image)
        }
        await #expect(throws: AssetError.shutDown) {
            try await library.prefetch(["page-1"]).awaitRegistration()
        }
        #expect(await library.sync(.force) == .failed(.shutDown))

        await library.start()
        await library.shutdown()
        #expect(library.phase == .shutDown, "neither a start nor a second shutdown leaves the final phase")
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a shutdown while a sync runs leaves no run published as running", .timeLimit(.minutes(1)))
    func shutdownEndsARunningSync() async throws {
        let firstBytes = LibraryFixture.bytes(4)
        let secondBytes = LibraryFixture.bytes(5)
        let first = LibraryFixture.entry("page-1", firstBytes)
        let second = LibraryFixture.entry("page-2", secondBytes)
        let harness = LibraryHarness.make()
        await harness.serve([(first, firstBytes)])
        await harness.startAndSettle()
        let library = harness.library
        await harness.serveManifest([first, second], etag: "v2")
        await harness.source.script(second.transferID, [.hold, .stage(secondBytes)])

        let run = Task { @MainActor in
            await library.sync(.force)
        }
        let running = await published(library.$syncActivity) { activity in
            if case .running = activity {
                return true
            }
            return false
        }
        #expect(running != nil, "setup: the run is published while its transfer is held")

        await library.shutdown()

        #expect(library.phase == .shutDown)
        #expect(library.syncActivity == .finished(.failed(.shutDown)))
        #expect(await run.value == .failed(.shutDown))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a shutdown during a start ends in shutDown, and no later phase follows it", .timeLimit(.minutes(1)))
    func shutdownDuringStart() async {
        let harness = LibraryHarness.make()
        await harness.serveManifest([])
        let (history, stop) = LibraryLifecycleTests.phases(of: harness.library)
        let library = harness.library

        async let starting: Void = library.start()
        async let closing: Void = library.shutdown()
        _ = await (starting, closing)

        #expect(library.phase == .shutDown)
        #expect(history().last == .shutDown)
        #expect(history().filter { $0 == .shutDown }.count == 1, "published once: \(history())")
        let settled = history()
        await library.start()
        #expect(history() == settled, "a start after the shutdown publishes nothing: \(history())")
        stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a shutdown returns only once the start in flight has ended, so no phase follows shutDown", .timeLimit(.minutes(1)))
    func shutdownWaitsForTheStartInFlight() async {
        let bundle = GatedBundleLookup([:])
        let harness = LibraryHarness.make(bulk: DetachedBlockingExecutor()) { $0.bundle(bundle).bundled(.image) }
        await harness.serveManifest([])
        let library = harness.library
        let (history, stop) = LibraryLifecycleTests.phases(of: library)

        // The start is held at its bundle indexing, which the client's shutdown does not wait for.
        let starting = Task { @MainActor in
            await library.start()
        }
        await bundle.waitForAnEnumeration()
        let closing = Task { @MainActor in
            await library.shutdown()
        }
        // The client is shut down under `closing`'s call or under these, whichever it runs first. Once they return
        // `closing` has nothing left to wait for but the start; a shutdown that did not wait for it would publish
        // its final phase about now, and the held start would publish another one after it.
        await library.client.shutdown()
        await library.client.shutdown()
        #expect(library.phase == .starting, "the shutdown published its phase before the start in flight ended")

        bundle.open()
        await starting.value
        await closing.value

        #expect(library.phase == .shutDown)
        #expect(history().firstIndex(of: .shutDown) == history().count - 1, "nothing follows shutDown: \(history())")
        stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a library shut down before it started is final too: a start publishes nothing and opens nothing", .timeLimit(.minutes(1)))
    func shutdownBeforeStartIsFinal() async {
        let harness = LibraryHarness.make()
        let library = harness.library
        let (history, stop) = LibraryLifecycleTests.phases(of: library)

        await library.shutdown()
        #expect(history() == [.idle, .shutDown])

        await library.start()
        #expect(history() == [.idle, .shutDown], "a start after the shutdown publishes nothing: \(history())")
        #expect(harness.fileSystem.operations.filter { $0.kind == .acquireExclusiveLock }.isEmpty, "the store was never opened")
        stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a started library is released with its last owner: its tasks do not keep it alive", .timeLimit(.minutes(1)))
    func startedLibraryIsReleased() async {
        weak var released: AssetLibrary?
        do {
            let harness = LibraryHarness.make()
            await harness.serveManifest([])
            await harness.startAndSettle()
            #expect(harness.library.phase == .ready)
            released = harness.library
        }
        #expect(released == nil)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a store that could not be opened stays failed for its library although the cause is gone; a new library opens it", .timeLimit(.minutes(1)))
    func failedStoreIsFinalForItsLibrary() async {
        let harness = LibraryHarness.make()
        // Only the first attempt to lock the store fails: whoever held it has let go by the second.
        harness.fileSystem.addFault(FaultRule(operation: .acquireExclusiveLock, occurrence: .nth(1), error: .wouldBlock))
        let library = harness.library

        await library.start()
        #expect(library.phase == .failed(.storageUnavailable(.locked)))

        await library.start()
        #expect(library.phase == .failed(.storageUnavailable(.locked)), "the client never opens a store twice")
        await library.shutdown()

        let successor = LibraryHarness.make(sharing: harness)
        await successor.serveManifest([])
        await successor.library.start()
        #expect(successor.library.phase == .ready, "a new library is how an app recovers")
        await successor.library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-STO-9: a second library on the same store fails to start as locked until the first one shut down", .timeLimit(.minutes(1)))
    func oneLibraryPerStore() async {
        let first = LibraryHarness.make()
        await first.serveManifest([])
        await first.startAndSettle()

        let second = LibraryHarness.make(sharing: first)
        await second.library.start()
        #expect(second.library.phase == .failed(.storageUnavailable(.locked)))
        #expect(first.library.phase == .ready, "the first library is not disturbed")
        await second.library.shutdown()

        await first.library.shutdown()
        let third = LibraryHarness.make(sharing: first)
        await third.serveManifest([])
        await third.library.start()
        #expect(third.library.phase == .ready)
        await third.library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a caller that is cancelled does not cancel the start", .timeLimit(.minutes(1)))
    func cancelledCallerDoesNotCancelTheStart() async {
        let harness = LibraryHarness.make()
        await harness.serveManifest([])
        let library = harness.library

        // Cancelled before it runs: the view whose `.task` called `start()` is already gone.
        let caller = Task { @MainActor in
            await library.start()
        }
        caller.cancel()
        await caller.value

        #expect(library.phase == .ready)
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("releasing a library shuts its client down", .timeLimit(.minutes(1)))
    func releasedLibraryShutsItsClientDown() async {
        let engine: SyncEngine
        do {
            let harness = LibraryHarness.make()
            await harness.serveManifest([])
            await harness.startAndSettle()
            engine = await harness.library.client.currentEngine()
            #expect(await engine.introspect().lifecycle == .running)
        }
        await engine.waitUntil { $0.lifecycle == .shutDown }
        #expect(await engine.introspect().lifecycle == .shutDown)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a released library that wrapped a client the app keeps gives its event subscription back at once", .timeLimit(.minutes(1)))
    func releasedWrapperEndsItsSubscription() async {
        let harness = LibraryHarness.make()
        await harness.serveManifest([])
        await harness.startAndSettle()
        let engine = await harness.library.client.currentEngine()
        let before = await engine.introspect().subscribers

        var wrapper: AssetLibrary? = AssetLibrary(client: harness.library.client)
        await wrapper?.start()
        await engine.waitUntil { $0.subscribers == before + 1 }
        #expect(wrapper?.phase == .ready)
        if let wrapper {
            // The replay of its subscription has reached the wrapper: its pump is waiting for the next event.
            #expect(await published(wrapper.$generation) { $0 != nil } != nil)
        }

        // The client is idle, so an event that would wake the pump may never come: only the release ends it.
        wrapper = nil
        await engine.waitUntil { $0.subscribers == before }
        #expect(await engine.introspect().subscribers == before)
        #expect(harness.library.phase == .ready, "the client and the library that owns it carry on")
        await harness.library.shutdown()
    }

    /// Every asynchronous call of the facade, by name, for `asynchronousCallsStartTheLibrary`.
    enum AsyncCall: String, CaseIterable, Sendable {
        case url, resolve, withAsset, prefetch, updatePrefetchWindow, pin, unpin, reportUnreadable, sync, isSyncDue
        case lastSyncedAt, availability, ensureAvailable, setRetentionScope, storageReport, purge, performMaintenance
        case metrics, diagnosticReport, subscribe

        /// Makes the call on `library`; what it answers is other tests' concern.
        @MainActor
        func make(on library: AssetLibrary) async {
            switch self {
            case .url: _ = try? await library.url(for: "page-1", kind: .image)
            case .resolve: _ = try? await library.resolve("page-1")
            case .withAsset: _ = try? await library.withAsset("page-1") { $0 }
            case .prefetch: library.prefetch(["page-1"]).cancel()
            case .updatePrefetchWindow: library.updatePrefetchWindow(ids: ["page-1"], current: 0)
            case .pin: try? await library.pin(["page-1"])
            case .unpin: try? await library.unpin(["page-1"])
            case .reportUnreadable: try? await library.reportUnreadable("page-1")
            case .sync: await library.sync(.ifDue)
            case .isSyncDue: _ = try? await library.isSyncDue()
            case .lastSyncedAt: _ = try? await library.lastSyncedAt()
            case .availability: _ = try? await library.availability(scope: .all)
            case .ensureAvailable: _ = try? await library.ensureAvailable(scope: .all)
            case .setRetentionScope: try? await library.setRetentionScope(.all)
            case .storageReport: _ = try? await library.storageReport()
            case .purge: _ = try? await library.purge(.evictable)
            case .performMaintenance: _ = try? await library.performMaintenance(timeBudget: 1)
            case .metrics: _ = try? await library.metrics()
            case .diagnosticReport: _ = try? await library.diagnosticReport()
            case .subscribe: _ = try? await library.subscribe()
            }
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("every asynchronous call starts an idle library, so its state is published without a start()", .timeLimit(.minutes(1)), arguments: AsyncCall.allCases)
    func asynchronousCallsStartTheLibrary(_ call: AsyncCall) async {
        let bytes = LibraryFixture.bytes(7)
        let entry = LibraryFixture.entry("page-1", bytes)
        let harness = LibraryHarness.make()
        await harness.serve([(entry, bytes)])
        let library = harness.library
        #expect(library.phase == .idle)

        await call.make(on: library)

        #expect(library.phase != .idle, "\(call.rawValue) left the library idle")
        #expect(await published(library.$phase) { $0 == .ready } == .ready)
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("the synchronous lookups start nothing", .timeLimit(.minutes(1)))
    func synchronousCallsStartNothing() async {
        let harness = LibraryHarness.make()
        let library = harness.library

        #expect(library.lookup("page-1") == nil)
        #expect(library.locate("page-1", kind: .image) == nil)
        library.cancelPrefetchWindow()
        _ = library.events

        #expect(library.phase == .idle)
        #expect(harness.fileSystem.operations.isEmpty)
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a library wrapped around an existing client drives that client and starts idle", .timeLimit(.minutes(1)))
    func wrappingAClient() async throws {
        let bytes = LibraryFixture.bytes(6)
        let entry = LibraryFixture.entry("page-1", bytes)
        let harness = LibraryHarness.make()
        await harness.serve([(entry, bytes)])
        await harness.startAndSettle()

        // The app built the client itself; a second facade over it shares the store the first one opened.
        let wrapper = AssetLibrary(client: harness.library.client)
        #expect(wrapper.client === harness.library.client)
        #expect(wrapper.phase == .idle)
        #expect(wrapper.lookup("page-1") == harness.library.lookup("page-1"))
        await wrapper.start()
        #expect(wrapper.phase == .ready)
        await harness.library.shutdown()
        #expect(await published(wrapper.$phase) { $0 == .shutDown } == .shutDown, "the shared client's last event reaches it")

        // A facade made around the client after its shutdown starts into the final phase, not into a failure.
        let late = AssetLibrary(client: harness.library.client)
        await late.start()
        #expect(late.phase == .shutDown)
    }
}
