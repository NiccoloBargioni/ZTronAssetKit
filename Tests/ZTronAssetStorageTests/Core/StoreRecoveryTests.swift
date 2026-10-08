import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// Failures between the commit protocol, the load rule and the reaper (SPEC §7.3 "EIO on rename"; ARCHITECTURE
/// §4.1, §4.2, §4.4; ADR draft B-15).
@Suite("Core: recovery from failed renames and commits")
struct StoreRecoveryTests {
    @Test("R-STO-5: EIO on the blob placement rename fails the publication with nothing bound and nothing held", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func placementRenameFails() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(220)
        let entry = CoreFixture.entry("a", bytes)
        let key = CoreFixture.key(bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let staged = try await harness.stage(bytes, for: entry)
        // The source of the placement rename is the claimed `.verifying` file (the claim renames `.part`).
        harness.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .io))
        await #expect(throws: StoreError.fileSystem(.io)) {
            try await harness.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .userInitiated)
        }
        #expect(await harness.store.location(for: entry.identifier, extensions: [], recordingAccess: false) == nil)
        #expect(await harness.state.core.blobTable[key] == nil, "no provisional reference survives the failure")
        #expect(await harness.state.core.publishing.isEmpty)
        #expect(!harness.exists(harness.layout.blobURL(key)))
        #expect(await harness.state.core.records[entry.identifier]?.residency == .absent(.neverFetched))
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
        // A later download of the same bytes publishes normally.
        let again = try await harness.stage(bytes, for: entry, sequence: 2)
        let location = try await harness.store.publish(again, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .userInitiated)
        #expect(location[entry.identifier]?.url == harness.layout.blobURL(key))
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-STO-4: EIO on either commit rename keeps the previous generation on disk and the state dirty until a later commit", .timeLimit(.minutes(1)), arguments: ["index.bin", "index.tmp"])
    @available(macOS 15.0, *)
    func commitRenameFails(source: String) async throws {
        let harness = CoreHarness.make()
        let entry = CoreFixture.entry("a", CoreFixture.bytes(230))
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let committed = await harness.state.core.committedGeneration
        // `index.bin` is the source of step 4 (bin → prev), `index.tmp` of step 5 (tmp → bin).
        harness.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: source), occurrence: .nth(1), error: .io))
        await #expect(throws: StoreError.fileSystem(.io)) {
            try await harness.store.markSyncDue()
        }
        #expect(await harness.state.core.committedGeneration == committed)
        #expect(await harness.state.core.commits.soonPending, "the mutation stays dirty")
        // The newest generation a launch would load is still the committed one or the synced attempt, never torn.
        let onDisk = IndexLoadRule.choose(
            Dictionary(uniqueKeysWithValues: IndexFile.allCases.compactMap { file -> (IndexFile, IndexFileRead)? in
                guard let bytes = harness.content(harness.layout.indexURL(file)) else {
                    return nil
                }
                return (file, IndexFileRead(size: Int64(bytes.count), bytes: [UInt8](bytes)))
            })
        )
        #expect(!onDisk.degraded && (onDisk.content?.generation ?? 0) >= committed)
        if source == "index.bin" {
            let bin = try #require(harness.content(harness.layout.indexURL(.current)))
            #expect(try IndexCodec.decode([UInt8](bin)).get().generation == committed, "index.bin keeps the committed generation")
        }
        #expect(await harness.store.nextDeadline() != nil)
        let work = await harness.store.runDueWork()
        let pending = await harness.state.core.commits.soonPending
        #expect(work.committed && !pending)
        await harness.store.close()
        let reopened = CoreHarness.make(disk: harness.fileSystem.survivingDisk())
        let report = try await reopened.store.open()
        #expect(report.syncDue && !report.degraded)
        #expect(await CoreInvariants.violations(of: reopened).isEmpty)
    }

    @Test("R-STO-4: keys doomed only in a loaded index.tmp wait for a commit that survives the failed launch commit", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func temporaryGenerationDoomsWaitForACommit() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(240)
        let entry = CoreFixture.entry("x", bytes)
        let key = CoreFixture.key(bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [entry])
        try await harness.store.flush(.durable)
        let binGeneration = await harness.state.core.committedGeneration
        // The prune's commit syncs index.tmp (x pruned, its blob doomed), then fails at bin → prev.
        harness.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: "index.bin"), occurrence: .nth(1), error: .io))
        await #expect(throws: StoreError.fileSystem(.io)) {
            try await harness.store.apply(CoreFixture.manifest([]), etag: nil, eviction: nil)
        }
        // The next launch loads index.tmp, and its launch commit fails twice with ENOSPC (removing index.tmp).
        let reopened = CoreHarness.make(disk: harness.fileSystem.survivingDisk())
        let tmp = URLMatcher(lastComponentSuffix: "index.tmp")
        reopened.fileSystem.addFault(FaultRule(operation: .write, matching: tmp, occurrence: .nth(1), error: .noSpace))
        reopened.fileSystem.addFault(FaultRule(operation: .write, matching: tmp, occurrence: .nth(2), error: .noSpace))
        let report = try await reopened.store.open()
        #expect(await reopened.state.core.records[entry.identifier] == nil, "the loaded generation is index.tmp's")
        #expect(report.generation == binGeneration, "only index.bin's generation survived the launch")
        #expect(!reopened.exists(reopened.layout.indexURL(.temporary)))
        reopened.time.advance(by: 3_600)
        #expect(await reopened.store.deletionBlocker(key) == .commit, "acknowledged and past its grace, but dropped by no surviving generation")
        #expect(await reopened.store.reapDeletable(maxKeys: 10).filesRemoved == 0)
        #expect(reopened.exists(reopened.layout.blobURL(key)))
        // Once a commit holding the drop succeeds, the key goes.
        var reaped = await reopened.store.runDueWork().reapedKeys
        reopened.time.advance(by: 3_600)
        reaped += await reopened.store.runDueWork().reapedKeys
        #expect(reaped == 1)
        #expect(!reopened.exists(reopened.layout.blobURL(key)))
    }

    @Test("R-STO-9: after the root was replaced nothing under it is deleted any more", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func replacedRootStopsTheReaper() async throws {
        let (harness, keyA, _) = try await StoreDeletionTests.prunedStore()
        _ = try await harness.store.apply(CoreFixture.manifest([CoreFixture.entry("b", CoreFixture.bytes(71))]), etag: nil, eviction: nil)
        try harness.fileSystem.removeItem(at: harness.layout.lockURL)
        try harness.fileSystem.write(Data(), to: harness.layout.lockURL, mode: .truncate)
        await #expect(throws: StoreError.storageUnavailable(.rootVanished)) {
            try await harness.store.markSyncDue()
        }
        harness.time.advance(by: 3_600)
        let work = await harness.store.runDueWork()
        #expect(work.reapedKeys == 0 && harness.exists(harness.layout.blobURL(keyA)))
        #expect(await harness.store.deletionBlocker(keyA) == .unavailable)
        #expect(await harness.store.reapDeletable(maxKeys: 10).filesRemoved == 0)
        #expect(await harness.store.nextDeadline() == nil)
    }
}
