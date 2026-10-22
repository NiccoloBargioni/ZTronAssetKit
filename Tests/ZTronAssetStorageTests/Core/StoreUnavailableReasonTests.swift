import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Orchestrator ruling L5-R4 (level 5 close-out; CCR-G3, L5-V3-02): `AssetStore.unavailableReason`, the one package
/// read the facade needs to own the B-15 reopen. It is `nil` while the store can write, `.rootVanished` once a replaced
/// root was detected, and the read-only reason of a launch that could not read an index file (B-34). Orchestrator ruling
/// L5-R20 (L5-C2-01): `AssetStore.verifyRootNow()`, the commit's own root check on demand, so the facade can detect a
/// root replaced while no commit has run since.
@Suite("Core: unavailable reason")
struct StoreUnavailableReasonTests {
    @Test("R-STO-9: unavailableReason is nil while the store is open and healthy, and rootVanished once a replaced root was detected", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func replacedRoot() async throws {
        let harness = CoreHarness.make()
        #expect(await harness.store.unavailableReason == nil, "nil before open")
        let entry = CoreFixture.entry("a", CoreFixture.bytes(91))
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        #expect(await harness.store.unavailableReason == nil, "nil while open and healthy")
        // Something replaces the root's lock file (a restore, another tool): a new inode at the same path.
        try harness.fileSystem.removeItem(at: harness.layout.lockURL)
        try harness.fileSystem.write(Data(), to: harness.layout.lockURL, mode: .truncate)
        await #expect(throws: StoreError.storageUnavailable(.rootVanished)) {
            try await harness.store.markSyncDue()
        }
        #expect(await harness.store.unavailableReason == .rootVanished, "the replaced root is reported")
        #expect(try await harness.store.planningView().records[entry.identifier] != nil, "reads keep working")
        await harness.store.close()
        #expect(await harness.store.unavailableReason == .rootVanished, "the reason outlives the store's close")
    }

    /// L5-R20: on a healthy root the check is one stat of the lock file and changes nothing: no reason recorded, no
    /// write, no commit counted, and the store still writes. Before `open()` it answers from state, with no I/O.
    @Test("R-STO-9: verifyRootNow answers nil on a healthy root with one stat of the lock file and changes nothing", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func verifyRootNowOnHealthyRoot() async throws {
        let harness = CoreHarness.make()
        #expect(await harness.store.verifyRootNow() == nil, "nil before open")
        #expect(harness.fileSystem.operations.isEmpty, "no I/O before open")
        let entry = CoreFixture.entry("a", CoreFixture.bytes(92))
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let before = harness.fileSystem.operations.count
        let metrics = await harness.store.metrics()
        #expect(await harness.store.verifyRootNow() == nil, "a healthy root verifies")
        let during = harness.fileSystem.operations.dropFirst(before)
        #expect(during.map(\.kind) == [.itemInfo] && during.first?.url == harness.layout.lockURL, "one stat of the lock file: \(during.map(\.kind))")
        #expect(await harness.store.unavailableReason == nil, "no reason recorded")
        #expect(await harness.store.metrics() == metrics, "no commit attempted or counted")
        try await harness.store.markSyncDue()
        await harness.store.close()
    }

    /// L5-R20: a root replaced while no commit ran since (its lock file replaced, or the whole root moved aside) is
    /// detected by the check alone: the store records `.rootVanished` exactly as a commit's detection does, writes nothing,
    /// counts no failed commit, then refuses every commit and mutating call while reads keep working, and answers the next
    /// check from state.
    @Test("R-STO-9: verifyRootNow detects a root replaced while no commit ran, and the store then behaves as after a commit's detection", .timeLimit(.minutes(1)), arguments: [false, true])
    @available(macOS 15.0, iOS 18.0, *)
    func verifyRootNowOnReplacedRoot(movesRootAside: Bool) async throws {
        let harness = CoreHarness.make()
        let entry = CoreFixture.entry("a", CoreFixture.bytes(93))
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        if movesRootAside {
            // An OS purge of the whole root: nothing is left at its path.
            let root = harness.layout.lockURL.deletingLastPathComponent()
            try harness.fileSystem.rename(from: root, to: root.deletingLastPathComponent().appendingPathComponent("aside", isDirectory: true), mode: .exclusive)
        } else {
            // Something replaces the root's lock file (a restore, another tool): a new inode at the same path.
            try harness.fileSystem.removeItem(at: harness.layout.lockURL)
            try harness.fileSystem.write(Data(), to: harness.layout.lockURL, mode: .truncate)
        }
        #expect(await harness.store.unavailableReason == nil, "setup: no commit has noticed it")
        let mutations = harness.fileSystem.mutationCount
        let metrics = await harness.store.metrics()
        #expect(await harness.store.verifyRootNow() == .rootVanished, "the replaced root is detected")
        #expect(harness.fileSystem.mutationCount == mutations, "the check writes nothing")
        #expect(await harness.store.metrics() == metrics, "the check is not a failed commit")
        #expect(await harness.store.unavailableReason == .rootVanished, "recorded as a commit's detection records it")
        await #expect(throws: StoreError.storageUnavailable(.rootVanished)) {
            try await harness.store.markSyncDue()
        }
        #expect(harness.fileSystem.mutationCount == mutations, "the refused call wrote nothing either")
        #expect(try await harness.store.planningView().records[entry.identifier] != nil, "reads keep working")
        let operations = harness.fileSystem.operations.count
        #expect(await harness.store.verifyRootNow() == .rootVanished, "asked again")
        #expect(harness.fileSystem.operations.count == operations, "answered from state, with no I/O")
        await harness.store.close()
        #expect(await harness.store.unavailableReason == .rootVanished, "the reason outlives the store's close")
    }

    /// The read-only lifetime of ADR draft B-34 (`StoreRecoveryTests.unreadableIndexOpensReadOnly`): the first read of
    /// `index.bin` fails with EIO, so the launch serves what it loaded and writes nothing.
    @Test("R-STO-4: unavailableReason reports the read-only lifetime of a launch that could not read an index file", .timeLimit(.minutes(1)))
    @available(macOS 15.0, iOS 18.0, *)
    func readOnlyLifetime() async throws {
        let first = CoreHarness.make()
        try await StoreRecoveryTests.quarantine(first)
        await first.store.close()
        let second = CoreHarness.make(disk: first.fileSystem.survivingDisk())
        second.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: "index.bin"), occurrence: .nth(1), error: .io))
        _ = try await second.store.open()
        #expect(await second.store.unavailableReason == .ioFailure, "the read-only reason of the lifetime")
        await #expect(throws: StoreError.storageUnavailable(.ioFailure)) {
            try await second.store.markSyncDue()
        }
        await second.store.close()
    }
}
