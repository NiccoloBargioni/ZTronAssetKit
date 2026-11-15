import Foundation
import Testing
@testable import ZTronAssetKit
@testable import ZTronAssetSwiftUI
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// What a view asks about one asset: the synchronous lookups, the fallback chain with its bundle index, the network
/// step, leases, prefetch handles and the carousel's window. Each test asserts the client-level effect the library's
/// call must have, on a real client over fakes.
@Suite("Library asset calls")
struct LibraryAssetTests {
    private static let bundledLogo = URL(fileURLWithPath: "/fake-bundle/logo.png")
    private static let bundledMark = URL(fileURLWithPath: "/fake-bundle/mark.svg")
    private static let imageExtensions: Set<String> = ["heic", "png", "jpg", "jpeg"]

    /// A fake bundle that ships `logo.png` and `mark.svg`.
    @available(macOS 15.0, iOS 18.0, *)
    private static func bundle() -> FakeBundleLookup {
        FakeBundleLookup([
            BundleResourceKey(name: "logo", fileExtension: "png"): LibraryAssetTests.bundledLogo,
            BundleResourceKey(name: "mark", fileExtension: "svg"): LibraryAssetTests.bundledMark,
        ])
    }

    /// Whether every registration and release has landed in the engine: no pending claim, no release in progress.
    private static func settled(_ engine: isolated SyncEngine) -> Bool {
        engine.state.claims.isEmpty && engine.state.releasing.isEmpty
    }

