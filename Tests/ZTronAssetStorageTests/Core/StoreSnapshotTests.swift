import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

@Suite("Core: snapshots, reads and accesses")
struct StoreSnapshotTests {
    @Test(
        "R-STO-13: bulk publishes install at most one snapshot per snapshotInstallInterval and a user-initiated publish installs at once",
        .timeLimit(.minutes(1))
    )
    @available(macOS 15.0, iOS 18.0, *)
    func installRate() async throws {
        let harness = CoreHarness.make(configuration: CoreFixture.configuration(installInterval: 0.1))
        let payloads = (0..<52).map { CoreFixture.bytes(400 + UInt64($0), count: 24) }
        let entries = payloads.enumerated().map { CoreFixture.entry("i\($0.offset)", $0.element) }
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest(entries), etag: nil, eviction: nil)
        let afterApply = await harness.sink.offeredKeys.count
        let start = harness.time.monotonicNow()

        // Two bulk publications inside the window: no install yet, the trailing install is a deadline.
        let first = try await harness.publish(payloads[0], [entries[0]], urgency: .bulk, sequence: 1)
        harness.time.advance(by: 0.02)
        try await harness.publish(payloads[1], [entries[1]], urgency: .prefetch, sequence: 2)
        #expect(await harness.sink.offeredKeys.count == afterApply)
        let commitOnly = await harness.store.runDueWork()
        #expect(commitOnly.committed && !commitOnly.installedSnapshot)
        #expect(await harness.store.nextDeadline() == start.adding(seconds: 0.1))
        #expect(first[entries[0].identifier] == (await harness.store.location(for: entries[0].identifier, extensions: [], recordingAccess: false)))
        #expect(await harness.sink.installed.location(for: entries[0].identifier, extensions: []) == nil)
        harness.time.advance(by: 0.03)
        #expect(await harness.store.runDueWork().installedSnapshot == false)
        harness.time.advance(to: start.adding(seconds: 0.1))
        let trailing = await harness.store.runDueWork()
        #expect(trailing.installedSnapshot)
        #expect(await harness.sink.offeredKeys.count == afterApply + 1)
        let installed = await harness.sink.installed
        #expect(installed.location(for: entries[0].identifier, extensions: []) != nil && installed.location(for: entries[1].identifier, extensions: []) != nil)

        // A user-initiated publication installs before returning, whatever the window.
        harness.time.advance(by: 0.01)
        try await harness.publish(payloads[2], [entries[2]], urgency: .userInitiated, sequence: 3)
        #expect(await harness.sink.offeredKeys.count == afterApply + 2)
        #expect(await harness.sink.installed.location(for: entries[2].identifier, extensions: []) != nil)

