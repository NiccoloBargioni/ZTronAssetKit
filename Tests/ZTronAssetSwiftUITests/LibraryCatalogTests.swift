import Foundation
import Testing
@testable import ZTronAssetSwiftUI
import ZTronAssetTestSupport

/// What a settings screen, a paywall or the app delegate asks about the catalog: sync and its published activity, the
/// retention scope, availability, storage, purge, maintenance, diagnostics, the raw events, caches and background
/// events. Each test asserts the client-level effect, on a real client over fakes.
@Suite("Library catalog calls")
struct LibraryCatalogTests {
    private static let expensive = DeviceConditions(
        network: NetworkConditions(satisfied: true, expensive: true, constrained: false),
        power: PowerConditions(lowPowerMode: false, thermal: .nominal)
    )

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a forced sync is published as running while it transfers and as its outcome afterwards; notDue publishes nothing", .timeLimit(.minutes(1)))
    func syncIsPublished() async throws {
        let firstBytes = LibraryFixture.bytes(31)
        let secondBytes = LibraryFixture.bytes(32)
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
        #expect(running != nil, "the run is published while its transfer is held")
        await harness.source.release(second.transferID, with: .progress(received: 0, expected: nil))
        let outcome = await run.value

        guard case .complete(let report) = outcome else {
            Issue.record("the run did not complete: \(outcome)")
            return
        }
        #expect(report.fetched == 1)
        #expect(await published(library.$syncActivity) { $0 == .finished(outcome) } == .finished(outcome))
        #expect(library.lookup("page-2") != nil)

        let again = await library.sync(.ifDue)
        guard case .notDue = again else {
            Issue.record("a complete run wrote the stamp, so nothing is due: \(again)")
            return
        }
        #expect(library.syncActivity == .finished(outcome), "notDue starts no run and replaces no outcome")
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-SYN-9: the chain's refresh policy decides when a sync is due, and the stamp is readable", .timeLimit(.minutes(1)))
    func refreshPolicyAndStamp() async throws {
        let harness = LibraryHarness.make { $0.refresh(.atMostEvery(3_600)) }
        await harness.serveManifest([])
        let library = harness.library
        await harness.startAndSettle()

        #expect(try await library.isSyncDue() == false)
        let stamp = try #require(try await library.lastSyncedAt())
        #expect(stamp <= harness.time.now())
        #expect(stamp == (try await library.client.lastSyncedAt()))

        harness.time.advance(by: 3_601)
        #expect(try await library.isSyncDue())
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-SYN-10: availability counts what is missing and ensureAvailable fetches it", .timeLimit(.minutes(1)))
    func availabilityAndEnsureAvailable() async throws {
        let storedBytes = LibraryFixture.bytes(33)
        let extraBytes = LibraryFixture.bytes(34)
        let stored = LibraryFixture.entry("page-1", storedBytes)
        let extra = LibraryFixture.entry("bonus", extraBytes, tags: ["season-1"], policy: .onDemand)
        let harness = LibraryHarness.make()
        await harness.serveManifest([stored, extra])
        await harness.source.script(stored.transferID, [.stage(storedBytes)])
        await harness.startAndSettle()
        let library = harness.library

        let before = try await library.availability(scope: .identifiers(["page-1", "bonus"]))
        #expect(before.total == 2)
        #expect(before.present == 1)
        #expect(before.missing == 1)
        #expect(before.bytesMissing == Int64(extraBytes.count))
        #expect(before == (try await library.client.availability(scope: .identifiers(["page-1", "bonus"]))))

        await harness.source.script(extra.transferID, [.stage(extraBytes)])
        let after = try await library.ensureAvailable(scope: .identifiers(["bonus"]))
        #expect(after.isComplete)
        #expect(try await library.availability(scope: .identifiers(["page-1", "bonus"])).missing == 0)
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CAR-5: the chain's retention scope bounds the launch sync, and setRetentionScope widens it without fetching", .timeLimit(.minutes(1)))
    func retentionScope() async throws {
        let freeBytes = LibraryFixture.bytes(35)
        let paidBytes = LibraryFixture.bytes(36)
        let extraBytes = LibraryFixture.bytes(34)
        let free = LibraryFixture.entry("free-1", freeBytes, tags: ["free"])
        let paid = LibraryFixture.entry("paid-1", paidBytes, tags: ["paid"])
        // Outside both scopes of this test, and scripted: a sync of everything would fetch it.
        let extra = LibraryFixture.entry("extra-1", extraBytes, tags: ["extra"])
        let harness = LibraryHarness.make { $0.retain(.tags(["free"])) }
        await harness.serveManifest([free, paid, extra])
        await harness.source.script(free.transferID, [.stage(freeBytes)])
        await harness.source.script(extra.transferID, [.stage(extraBytes)])
        await harness.startAndSettle()
        let library = harness.library
        #expect(await harness.source.starts.map(\.id) == [free.transferID], "the launch sync fetched only what the chain retains")
        #expect(library.lookup("paid-1") == nil)

        try await library.setRetentionScope(.tags(["free", "paid"]))
        #expect(await harness.source.starts.count == 1, "a scope change fetches nothing by itself")

        await harness.source.script(paid.transferID, [.stage(paidBytes)])
        let outcome = await library.sync(.force)
        guard case .complete(let report) = outcome else {
            Issue.record("the run did not complete: \(outcome)")
            return
        }
        #expect(report.fetched == 1, "the next sync covers the wider scope")
        #expect(await harness.source.starts.map(\.id) == [free.transferID, paid.transferID])
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CLN-6: purge removes a scope's assets, frees or defers their bytes and makes a sync due", .timeLimit(.minutes(1)))
    func purge() async throws {
        let keptBytes = LibraryFixture.bytes(37)
        let droppedBytes = LibraryFixture.bytes(38)
        let kept = LibraryFixture.entry("page-1", keptBytes, tags: ["season-1"])
        let dropped = LibraryFixture.entry("old-1", droppedBytes, tags: ["season-0"])
        let harness = LibraryHarness.make()
        await harness.serve([(kept, keptBytes), (dropped, droppedBytes)])
        await harness.startAndSettle()
        let library = harness.library
        #expect(try await library.isSyncDue() == false)

        let result = try await library.purge(.scope(.tags(["season-0"])))

        #expect(result.assetsRemoved == 1)
        #expect(result.bytesFreed + result.bytesDeferred == Int64(droppedBytes.count))
        let availability = try await library.availability(scope: .all)
        #expect(availability.present == 1)
        #expect(availability.missing == 1)
        #expect(try await library.isSyncDue(), "a purge makes a sync due")
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-OBS-2: metrics count the library's lookups and downloads, and maintenance reports within its budget", .timeLimit(.minutes(1)))
    func metricsAndMaintenance() async throws {
        let bytes = LibraryFixture.bytes(39)
        let entry = LibraryFixture.entry("page-1", bytes)
        let harness = LibraryHarness.make()
        await harness.serve([(entry, bytes)])
        await harness.startAndSettle()
        let library = harness.library

        let before = try await library.metrics()
        #expect(before.bytesDownloaded == Int64(bytes.count))
        #expect(library.lookup("page-1") != nil)
        #expect(library.lookup("ghost") == nil)
        let after = try await library.metrics()
        #expect(after.lookupHits == before.lookupHits + 1)
        #expect(after.lookupMisses == before.lookupMisses + 1)

        let report = try await library.performMaintenance(timeBudget: 5)
        #expect(report.corruptFound == 0)
        #expect(report.budgetExhausted == false)
        #expect(try await library.storageReport().bytesByState.present == Int64(bytes.count))
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-SEC-1: the diagnostic report describes the chain's configuration and never carries the app key", .timeLimit(.minutes(1)))
    func diagnosticReport() async throws {
        let canary = "CANARY-51c0de-APP-KEY"
        let harness = LibraryHarness.make { $0.appKey(canary).prefetchRadius(3) }
        await harness.serveManifest([])
        await harness.startAndSettle()
        let library = harness.library

        let data = try await library.diagnosticReport()

        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(canary))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReport.self, from: data)
        #expect(report.appVersion == "1.0+1")
        #expect(report.configuration["remote.http.appKey"] == "<redacted>", "the key's place is in the report")
        #expect(report.configuration["prefetchRadius"] == "3")
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-SYN-12: subscribe carries the per-asset events the published state leaves out, and a stream made after shutdown only ends", .timeLimit(.minutes(1)))
    func rawEvents() async throws {
        let bytes = LibraryFixture.bytes(40)
        let entry = LibraryFixture.entry("bonus", bytes, policy: .onDemand)
        let harness = LibraryHarness.make()
        await harness.serveManifest([entry])
        await harness.startAndSettle()
        let library = harness.library
        await harness.source.script(entry.transferID, [.stage(bytes)])
        let events = try await library.subscribe()

        let handle = library.prefetch(["bonus"])
        var available = false
        for await event in events {
            if case .assetAvailable("bonus", _) = event {
                available = true
                break
            }
        }
        #expect(available)
        // What a view does on that event: it asks for the file, which is answered from the store.
        let url = try await library.resolve("bonus")
        #expect(url.pathExtension == "png")
        #expect(await harness.source.starts.count == 1, "the prefetch's transfer is the only one")
        handle.cancel()

        await library.shutdown()
        var last: [AssetEvent] = []
        for await event in library.events {
            last.append(event)
        }
        #expect(last == [.clientShutDown])
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("a change of the device's conditions is published while the client has work, which is when it observes them", .timeLimit(.minutes(1)))
    func conditionsArePublished() async throws {
        // An on-demand entry whose transfer parks in the fake source (unscripted): work in flight for as long as its
        // handle lives, so the client keeps observing the device (R-SYN-14: an idle client observes nothing).
        let entry = LibraryFixture.entry("bonus", LibraryFixture.bytes(41), policy: .onDemand)
        let harness = LibraryHarness.make()
        await harness.serveManifest([entry])
        await harness.startAndSettle()
        let library = harness.library
        #expect(await published(library.$conditions) { $0 == .unrestricted } == .unrestricted)
        let handle = library.prefetch(["bonus"])
        try await handle.awaitRegistration()
        await harness.conditions.waitForObservers(equalTo: 1)

        await harness.conditions.send(LibraryCatalogTests.expensive)

        #expect(await published(library.$conditions) { $0 == LibraryCatalogTests.expensive } == LibraryCatalogTests.expensive)
        handle.cancel()
        await library.shutdown()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-CLN-11: a registered cache is purged by the chain's memory-pressure source until it is unregistered", .timeLimit(.minutes(1)))
    func registeredCacheIsPurged() async throws {
        let harness = LibraryHarness.make()
        await harness.serveManifest([])
        await harness.startAndSettle()
        let library = harness.library
        let (purges, signal) = AsyncStream<MemoryPressureLevel>.makeStream()
        let cache = SignallingCache(signal: signal)

        try library.register(cache)
        await harness.pressure.waitForObservers(equalTo: 1)
        await harness.pressure.send(.critical)
        for await level in purges {
            #expect(level == .critical)
            break
        }
        #expect(cache.levels == [.critical])

        library.unregister(cache)
        await harness.pressure.waitForObservers(equalTo: 0)
        #expect(await harness.pressure.activeObservers == 0, "nothing observes memory pressure for no cache")

        await library.shutdown()
        #expect(throws: AssetError.shutDown) {
            try library.register(cache)
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @MainActor
    @Test("R-NET-3: background events of the kit's session reach the source, complete the handler and start the library; a foreign session is refused and starts nothing", .timeLimit(.minutes(1)))
    func backgroundEvents() async {
        let identifier = "com.ztron.assetkit.bg.carousel.v1"
        let harness = LibraryHarness.make()
        await harness.serveManifest([])
        let library = harness.library
        let (completions, signal) = AsyncStream<Void>.makeStream()

        #expect(library.handleBackgroundEvents(identifier: "com.example.other") {} == false)
        #expect(library.phase == .idle, "a session that is not the kit's starts nothing")

        let accepted = library.handleBackgroundEvents(identifier: identifier) {
            signal.yield()
        }
        #expect(accepted)
        #expect(library.phase == .starting, "the client starts for its session, and the library with it")
        for await _ in completions {
            break
        }
        #expect(await harness.source.backgroundEventIdentifiers == [identifier])
        #expect(await published(library.$phase) { $0 == .ready } == .ready)
        await library.shutdown()
    }
}
