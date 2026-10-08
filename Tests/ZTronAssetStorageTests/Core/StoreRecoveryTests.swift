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
        #expect(StoreRecoveryTests.stagingNames(harness).isEmpty, "the claimed file is discarded, not stranded in staging")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
        // A later download of the same bytes publishes normally.
        let again = try await harness.stage(bytes, for: entry, sequence: 2)
        let location = try await harness.store.publish(again, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .userInitiated)
        #expect(location[entry.identifier]?.url == harness.layout.blobURL(key))
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-INT-2: EIO while hashing the claimed file fails the publication and discards the claim and its sidecar", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func hashReadFails() async throws {
        let harness = CoreHarness.make()
        let bytes = CoreFixture.bytes(221)
        let entry = CoreFixture.entry("a", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        let staged = try await harness.stage(bytes, for: entry, sidecar: true)
        #expect(StoreRecoveryTests.stagingNames(harness).count == 2)
        harness.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .io))
        await #expect(throws: StoreError.fileSystem(.io)) {
            try await harness.store.publish(staged, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .userInitiated)
        }
        #expect(StoreRecoveryTests.stagingNames(harness).isEmpty, "the claimed file and its sidecar are discarded")
        #expect(await harness.state.core.blobTable.isEmpty)
        #expect(await harness.state.core.publishing.isEmpty)
        #expect(await harness.state.core.records[entry.identifier]?.residency == .absent(.neverFetched))
        // The engine's retry under a new attempt name publishes normally.
        let again = try await harness.stage(bytes, for: entry, sequence: 2)
        let location = try await harness.store.publish(again, binding: [entry.identifier], expecting: entry.contentIdentity, urgency: .userInitiated)
        #expect(location[entry.identifier]?.url == harness.layout.blobURL(CoreFixture.key(bytes)))
        #expect(StoreRecoveryTests.stagingNames(harness).isEmpty)
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    @Test("R-INT-1: EIO on placing a copy under a second extension binds nothing under it and leaves no copy in staging", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func copyPlacementFails() async throws {
        let bytes = CoreFixture.bytes(262)
        let png = CoreFixture.entry("a", bytes, ext: "png")
        let jpg = CoreFixture.entry("b", bytes, ext: "jpg")
        let jpgKey = CoreFixture.key(bytes, ext: "jpg")
        let harness = CoreHarness.make()
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([png, jpg]), etag: nil, eviction: nil)
        // The source of the copy's placement rename is the verified `.parttmp` copy.
        harness.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: ".parttmp"), occurrence: .nth(1), error: .io))
        let bound = try await harness.publish(bytes, [png, jpg])
        #expect(Set(bound.keys) == [png.identifier], "the png is bound; the jpg copy failed")
        #expect(await harness.state.core.blobTable[jpgKey] == nil)
        #expect(await harness.state.core.publishing.isEmpty)
        #expect(!harness.exists(harness.layout.blobURL(jpgKey)))
        #expect(StoreRecoveryTests.stagingNames(harness).isEmpty, "the copy is removed, not stranded in staging")
        #expect(await CoreInvariants.violations(of: harness).isEmpty)
    }

    /// Review round 2, probe 3: while a `corrupt` name is being replaced the key is live (held in `publishing`), so a
    /// commit captured then must still record its doom; otherwise a crash before the replacement rename leaves an
    /// unreferenced, undoomed name that launch adopts with the rotten bytes still under it.
    @Test("R-STO-5: a commit during a corrupt key's replacement keeps the key doomed, so a crash never adopts the rotten bytes", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func replacementKeepsCorruptDoom() async throws {
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = CoreHarness.make(metadata: metadata)
        let bytes = CoreFixture.bytes(910)
        let key = CoreFixture.key(bytes)
        let a = CoreFixture.entry("a", bytes)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a]), etag: nil, eviction: nil)
        try await harness.publish(bytes, [a], sequence: 1)
        // Bit rot under the name (same size, other bytes); quarantine dooms the name `corrupt` (WP-C's path).
        var rotten = bytes
        rotten[rotten.startIndex] ^= 0xFF
        try harness.fileSystem.write(rotten, to: harness.layout.blobURL(key), mode: .truncate)
        await harness.store.setResidency(.absent(.healing), of: a.identifier, dooming: .corrupt)
        try await harness.store.flush(.ordered)
        // The heal publishes good bytes; its replacement placement is held.
        let staged = try await harness.stage(bytes, for: a, sequence: 2)
        await metadata.setHolding(true)
        let heal = Task {
            try await harness.store.publish(staged, binding: [a.identifier], expecting: a.contentIdentity, urgency: .bulk)
        }
        await metadata.waitForHeldUnits(atLeast: 1)
        await metadata.releaseNext()  // the claim
        await metadata.waitForHeldUnits(atLeast: 1)  // the replacement placement
        #expect(await harness.state.core.publishing.contains(key))
        #expect(await harness.state.core.replacingDooms[key]?.reason == .corrupt)
        // Any commit meanwhile (the engine's runDueWork, a markSynced, a flush) still records the doom.
        let other = Task {
            try await harness.store.markSyncDue()
        }
        await metadata.waitForHeldUnits(atLeast: 2)
        await metadata.release(await metadata.heldUnits[1])
        try await other.value
        let disk = harness.fileSystem.survivingDisk()  // a crash before the replacement rename
        await metadata.setHolding(false)
        let healed = try await heal.value
        #expect(healed[a.identifier]?.url == harness.layout.blobURL(key))
        #expect(await harness.state.core.replacingDooms.isEmpty, "the doom is released once the replacement is in place")

        let reopened = CoreHarness.make(disk: disk)
        _ = try await reopened.store.open()
        let state = await reopened.state
        #expect(reopened.content(reopened.layout.blobURL(key)) == rotten, "the crash image still holds the rotten bytes")
        #expect(state.core.records[a.identifier]?.referencedBlob == nil, "record a is never bound to the rotten bytes")
        guard case .doomed(let info)? = state.core.blobTable[key] else {
            Issue.record("the rotten name is not doomed after the crash: \(String(describing: state.core.blobTable[key]))")
            return
        }
        #expect(info.reason == .corrupt)
        #expect(await reopened.sink.installed.location(for: a.identifier, extensions: []) == nil, "readers are never handed the rotten file")
        // The only invariant broken is the injected rot itself, which the reaper removes after the grace.
        #expect(await CoreInvariants.violations(of: reopened) == ["I-1: \(reopened.layout.blobURL(key).path) holds \(bytes.count) bytes that do not hash to its name"])
        _ = await reopened.store.runDueWork()
        reopened.time.advance(by: 11)
        var reaped = await reopened.store.runDueWork().reapedKeys
        reopened.time.advance(by: 11)
        reaped += await reopened.store.runDueWork().reapedKeys
        #expect(reaped == 1 && !reopened.exists(reopened.layout.blobURL(key)))
        #expect(await CoreInvariants.violations(of: reopened).isEmpty)
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

    /// The names under `staging/`.
    @available(macOS 15.0, *)
    static func stagingNames(_ harness: CoreHarness) -> [String] {
        ((try? harness.fileSystem.contentsOfDirectory(at: harness.layout.stagingDirectory)) ?? []).map(\.name).sorted()
    }
}