    /// Whether `transfer` is downloading with its handle in place: the fake source recorded its start. The engine
    /// counts a transfer as running from its dispatch, which is earlier.
    private static func inFlight(_ transfer: TransferID, _ engine: isolated SyncEngine) -> Bool {
        engine.state.jobs[transfer]?.state.kind == .downloading && engine.state.jobs[transfer]?.active?.handle != nil
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-1: lookup and locate answer nil before the start and the stored asset after it, with the extension filter applied", .timeLimit(.minutes(1)))
    func lookupsFollowTheSnapshot() async throws {
        let bytes = LibraryFixture.bytes(11)
        let entry = LibraryFixture.entry("page-1", bytes)
        let harness = LibraryHarness.make()
        await harness.serve([(entry, bytes)])
        let library = harness.library
        #expect(library.lookup("page-1") == nil)
        #expect(library.locate("page-1", kind: .image) == nil)

        await harness.startAndSettle()

        let location = try #require(library.lookup("page-1"))
        #expect(location.byteSize == Int64(bytes.count))
        #expect(location.integrity == .verified)
        #expect(library.locate("page-1", kind: .image) == .local(location))
        #expect(library.lookup("page-1", extensions: ["svg"]) == nil)
        #expect(library.locate("page-1", kind: .svg) == nil)
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-2: url(for:kind:) answers a bundled asset without a transfer, indexing the bundle off the main thread", .timeLimit(.minutes(1)))
    func bundleStepComesFirst() async throws {
        let bundle = LibraryAssetTests.bundle()
        let harness = LibraryHarness.make { $0.bundle(bundle) }
        await harness.serveManifest([])
        let library = harness.library

        let url = try await library.url(for: "logo", kind: .image)

        #expect(url == LibraryAssetTests.bundledLogo)
        #expect(bundle.enumerations == [LibraryAssetTests.imageExtensions])
        #expect(!bundle.ranOnMain)
        #expect(await harness.source.starts.isEmpty)
        #expect(library.locate("logo", kind: .image) == .bundle(LibraryAssetTests.bundledLogo), "indexed kinds answer synchronously from then on")

        _ = try await library.url(for: "logo", kind: .image)
        #expect(bundle.enumerations.count == 1, "a kind is indexed once")
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-2: the kinds named in the chain are indexed by start(), in one enumeration", .timeLimit(.minutes(1)))
    func declaredKindsAreIndexedAtStart() async {
        let bundle = LibraryAssetTests.bundle()
        let harness = LibraryHarness.make { $0.bundle(bundle).bundled(.image, .svg) }
        await harness.serveManifest([])
        let library = harness.library
        #expect(library.locate("logo", kind: .image) == nil, "nothing is indexed before the start")
        #expect(bundle.enumerations.isEmpty)

        await library.start()

        #expect(library.locate("logo", kind: .image) == .bundle(LibraryAssetTests.bundledLogo))
        #expect(library.locate("mark", kind: .svg) == .bundle(LibraryAssetTests.bundledMark))
        #expect(bundle.enumerations == [LibraryAssetTests.imageExtensions.union(["svg"])])
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-2: the bundle step needs no store: the declared kinds are indexed although the start failed", .timeLimit(.minutes(1)))
    func bundleSurvivesAFailedStart() async throws {
        let bundle = LibraryAssetTests.bundle()
        let harness = LibraryHarness.make { $0.bundle(bundle).bundled(.image) }
        harness.fileSystem.addFault(FaultRule(operation: .acquireExclusiveLock, occurrence: .every, error: .wouldBlock))
        let library = harness.library

        await library.start()

        #expect(library.phase == .failed(.storageUnavailable(.locked)))
        #expect(library.locate("logo", kind: .image) == .bundle(LibraryAssetTests.bundledLogo))
        #expect(try await library.url(for: "logo", kind: .image) == LibraryAssetTests.bundledLogo)
        await #expect(throws: AssetError.storageUnavailable(.locked)) {
            try await library.url(for: "page-1", kind: .image)
        }
        await library.shutdown()
        #expect(try await library.url(for: "logo", kind: .image) == LibraryAssetTests.bundledLogo, "the bundle outlives the client")
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-2: a later, wider bundle index is built only after the one before it is installed", .timeLimit(.minutes(1)))
    func bundleIndexingIsOrdered() async {
        let bundle = LibraryAssetTests.bundle()
        let bulk = SteppedBlockingExecutor()
        let harness = LibraryHarness.make(bulk: bulk) { $0.bundle(bundle) }
        let library = harness.library

        // The client is never started here: the enumerations are the executor's only units.
        async let images: Void = library.index([.image])
        async let vectors: Void = library.index([.svg])
        // Releases the newest held unit first, whenever one is held, until both calls returned. An indexing that
        // did not wait for the one before it would have both units held at once, and the narrow index, released
        // last, would then replace the wide one.
        let releaser = Task {
            while !Task.isCancelled {
                await bulk.waitForHeldUnits(atLeast: 1)
                if let newest = await bulk.heldUnits.max() {
                    await bulk.release(newest)
                }
            }
        }
        _ = await (images, vectors)
        releaser.cancel()
        await releaser.value

        #expect(bundle.enumerations == [LibraryAssetTests.imageExtensions, LibraryAssetTests.imageExtensions.union(["svg"])])
        #expect(await bulk.submittedUnits == bulk.completedUnits, "one enumeration at a time, in order")
        #expect(library.locate("logo", kind: .image) == .bundle(LibraryAssetTests.bundledLogo))
        #expect(library.locate("mark", kind: .svg) == .bundle(LibraryAssetTests.bundledMark))
        #expect(library.phase == .idle)
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-2: kinds asked for concurrently are all indexed: a later index never drops an earlier kind", .timeLimit(.minutes(1)))
    func bundleIndexOnlyWidens() async throws {
        let bundle = LibraryAssetTests.bundle()
        let harness = LibraryHarness.make { $0.bundle(bundle) }
        await harness.serveManifest([])
        let library = harness.library

        async let logo = library.url(for: "logo", kind: .image)
        async let mark = library.url(for: "mark", kind: .svg)
        let urls = try await (logo, mark)

        #expect(urls.0 == LibraryAssetTests.bundledLogo)
        #expect(urls.1 == LibraryAssetTests.bundledMark)
        #expect(library.locate("logo", kind: .image) == .bundle(LibraryAssetTests.bundledLogo))
        #expect(library.locate("mark", kind: .svg) == .bundle(LibraryAssetTests.bundledMark))
        #expect(bundle.enumerations.last == LibraryAssetTests.imageExtensions.union(["svg"]), "the last index is the widest: \(bundle.enumerations)")
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-2: url(for:kind:) answers a stored asset locally and downloads a missing one at userInitiated", .timeLimit(.minutes(1)))
    func localThenNetwork() async throws {
        let storedBytes = LibraryFixture.bytes(12)
        let missingBytes = LibraryFixture.bytes(13)
        let stored = LibraryFixture.entry("page-1", storedBytes)
        let missing = LibraryFixture.entry("page-2", missingBytes)
        let harness = LibraryHarness.make()
        await harness.serve([(stored, storedBytes)])
        await harness.startAndSettle()
        let library = harness.library
        let startsBefore = await harness.source.starts.count

        let local = try await library.url(for: "page-1", kind: .image)
        #expect(local == library.lookup("page-1")?.url)
        #expect(await harness.source.starts.count == startsBefore, "a stored asset needs no transfer")

        // The origin published a second page since: the client fetches the manifest first, then the asset.
        await harness.serveManifest([stored, missing], etag: "v2")
        await harness.source.script(missing.transferID, [.stage(missingBytes)])
        let fetched = try await library.url(for: "page-2", kind: .image)

        let starts = await harness.source.starts.dropFirst(startsBefore)
        #expect(starts.map(\.id) == [missing.transferID])
        #expect(starts.first?.priority == .userInitiated)
        #expect(try await library.resolve("page-2") == fetched)
        #expect(await harness.source.starts.count == startsBefore + 1, "resolve answers the stored asset without a second transfer")
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-2: an asset whose extension is no candidate of the kind is notFound, and found under its own kind", .timeLimit(.minutes(1)))
    func kindFiltersTheExtension() async throws {
        let bytes = LibraryFixture.bytes(14)
        let clip = LibraryFixture.entry("clip", bytes, ext: "mp4")
        let harness = LibraryHarness.make()
        await harness.serve([(clip, bytes)])
        await harness.startAndSettle()
        let library = harness.library

        await #expect(throws: AssetError.notFound) {
            try await library.url(for: "clip", kind: .image)
        }
        let url = try await library.url(for: "clip", kind: .video(fileExtension: "mp4"))
        #expect(url == library.lookup("clip")?.url)
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-8: withAsset hands the stored file to its body, returns the body's value and rethrows its error", .timeLimit(.minutes(1)))
    func leases() async throws {
        struct BodyFailure: Error, Equatable {}
        let bytes = LibraryFixture.bytes(15)
        let entry = LibraryFixture.entry("intro", bytes, ext: "mp4")
        let harness = LibraryHarness.make()
        await harness.serve([(entry, bytes)])
        await harness.startAndSettle()
        let library = harness.library
        let stored = try #require(library.lookup("intro")?.url)

        let leased = try await library.withAsset("intro") { url in url }
        #expect(leased == stored)
        await #expect(throws: BodyFailure()) {
            try await library.withAsset("intro") { _ in throw BodyFailure() }
        }
        // The lease of the failed body was released: a purge of the asset is not held back by it.
        let purged = try await library.purge(.scope(.identifiers(["intro"])))
        #expect(purged.assetsRemoved == 1)
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-4: a prefetch handle and a resolve of the same asset share one transfer", .timeLimit(.minutes(1)))
    func prefetchAndResolveShareATransfer() async throws {
        let bytes = LibraryFixture.bytes(16)
        let entry = LibraryFixture.entry("page-9", bytes, policy: .onDemand)
        let harness = LibraryHarness.make()
        await harness.serveManifest([entry])
        await harness.startAndSettle()
        let library = harness.library
        await harness.source.script(entry.transferID, [.hold, .stage(bytes)])

        let handle = library.prefetch(["page-9"])
        try await handle.awaitRegistration()
        let engine = await library.client.currentEngine()
        await engine.waitUntil { $0.running == 1 }
        async let resolving = library.resolve("page-9")
        await engine.waitUntil { $0.waiters == 1 }
        await harness.source.release(entry.transferID, with: .progress(received: 0, expected: nil))
        let url = try await resolving

        #expect(url.pathExtension == "png")
        let starts = await harness.source.starts.filter { $0.id == entry.transferID }
        #expect(starts.count == 1, "the resolve joined the prefetch's transfer")
        #expect(starts.first?.priority == .prefetch)
        handle.cancel()
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-3: the prefetch window uses the chain's radius, fetches the current page at userInitiated, cancels what left and ends on cancel", .timeLimit(.minutes(1)))
    func prefetchWindow() async throws {
        // On-demand entries whose transfers park in the fake source (unscripted), so a started transfer stays in
        // flight until the engine cancels it.
        let entries = (0..<5).map { LibraryFixture.entry("p\($0)", LibraryFixture.bytes(20 + UInt64($0)), policy: .onDemand) }
        let ids = entries.map(\.identifier)
        let harness = LibraryHarness.make { $0.prefetchRadius(1).tuning(\.maxConcurrentTransfers, 8) }
        await harness.serveManifest(entries)
        await harness.startAndSettle()
        let library = harness.library
        let source = harness.source
        let engine = await library.client.currentEngine()

        library.updatePrefetchWindow(ids: ids, current: 0)
        let opening = entries[0...1].map(\.transferID)
        await engine.awaitCondition { engine in
            LibraryAssetTests.settled(engine) && opening.allSatisfy { LibraryAssetTests.inFlight($0, engine) }
        }
        let first = await source.starts
        #expect(Set(first.map(\.id)) == Set(opening), "radius 1: the page and one neighbour")
        #expect(first.first { $0.id == entries[0].transferID }?.priority == .userInitiated)
        #expect(first.first { $0.id == entries[1].transferID }?.priority == .prefetch)

        library.updatePrefetchWindow(ids: ids, current: 3)
        let entered = entries[2...4].map(\.transferID)
        await engine.awaitCondition { engine in
            engine.introspect().groups == 3 && LibraryAssetTests.settled(engine)
                && opening.allSatisfy { engine.state.jobs[$0] == nil }
                && entered.allSatisfy { LibraryAssetTests.inFlight($0, engine) }
        }
        let moved = await source.starts.dropFirst(first.count)
        let cancelled = await source.controlLog.filter { $0.control == .cancel }.map(\.transfer)
        #expect(Set(moved.map(\.id)) == Set(entered))
        #expect(moved.first { $0.id == entries[3].transferID }?.priority == .userInitiated, "the new current page")
        #expect(Set(cancelled) == Set(opening), "what left the window was cancelled")

        library.cancelPrefetchWindow()
        await engine.waitUntil { $0.groups == 0 && $0.running == 0 }
        let allCancelled = await source.controlLog.filter { $0.control == .cancel }.map(\.transfer)
        #expect(Set(allCancelled) == Set(entries.map(\.transferID)), "nothing runs for nobody")
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CLN-4: pin and unpin reach the store's pinned bytes", .timeLimit(.minutes(1)))
    func pins() async throws {
        let bytes = LibraryFixture.bytes(17)
        let entry = LibraryFixture.entry("intro", bytes)
        let harness = LibraryHarness.make()
        await harness.serve([(entry, bytes)])
        await harness.startAndSettle()
        let library = harness.library
        #expect(try await library.storageReport().pinnedBytes == 0)

        try await library.pin(["intro"])
        #expect(try await library.storageReport().pinnedBytes == Int64(bytes.count))

        try await library.unpin(["intro"])
        #expect(try await library.storageReport().pinnedBytes == 0)
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CLN-8: an asset reported unreadable leaves the lookups", .timeLimit(.minutes(1)))
    func unreadableAssetIsQuarantined() async throws {
        let bytes = LibraryFixture.bytes(18)
        let entry = LibraryFixture.entry("page-1", bytes)
        let harness = LibraryHarness.make()
        await harness.serve([(entry, bytes)])
        await harness.startAndSettle()
        let library = harness.library
        let events = try await library.subscribe()
        #expect(library.lookup("page-1") != nil)

        try await library.reportUnreadable("page-1")

        for await event in events {
            if case .assetRemoved("page-1", let reason) = event {
                #expect(reason == .quarantined)
                break
            }
        }
        #expect(try await library.availability(scope: .all).present == 0)
        await library.shutdown()
    }
}
