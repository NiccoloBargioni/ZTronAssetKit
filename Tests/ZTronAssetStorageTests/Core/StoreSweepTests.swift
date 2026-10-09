import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// `apply` in chunks behind its gate, and the verified copy of a blob under a second extension (C2; ADR draft B-11,
/// B-18, B-19).
@Suite("Core: chunked apply and extension copies")
struct StoreSweepTests {
    @Test("R-SYN-8: an apply larger than one sweep chunk adds, re-adopts and prunes every entry", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func applyLargerThanAChunk() async throws {
        let harness = CoreHarness.make()
        let count = AssetStore.sweepChunk * 2 + 100
        let published = AssetStore.sweepChunk + 88
        let payloads = (0..<count).map { CoreFixture.bytes(10_000 + UInt64($0), count: 16) }
        let entries = payloads.enumerated().map { CoreFixture.entry("s\($0.offset)", $0.element) }
        let manifest = CoreFixture.manifest(entries)
        _ = try await harness.store.open()
        let first = try await harness.store.apply(manifest, etag: nil, eviction: nil)
        #expect(first.added.count == count && first.reused.isEmpty)
        for index in 0..<published {
            try await harness.publish(payloads[index], [entries[index]], sequence: UInt32(index + 1))
        }
        let pruned = try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        #expect(pruned.pruned.count == count)
        let emptied = await harness.sink.installed.entries.isEmpty
        #expect(await harness.state.core.records.isEmpty && emptied)
        // The doomed blobs are rescued by the next apply, in more than one chunk.
        let again = try await harness.store.apply(manifest, etag: nil, eviction: nil)
        #expect(again.added.count == count && again.reused.count == published)
        let view = try await harness.store.planningView()
        #expect(view.records.values.filter { $0.referencedBlob != nil }.count == published)
        #expect(await harness.sink.installed.entries.count == published)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-SYN-8: concurrent applies run one at a time, and close unwinds an apply waiting for its turn", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func appliesAreSerialised() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(bulk: bulk)
        let a = CoreFixture.entry("a", CoreFixture.bytes(250))
        let b = CoreFixture.entry("b", CoreFixture.bytes(251))
        _ = try await harness.store.open()
        await bulk.setHolding(true)
        let applyA = Task {
            try await harness.store.apply(CoreFixture.manifest([a]), etag: nil, eviction: nil)
        }
        try await bulk.requireHeldUnits(atLeast: 1)  // A's plan unit
        let submitted = await bulk.submittedUnits.count
        let applyB = Task {
            try await harness.store.apply(CoreFixture.manifest([b]), etag: nil, eviction: nil)
        }
        try await StoreSweepTests.waitForGateWaiter(harness)
        #expect(await bulk.submittedUnits.count == submitted, "B plans nothing while A holds the gate")
        await bulk.setHolding(false)
        let reportA = try await applyA.value
        let reportB = try await applyB.value
        #expect(reportA.added == [a.identifier])
        #expect(reportB.added == [b.identifier] && reportB.pruned == [a.identifier], "B planned against A's manifest")
        #expect(await harness.state.core.appliedManifest.entries.map(\.identifier) == [b.identifier])
        #expect(await !harness.state.core.applyGate.held)

        await bulk.setHolding(true)
        let applyC = Task {
            try await harness.store.apply(CoreFixture.manifest([a]), etag: nil, eviction: nil)
        }
        try await bulk.requireHeldUnits(atLeast: 1)
        let applyD = Task {
            try await harness.store.apply(CoreFixture.manifest([b]), etag: nil, eviction: nil)
        }
        try await StoreSweepTests.waitForGateWaiter(harness)
        let closing = Task {
            await harness.store.close()
        }
        // C's plan unit is released only once close() is draining: released earlier, C could plan, write and commit
        // while the store is still open and return normally (close-out cycle 3: failed once under load).
        try await StoreSweepTests.waitForPhase(.closing, harness)
        await bulk.setHolding(false)
        await closing.value
        await #expect(throws: StoreError.closed) {
            try await applyC.value
        }
        await #expect(throws: StoreError.closed) {
            try await applyD.value
        }
    }

    @Test("R-INT-1: a copy under a second extension is verified, and a failed or mismatched copy binds nothing and leaves nothing behind", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func copyFailures() async throws {
        let bytes = CoreFixture.bytes(260)
        let png = CoreFixture.entry("a", bytes, ext: "png")
        let jpg = CoreFixture.entry("b", bytes, ext: "jpg")
        let pngKey = CoreFixture.key(bytes, ext: "png")
        let jpgKey = CoreFixture.key(bytes, ext: "jpg")

        // A read of the source blob fails.
        let failing = CoreHarness.make()
        _ = try await failing.store.open()
        _ = try await failing.store.apply(CoreFixture.manifest([png, jpg]), etag: nil, eviction: nil)
        failing.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(pathContains: "/blobs/"), occurrence: .nth(1), error: .io))
        let bound = try await failing.publish(bytes, [png, jpg])
        #expect(Set(bound.keys) == [png.identifier], "the png is bound; the jpg copy failed")
        #expect(await failing.state.core.blobTable[jpgKey] == nil)
        #expect(await failing.state.core.publishing.isEmpty)
        #expect(try StoreSweepTests.copies(in: failing).isEmpty)
        #expect(await CoreInvariants.violations(of: failing).isEmpty)

        // The source changes while it is copied: the copy does not hash to its name and is discarded.
        let bulk = SteppedBlockingExecutor(holding: false)
        let changing = CoreHarness.make(bulk: bulk)
        _ = try await changing.store.open()
        _ = try await changing.store.apply(CoreFixture.manifest([png, jpg]), etag: nil, eviction: nil)
        let staged = try await changing.stage(bytes, for: png)
        await bulk.setHolding(true)
        let publishing = Task {
            try await changing.store.publish(staged, binding: [png.identifier, jpg.identifier], expecting: png.contentIdentity, urgency: .bulk)
        }
        try await StoreRaceTests.step(bulk)  // the hash
        try await bulk.requireHeldUnits(atLeast: 1)  // the first copy unit
        let source = changing.layout.blobURL(pngKey)
        try changing.fileSystem.write(CoreFixture.bytes(261), to: source, mode: .truncate)
        await bulk.setHolding(false)
        #expect(Set(try await publishing.value.keys) == [png.identifier])
        #expect(await changing.state.core.blobTable[jpgKey] == nil)
        #expect(!changing.exists(changing.layout.blobURL(jpgKey)))
        #expect(try StoreSweepTests.copies(in: changing).isEmpty)
        try changing.fileSystem.write(bytes, to: source, mode: .truncate)
        #expect(await CoreInvariants.violations(of: changing).isEmpty)
    }

    @Test("R-INT-1: a copy replaces a corrupt name under the second extension", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func copyReplacesACorruptName() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(270)
        let png = CoreFixture.entry("a", bytes, ext: "png")
        let jpg = CoreFixture.entry("b", bytes, ext: "jpg")
        let jpgKey = CoreFixture.key(bytes, ext: "jpg")
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([png, jpg]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [jpg], sequence: 1)
        // Integrity verification quarantined the jpg (WP-C's path): its name is doomed `corrupt`, its bytes damaged.
        await harness.store.setResidency(.absent(.neverFetched), of: jpg.identifier, dooming: .corrupt)
        try harness.fileSystem.write(CoreFixture.bytes(271), to: harness.layout.blobURL(jpgKey), mode: .truncate)
        let bound = try await harness.publish(bytes, [png, jpg], sequence: 2)
        #expect(Set(bound.keys) == [png.identifier, jpg.identifier])
        #expect(harness.content(harness.layout.blobURL(jpgKey)) == bytes)
        #expect(await harness.state.core.blobTable[jpgKey] == .live(references: 1))
        #expect(await harness.state.core.publishing.isEmpty)
        #expect(try StoreSweepTests.copies(in: harness).isEmpty)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-STO-9: close during a copy unit drains it, and the publication fails with closed leaving no copy", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func closeDuringACopy() async throws {
        let bulk = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(bulk: bulk)
        let bytes = CoreFixture.bytes(280)
        let png = CoreFixture.entry("a", bytes, ext: "png")
        let jpg = CoreFixture.entry("b", bytes, ext: "jpg")
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([png, jpg]), etag: nil, eviction: nil)
        let staged = try await harness.stage(bytes, for: png)
        await bulk.setHolding(true)
        let publishing = Task {
            try await harness.store.publish(staged, binding: [png.identifier, jpg.identifier], expecting: png.contentIdentity, urgency: .bulk)
        }
        try await StoreRaceTests.step(bulk)  // the hash
        try await bulk.requireHeldUnits(atLeast: 1)  // the first copy unit
        let closing = Task {
            await harness.store.close()
        }
        try await StoreSweepTests.waitForPhase(.closing, harness)
        await bulk.setHolding(false)
        await closing.value
        await #expect(throws: StoreError.closed) {
            try await publishing.value
        }
        #expect(try StoreSweepTests.copies(in: harness).isEmpty)
        #expect(await harness.state.core.publishing.isEmpty)
    }

    /// The extension copies left in staging.
    @available(macOS 15.0, *)
    static func copies(in harness: CoreHarness) throws -> [String] {
        try harness.fileSystem.contentsOfDirectory(at: harness.layout.stagingDirectory).map(\.name).filter { $0.hasSuffix(".parttmp") }
    }

    /// Waits until a caller is parked on the apply gate (polled between yields; no sleeping; ends with the test).
    @available(macOS 15.0, *)
    static func waitForGateWaiter(_ harness: CoreHarness, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await CorePoll.until("a caller parked on the apply gate", sourceLocation: sourceLocation) {
            await !harness.state.core.applyGate.waiters.isEmpty
        }
    }

    /// Waits until the store reaches `phase` (polled between yields; no sleeping; ends with the test).
    @available(macOS 15.0, *)
    static func waitForPhase(_ phase: StorePhase, _ harness: CoreHarness, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await CorePoll.until("the store's phase \(phase)", sourceLocation: sourceLocation) {
            await harness.state.core.phase == phase
        }
    }
}