        // A second of bulk publications every 20 ms, with the alarm served at every deadline: at most ten installs.
        let before = await harness.sink.offeredKeys.count
        let second = harness.time.monotonicNow()
        for index in 3..<52 {
            harness.time.advance(by: 0.02)
            try await harness.publish(payloads[index], [entries[index]], urgency: .bulk, sequence: UInt32(index + 1))
            if let deadline = await harness.store.nextDeadline(), deadline <= harness.time.monotonicNow() {
                _ = await harness.store.runDueWork()
            }
        }
        let elapsed = harness.time.monotonicNow().seconds(since: second)
        let installs = await harness.sink.offeredKeys.count - before
        #expect(elapsed <= 1.0 && installs <= 10 && installs >= 8, "\(installs) installs in \(elapsed) s")
        let keys = await harness.sink.offeredKeys
        #expect(zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 }, "versions are allocated in build order")
    }

    @Test("R-STO-13: the store resolves from current state, matches extensions case-insensitively and records accesses lazily", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func locationsFromCurrentState() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(90)
        let entry = CoreFixture.entry("a", bytes, ext: "PnG")
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [entry])
        let location = try #require(await harness.store.location(for: entry.identifier, extensions: ["jpg", "png"], recordingAccess: false))
        #expect(location.fileExtension.rawValue == "png" && location.byteSize == 300 && location.integrity == .verified && !location.isStale)
        #expect(await harness.store.location(for: entry.identifier, extensions: ["jpg"], recordingAccess: false) == nil)
        #expect(await harness.store.location(for: "missing", extensions: [], recordingAccess: false) == nil)
        let before = try #require(try await harness.store.planningView().records[entry.identifier]).lastAccess
        harness.time.advance(by: 30)
        let serial = await harness.state.core.commits.soonSerial
        _ = await harness.store.location(for: entry.identifier, extensions: ["PNG"], recordingAccess: true)
        let after = try #require(try await harness.store.planningView().records[entry.identifier]).lastAccess
        #expect(after == before.addingTimeInterval(30))
        #expect(await harness.state.core.commits.soonSerial == serial, "an access is a lazy mutation")
    }

    @Test("R-STO-13: accesses reach the records through acknowledgements, clamped to now and never moved backwards", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func accessesThroughAcknowledgements() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(91)
        let entry = CoreFixture.entry("a", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [entry])
        harness.time.advance(by: 10)
        let now = harness.time.now()
        await harness.sink.recordAccess(entry.identifier, at: now.addingTimeInterval(500))
        try await harness.store.flushAndInstall()
        #expect(try await harness.store.planningView().records[entry.identifier]?.lastAccess == now, "a future stamp is clamped to now")
        await harness.store.recordAccesses([entry.identifier: now.addingTimeInterval(-100), "unknown": now])
        #expect(try await harness.store.planningView().records[entry.identifier]?.lastAccess == now)
        #expect(await harness.store.metrics().acknowledgedInstalls >= 3)
    }

    @Test("R-STO-7: the store's availability counts present, missing, stale, failed and unverified entries of a scope without I/O", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func availabilityCounts() async throws {
        let harness = CoreHarness.make()
        let a = CoreFixture.bytes(92)
        let b = CoreFixture.bytes(93)
        let c = CoreFixture.bytes(94)
        let entries = [
            CoreFixture.entry("ri.a", a, tags: ["ri"]),
            CoreFixture.entry("ri.b", b, checksum: false, tags: ["ri"]),
            CoreFixture.entry("ri.c", c, tags: ["ri"]),
            CoreFixture.entry("ot.d", CoreFixture.bytes(95)),
        ]
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest(entries), etag: nil, eviction: nil)
        try await harness.publish(a, [entries[0]], sequence: 1)
        try await harness.publish(b, [entries[1]], sequence: 2)
        try await harness.publish(c, [entries[2]], sequence: 3)
        var changed = entries
        changed[2] = CoreFixture.entry("ri.c", CoreFixture.bytes(96), tags: ["ri"])
        _ = try await harness.store.apply(CoreFixture.manifest(changed), etag: nil, eviction: nil)
        await harness.store.setResidency(.failed(.notFound), of: "ot.d", dooming: .unreferenced)
        let start = harness.fileSystem.operations.count
        let all = await harness.store.availability(of: .all)
        #expect(all.total == 4 && all.present == 2 && all.stale == 1 && all.failed == 1 && all.missing == 0 && all.unverified == 1)
        let scoped = await harness.store.availability(of: .tags(["ri"]))
        #expect(scoped.total == 3 && scoped.present == 2 && scoped.stale == 1 && scoped.failed == 0)
        let prefix = await harness.store.availability(of: .prefix("ot."))
        #expect(prefix.total == 1 && prefix.failed == 1 && !prefix.manifestFresh)
        await harness.store.setResidency(.absent(.evicted), of: "ri.a", dooming: .unreferenced)
        let evicted = await harness.store.availability(of: .identifiers(["ri.a"]))
        #expect(evicted.missing == 1 && evicted.bytesMissing == 300)
        #expect(harness.fileSystem.operations.count == start, "availability performs no I/O")
    }

    @Test("R-OBS-1: every index commit and every hash runs inside exactly one commit or verify interval", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func signpostIntervals() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(97)
        let entry = CoreFixture.entry("a", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [entry])
        try await harness.store.flush(.durable)
        let events = harness.tap.lines.compactMap(LogIntervalEvent.init(line:))
        let commits = events.filter { $0.name == .commit }
        let verifies = events.filter { $0.name == .verify }
        let metrics = await harness.store.metrics()
        #expect(commits.filter { $0.phase == .began }.count == metrics.commits + metrics.commitFailures)
        #expect(commits.filter { $0.phase == .ended }.count == commits.filter { $0.phase == .began }.count)
        #expect(verifies.filter { $0.phase == .began }.count == 1 && verifies.filter { $0.phase == .ended }.count == 1)
        #expect(events.allSatisfy { $0.category == .store })
    }

    @Test("R-CLN-1: freeSpace reads both capacities once and reports usage, the pending reclaim of doomed blobs and the resolved budget", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func freeSpaceFigures() async throws {
        let harness = CoreHarness.make(importantCapacity: 10_000)
        let a = CoreFixture.bytes(98)
        let b = CoreFixture.bytes(99)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([CoreFixture.entry("a", a), CoreFixture.entry("b", b)]), etag: nil, eviction: nil)
        try await harness.publish(a, [CoreFixture.entry("a", a)], sequence: 1)
        try await harness.publish(b, [CoreFixture.entry("b", b)], sequence: 2)
        _ = try await harness.store.apply(CoreFixture.manifest([CoreFixture.entry("b", b)]), etag: nil, eviction: nil)
        let space = try await harness.store.freeSpace()
        #expect(space.usedBytes == 300 && space.pendingReclaim == 300)
        #expect(space.volumeImportant == (try harness.fileSystem.availableCapacity(at: harness.layout.root, for: .important)))
        #expect(space.budgetBytes == StoragePolicy().budget.resolve(usedBytes: 300, availableBytes: space.volumeImportant))
        #expect(space.reserveBytes == StoragePolicy().reserveFreeBytes)
        harness.fileSystem.addFault(FaultRule(operation: .availableCapacity, occurrence: .every, error: .io))
        await #expect(throws: StoreError.fileSystem(.io)) {
            try await harness.store.freeSpace()
        }
    }
}
