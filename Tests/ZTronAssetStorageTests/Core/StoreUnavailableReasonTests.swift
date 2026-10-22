import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Orchestrator ruling L5-R4 (level 5 close-out; CCR-G3, L5-V3-02): `AssetStore.unavailableReason`, the one package
/// read the facade needs to own the B-15 reopen. It is `nil` while the store can write, `.rootVanished` once a replaced
/// root was detected, and the read-only reason of a launch that could not read an index file (B-34).
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
