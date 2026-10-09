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

    /// Review round 3, probe 4: the placement unit creates `blobs/<aa>/` before its rename; when the rename fails, the
    /// next placement into that fan-out finds it already there, so nothing would make the fan-out's own entry in
    /// `blobs/` durable before the commit that references a blob in it (ARCHITECTURE §3, §4.1 step 1).
    @Test("R-STO-5: a fan-out created by a failed placement is synced into blobs/ before a commit references a blob in it", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func failedPlacementFanOutIsSynced() async throws {
        let firstSeed: UInt64 = 600
        let first = CoreFixture.bytes(firstSeed)
        let fanOut = ContentHash.sha256(of: first).fanOut
        let secondSeed = try #require((firstSeed + 1..<firstSeed + 10_000).first { ContentHash.sha256(of: CoreFixture.bytes($0)).fanOut == fanOut })
        let second = CoreFixture.bytes(secondSeed)
        print("R-STO-5 fan-out probe: seeds \(firstSeed) and \(secondSeed) share fan-out \(fanOut)")
        let harness = CoreHarness.make(mode: .powerLossDropUnsynced)
        let a = CoreFixture.entry("a", first)
        let b = CoreFixture.entry("b", second)
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([a, b]), etag: nil, eviction: nil)
        // a's placement creates the fan-out, then its rename fails.
        harness.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .io))
        let stagedA = try await harness.stage(first, for: a)
        await #expect(throws: StoreError.fileSystem(.io)) {
            try await harness.store.publish(stagedA, binding: [a.identifier], expecting: a.contentIdentity, urgency: .bulk)
        }
        #expect(harness.exists(harness.layout.fanOutDirectory(for: ContentHash.sha256(of: first))), "the failed placement created the fan-out")
        // b lands in the same fan-out, and an ordered commit references it.
        try await harness.publish(second, [b], sequence: 2)
        try await harness.store.flush(.ordered)
        // Power fails right after the commit returned.
        let reopened = CoreHarness.make(disk: harness.fileSystem.survivingDisk())
        let report = try await reopened.store.open()
        #expect(report.missingBlobs == 0, "a committed blob was lost by the power loss")
        let location = await reopened.store.location(for: b.identifier, extensions: [], recordingAccess: false)
        #expect(location.flatMap { reopened.content($0.url) } == second)
        #expect(await CoreInvariants.violations(of: reopened).isEmpty)
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
        try await metadata.requireHeldUnits(atLeast: 1)
        await metadata.releaseNext()  // the claim
        try await metadata.requireHeldUnits(atLeast: 1)  // the replacement placement
        #expect(await harness.state.core.publishing.contains(key))
        #expect(await harness.state.core.replacingDooms[key]?.reason == .corrupt)
        // Any commit meanwhile (the engine's runDueWork, a markSynced, a flush) still records the doom.
        let other = Task {
            try await harness.store.markSyncDue()
        }
        try await metadata.requireHeldUnits(atLeast: 2)
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
        // Step 4 is rolled back when step 5 fails (ADR draft B-28), so index.bin is never missing after a failed commit.
        let bin = try #require(harness.content(harness.layout.indexURL(.current)), "index.bin is missing after the failed commit")
        #expect(try IndexCodec.decode([UInt8](bin)).get().generation == committed, "index.bin keeps the committed generation")
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

    /// Which step of the launch commit's promotion of the loaded `index.tmp` fails (ADR draft B-28).
    enum PromotionFault: String, CaseIterable, Sendable {
        /// `index.tmp → index.bin` fails with EIO: step 4 is rolled back and `index.tmp` stays.
        case rename
        /// The root's sync after the promotion's renames fails with EIO: `index.tmp` is `index.bin` now, unordered.
        case sync
        /// The sync of the loaded `index.tmp` before the renames fails with EIO (review close-out, probe VP7: a killed
        /// process may have written it without its step 3): nothing is renamed and the promotion stays pending.
        case syncFile
    }

    @Test(
        "R-STO-4: keys doomed only in a loaded index.tmp wait for a commit that survives the failed launch commit",
        .timeLimit(.minutes(1)),
        arguments: PromotionFault.allCases
    )
    @available(macOS 15.0, *)
    func temporaryGenerationDoomsWaitForACommit(fault: PromotionFault) async throws {
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
        let pruneGeneration = try IndexCodec.decode([UInt8](try #require(harness.content(harness.layout.indexURL(.temporary))))).get().generation
        // The next launch loads index.tmp. Its launch commit must promote it to index.bin before writing index.tmp
        // again (ADR draft B-28), and the promotion fails here, so the generation that dooms x is not committed yet.
        let reopened = CoreHarness.make(disk: harness.fileSystem.survivingDisk())
        switch fault {
        case .rename:
            reopened.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .io))
        case .sync:
            // The first root sync is open()'s own barrier (tolerated); the second is the promotion's.
            reopened.fileSystem.addFault(FaultRule(operation: .synchronizeDirectory, matching: URLMatcher(lastComponentSuffix: "v1"), occurrence: .nth(2), error: .io))
        case .syncFile:
            reopened.fileSystem.addFault(FaultRule(operation: .synchronizeFile, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .io))
        }
        let report = try await reopened.store.open()
        #expect(await reopened.state.core.records[entry.identifier] == nil, "the loaded generation is index.tmp's")
        #expect(report.generation == binGeneration, "only index.bin's generation is committed after the failed launch commit")
        let bin = try IndexCodec.decode([UInt8](try #require(reopened.content(reopened.layout.indexURL(.current))))).get()
        switch fault {
        case .rename, .syncFile:
            #expect(reopened.exists(reopened.layout.indexURL(.temporary)), "the loaded index.tmp is never truncated before it is promoted")
            #expect(bin.generation == binGeneration, "the failed promotion was rolled back")
            #expect(await reopened.state.core.commits.pendingPromotion == pruneGeneration, "the next commit promotes it again")
        case .sync:
            #expect(bin.generation == pruneGeneration, "the rename happened; only its ordering failed")
            #expect(await reopened.state.core.commits.pendingPromotion == nil, "there is no index.tmp left to promote")
        }
        reopened.time.advance(by: 3_600)
        #expect(await reopened.store.deletionBlocker(key) == .commit, "acknowledged and past its grace, but dropped by no committed generation")
        #expect(await reopened.store.reapDeletable(maxKeys: 10).filesRemoved == 0)
        #expect(reopened.exists(reopened.layout.blobURL(key)))
        // Once a commit holding the drop succeeds (promoting index.tmp first where it is still pending), the key goes.
        var reaped = await reopened.store.runDueWork().reapedKeys
        #expect(await reopened.state.core.committedGeneration > pruneGeneration)
        reopened.time.advance(by: 3_600)
        reaped += await reopened.store.runDueWork().reapedKeys
        #expect(reaped == 1)
        #expect(!reopened.exists(reopened.layout.blobURL(key)))
        #expect(await CoreInvariants.violations(of: reopened).isEmpty)
    }

    /// The ENOSPC fallback of the commit unit (ADR-015 as amended by ADR draft B-28) on a disk holding `index.prev` of
    /// generation 4: it may drop `index.prev` only while `index.bin` is the file the store knows to hold its committed
    /// generation, never because of what `index.bin`'s header says (close-out cycle 5). The store's knowledge is what a
    /// launch builds from the loaded disk (`LaunchState.ledger(rootOrdered:)`); then the disk changes as the case says.
    @Test(
        "R-STO-4: the ENOSPC fallback removes index.prev only while index.bin holds the committed generation",
        arguments: ["committed", "missing", "rotten", "other generation", "forged header"]
    )
    @available(macOS 15.0, *)
    func noSpaceFallbackKeepsTheNewestGeneration(bin: String) throws {
        let layout = CoreFixture.layout
        let fileSystem = FakeFileSystem(time: ManualTimeSource())
        var path = URL(fileURLWithPath: "/", isDirectory: true)
        for component in layout.blobsDirectory.pathComponents.dropFirst() {
            path.appendPathComponent(component, isDirectory: true)
            try fileSystem.createDirectory(at: path)
        }
        var content = IndexContent.empty(storeID: StoreIdentifier.derived(fromSeed: 7))
        func encoded(_ generation: UInt64) throws -> Data {
            content.generation = generation
            return try #require(IndexCodec.encode(content))
        }
        try fileSystem.write(try encoded(4), to: layout.indexURL(.previous), mode: .truncate)
        switch bin {
        case "committed", "missing":
            try fileSystem.write(try encoded(5), to: layout.indexURL(.current), mode: .truncate)
        case "rotten", "other generation":
            var rotten = try encoded(5)
            rotten[rotten.count - 1] ^= 0xFF
            rotten.removeLast()
            try fileSystem.write(rotten, to: layout.indexURL(.current), mode: .truncate)
        case "forged header":
            // A copy of generation 5 whose header's generation field lost bit 0: it names 4, the committed generation,
            // with the right size; only the trailer fails.
            let valid = [UInt8](try encoded(5))
            var header = try #require(IndexHeader.parse(valid))
            header.generation = 4
            try fileSystem.write(Data(header.encoded() + valid[IndexHeader.length...]), to: layout.indexURL(.current), mode: .truncate)
        default:
            break
        }
        let loaded = StoreRecoveryTests.loadRule(fileSystem.survivingDisk())
        let launch = LaunchState.build(outcome: loaded, onDisk: [:], blobsRecreated: false, seed: 7, now: Date(timeIntervalSince1970: 0), layout: layout)
        let ledger = launch.ledger(rootOrdered: true)
        #expect(ledger.committedGeneration == (bin == "committed" || bin == "missing" ? 5 : 4))
        #expect(ledger.committedFile == (bin == "committed" || bin == "missing" ? .current : .previous))
        switch bin {
        case "missing":
            // index.bin vanished after the load (an outside deletion inside the private root).
            try fileSystem.removeItem(at: layout.indexURL(.current))
        case "other generation":
            // An attempt whose root sync failed renamed its synced index.tmp over the rotten index.bin: valid, but the
            // store never counted it.
            try fileSystem.write(try encoded(6), to: layout.indexURL(.current), mode: .truncate)
        default:
            break
        }
        fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .every, error: .noSpace))
        var input = IndexCommitInput(layout: layout, content: content, dirtyFanOuts: [], blobsDirectoryDirty: false, durability: .ordered, lock: nil)
        input.content.generation = 7
        input.committedGeneration = ledger.committedGeneration
        input.committedFile = ledger.committedFile
        let outcome = IndexCommitUnit.run(input, fileSystem: fileSystem)
        #expect(throws: StoreError.fileSystem(.noSpace)) {
            try outcome.result.get()
        }
        #expect(fileSystem.operations.filter { $0.kind == .write && $0.url == layout.indexURL(.temporary) }.count == 2, "the write is retried once")
        let previousKept = ((try? fileSystem.itemInfo(at: layout.indexURL(.previous))) ?? nil) != nil
        #expect(previousKept == (bin != "committed"), "index.bin \(bin): index.prev kept \(previousKept)")
        #expect(((try? fileSystem.itemInfo(at: layout.indexURL(.temporary))) ?? nil) == nil, "the failed index.tmp is removed")
        #expect(outcome.committedFile == ledger.committedFile, "nothing was renamed, so the committed file is where it was")
    }

    /// How the commit before the kill was stopped between its two renames (review round 3, probe 1).
    enum StepFiveInterruption: String, CaseIterable, Sendable {
        /// The process died after `index.bin → index.prev` and before `index.tmp → index.bin`.
        case crash
        /// `index.tmp → index.bin` failed with EIO; the process died right after.
        case eio
    }

    /// Review round 3, probe 1: a launch that loads `index.tmp` (or finds no `index.bin`) on a full volume must keep a
    /// valid generation on disk. Before the fix the launch commit truncated `index.tmp`, hit ENOSPC, removed `index.tmp`
    /// and `index.prev` and failed again: no index was left, and the next launch re-adopted the corrupt-doomed name.
    @Test(
        "R-STO-4: ENOSPC at a launch after a crash between commit steps 4 and 5 keeps a valid generation on disk and never re-adopts a corrupt doom",
        .timeLimit(.minutes(1)),
        arguments: StepFiveInterruption.allCases
    )
    @available(macOS 15.0, *)
    func fullVolumeLaunchAfterStepFive(interruption: StepFiveInterruption) async throws {
        let (disk, entry, key) = try await StoreRecoveryTests.interruptedBetweenRenames(interruption)
        let newest = try #require(StoreRecoveryTests.loadRule(disk).content?.generation)
        #expect(StoreRecoveryTests.loadRule(disk).chosen == .temporary, "the interrupted generation is only in index.tmp")
        // Lifetime 2: the volume is full; every write of index.tmp fails.
        let second = CoreHarness.make(disk: disk)
        second.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .every, error: .noSpace))
        let report = try await second.store.open()
        #expect(!report.degraded)
        #expect(report.generation == newest, "the loaded index.tmp was promoted to index.bin before any write")
        #expect(StoreRecoveryTests.isDoomed(await second.state.core.blobTable[key], .corrupt))
        await second.store.close()
        #expect(CoreInvariants.blobRemovals(second.fileSystem.operations, layout: second.layout).isEmpty)
        let left = StoreRecoveryTests.loadRule(second.fileSystem.survivingDisk())
        #expect(!left.degraded && left.content?.generation == newest, "a valid generation is left on disk: \(String(describing: left.chosen))")
        // Lifetime 3: space is back.
        let afterFull = second.fileSystem.survivingDisk()
        let headers = IndexFile.allCases.compactMap { afterFull.files[CoreFixture.layout.indexURL($0).path].flatMap(IndexHeader.parse) }
        let third = CoreHarness.make(disk: afterFull)
        let thirdReport = try await third.store.open()
        #expect(!thirdReport.degraded)
        #expect(thirdReport.generation >= newest)
        #expect(headers.allSatisfy { thirdReport.launchEpoch > $0.generation }, "I-5: the launch epoch reuses a generation")
        #expect(await third.state.core.records[entry.identifier] != nil, "the quarantined record survived")
        _ = try await third.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        #expect(await third.store.location(for: entry.identifier, extensions: [], recordingAccess: false) == nil, "the corrupt name is never re-adopted (§4.4)")
        #expect(StoreRecoveryTests.isDoomed(await third.state.core.blobTable[key], .corrupt))
    }

    /// Close-out cycle 3, probe VPC2-D: commit step 4 renamed an invalid `index.bin` over `index.prev` although
    /// `index.prev` held the only valid generation. Lifetime 1 dooms a rotten blob `corrupt` and closes durably; one body
    /// byte of `index.bin` then flips, so the load rule picks `index.prev`. Lifetime 2's launch commit fails at step 5
    /// (EIO): before the fix step 4 had already moved the rotten file over `index.prev` (and the rollback moved it back),
    /// so the only valid generation was the synced `index.tmp`, which the next commit's ENOSPC fallback removed on the
    /// now full volume. Lifetime 3 then found no valid index, lost the record and served the `corrupt`-doomed name.
    @Test(
        "R-STO-4: a rotten index.bin never replaces a valid index.prev, so EIO on step 5 and then a full volume keep a valid generation",
        .timeLimit(.minutes(1)),
        arguments: [CrashMode.processKill, .powerLossKeepMetadata]
    )
    @available(macOS 15.0, *)
    func rottenCurrentNeverReplacesPrevious(end: CrashMode) async throws {
        try await StoreRecoveryTests.rottenCurrentLifetimes(end: end, rot: .body)
    }

    /// Close-out cycle 5 (review probe (c)): the same three lifetimes, but the bit that flips in `index.bin` is in its
    /// header's generation field, so the rotten header names `index.prev`'s generation, the one lifetime 2 counts
    /// committed. The header has no checksum of its own (the trailer covers header and body), so it parses, and the size
    /// is right. The commit unit took a header naming the committed generation for proof that `index.bin` held it: step 4
    /// moved the rotten file over the only valid `index.prev`, and the ENOSPC fallback could remove `index.prev`; lifetime 3
    /// then found no valid index, lost the record and served the `corrupt`-doomed name.
    @Test(
        "R-STO-4: an index.bin whose rotten header names the committed generation never replaces a valid index.prev, so EIO on step 5 and then a full volume keep a valid generation",
        .timeLimit(.minutes(1)),
        arguments: [CrashMode.processKill, .powerLossKeepMetadata]
    )
    @available(macOS 15.0, *)
    func forgedHeaderNeverReplacesPrevious(end: CrashMode) async throws {
        try await StoreRecoveryTests.rottenCurrentLifetimes(end: end, rot: .generationField)
    }

    /// How lifetime 1's `index.bin` rots before lifetime 2 (durably: bit rot, not an unsynced write).
    enum IndexRot: Sendable {
        /// One body byte flips; the header still names the file's own generation (probe VPC2-D).
        case body
        /// One bit of the header's generation field flips, so the header names `index.prev`'s generation (close-out
        /// cycle 5); only the trailer fails.
        case generationField
    }

    /// Lifetime 1 dooms a rotten blob `corrupt` and closes durably; `index.bin` then rots as `rot` says. Lifetime 2's
    /// launch commit fails at step 5 (EIO), then the volume is full for its close; lifetime 3 has space again. A valid
    /// generation, the record and the `corrupt` doom survive all three.
    @available(macOS 15.0, *)
    static func rottenCurrentLifetimes(end: CrashMode, rot: IndexRot) async throws {
        // Lifetime 1: the corrupt doom is committed durably, then two more commits (the last one close()'s durable flush).
        let first = CoreHarness.make()
        try await StoreRecoveryTests.quarantine(first)
        try await first.store.markSyncDue()
        await first.store.close()
        var disk = first.fileSystem.survivingDisk()
        let binPath = CoreFixture.layout.indexURL(.current).path
        let prevPath = CoreFixture.layout.indexURL(.previous).path
        let previous = try IndexCodec.decode(try #require(disk.files[prevPath], "index.prev exists after three commits")).get().generation
        var rotten = try #require(disk.files[binPath])
        switch rot {
        case .body:
            rotten[IndexHeader.length] ^= 0xFF
        case .generationField:
            var header = try #require(IndexHeader.parse(rotten))
            let flipped = (header.generation ^ previous).nonzeroBitCount
            try #require(flipped == 1, "index.bin's generation \(header.generation) and index.prev's \(previous) differ in one bit")
            header.generation = previous
            rotten.replaceSubrange(0..<IndexHeader.length, with: header.encoded())
            #expect(IndexHeader.parse(rotten)?.generation == previous && rotten.count == disk.files[binPath]?.count, "the header parses, names the committed generation, and the size is right")
        }
        disk.files[binPath] = rotten
        disk.makeDurable()
        let loaded = StoreRecoveryTests.loadRule(disk)
        #expect(loaded.chosen == .previous && loaded.degraded && loaded.content?.generation == previous)
        // Lifetime 2: the launch commit's step 5 (index.tmp → index.bin) fails with EIO; then the volume is full.
        let second = CoreHarness.make(disk: disk, mode: end)
        second.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .io))
        let report = try await second.store.open()
        #expect(report.degraded && report.generation == previous)
        let kept = second.content(second.layout.indexURL(.previous)).flatMap { try? IndexCodec.decode([UInt8]($0)).get().generation }
        #expect(kept == previous, "\(rot): the committed generation \(previous) is still on disk after the failed launch commit: index.prev holds \(String(describing: kept))")
        second.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .every, error: .noSpace))
        await #expect(throws: StoreError.fileSystem(.noSpace)) {
            try await second.store.markSyncDue()
        }
        await second.store.close()
        #expect(CoreInvariants.blobRemovals(second.fileSystem.operations, layout: second.layout).isEmpty)
        let afterFull = second.fileSystem.survivingDisk()
        let left = StoreRecoveryTests.loadRule(afterFull)
        #expect((left.content?.generation ?? 0) >= previous, "\(rot), \(end): a valid generation is left after the full volume: \(String(describing: left.chosen))")
        // Lifetime 3: space is back.
        let headers = IndexFile.allCases.compactMap { afterFull.files[CoreFixture.layout.indexURL($0).path].flatMap(IndexHeader.parse) }
        let third = CoreHarness.make(disk: afterFull)
        let thirdReport = try await third.store.open()
        #expect(headers.allSatisfy { thirdReport.launchEpoch > $0.generation }, "I-5: the launch epoch reuses a generation")
        #expect(await third.state.core.records[QuarantineFixture.entry.identifier] != nil, "\(rot), \(end): the quarantined record survived")
        _ = try await third.store.apply(CoreFixture.manifest([QuarantineFixture.entry]), etag: nil, eviction: nil)
        #expect(await third.store.location(for: QuarantineFixture.entry.identifier, extensions: [], recordingAccess: false) == nil, "\(rot), \(end): the corrupt name is never re-adopted (§4.4)")
        #expect(StoreRecoveryTests.isDoomed(await third.state.core.blobTable[QuarantineFixture.key], .corrupt))
    }

    /// Close-out cycle 3, probe VPC2-K: while a promotion of the loaded `index.tmp` is pending, every commit first syncs
    /// `index.tmp`. When that file is gone (an outside deletion inside the private root, or a rename that took effect
    /// but reported failure), the sync threw `notFound`, the promotion stayed pending, and every later commit failed,
    /// `close()`'s durable flush included. A vanished `index.tmp` now completes the promotion without a commit: it is no
    /// longer pending, its generation never counts as committed, and the commit goes on with steps 1–6.
    @Test("R-STO-4: a pending promotion whose index.tmp vanished stops blocking commits and never counts as committed", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func vanishedPromotionStopsBlockingCommits() async throws {
        // Lifetime 1 is killed right before its last commit's step 4: its synced index.tmp is the newest generation.
        let (killed, entry, key) = try await StoreRecoveryTests.killedInLastCommit { $0.kind == .rename && $0.url.lastPathComponent == "index.bin" }
        let loaded = StoreRecoveryTests.loadRule(killed)
        #expect(loaded.chosen == .temporary)
        let promoted = try #require(loaded.content?.generation)
        // Lifetime 2: the launch commit's promotion fails at its sync of index.tmp, so the promotion stays pending.
        let second = CoreHarness.make(disk: killed)
        second.fileSystem.addFault(FaultRule(operation: .synchronizeFile, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .io))
        let report = try await second.store.open()
        let surviving = report.generation
        #expect(surviving < promoted)
        #expect(await second.state.core.commits.pendingPromotion == promoted)
        try second.fileSystem.removeItem(at: second.layout.indexURL(.temporary))
        // The next commit resolves the promotion, then fails on its own write: the vanished generation is not pending
        // any more and was never committed.
        second.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .io))
        await #expect(throws: StoreError.fileSystem(.io)) {
            try await second.store.flush(.ordered)
        }
        #expect(await second.state.core.commits.pendingPromotion == nil, "a vanished index.tmp is no longer pending")
        #expect(await second.state.core.committedGeneration == surviving, "the vanished generation never counts as committed")
        // Later commits and close()'s durable flush succeed.
        try await second.store.flush(.durable)
        let committed = await second.state.core.committedGeneration
        #expect(committed > promoted)
        await second.store.close()
        #expect(CoreInvariants.blobRemovals(second.fileSystem.operations, layout: second.layout).isEmpty)
        let left = StoreRecoveryTests.loadRule(second.fileSystem.survivingDisk())
        #expect(!left.degraded && (left.content?.generation ?? 0) >= committed)
        // Lifetime 3 keeps the record and the corrupt doom that lifetime 2 carried over from the vanished generation.
        let third = CoreHarness.make(disk: second.fileSystem.survivingDisk())
        let thirdReport = try await third.store.open()
        #expect(!thirdReport.degraded && thirdReport.launchEpoch > committed)
        #expect(await third.state.core.records[entry.identifier] != nil)
        #expect(StoreRecoveryTests.isDoomed(await third.state.core.blobTable[key], .corrupt), "the rotten blob is still doomed corrupt")
    }

    /// Close-out cycle 4 (review "ADR accuracy, B-28 amendment 2"): only a stat that finds no `index.tmp` completes a
    /// pending promotion without a commit. A `notFound` from the promotion's sync of a file the stat just found is an
    /// error like any other: the promotion stays pending, `index.tmp` is left as it was (it may hold the newest loaded
    /// generation), and the next attempt's stat decides. Before, the sync's `notFound` was taken for a vanish: the
    /// launch commit then truncated and rewrote the loaded `index.tmp` in place, so a failed or torn write there would
    /// have dropped the newest generation.
    @Test("R-STO-4: a notFound from the promotion's sync of an index.tmp that exists keeps the promotion pending and the file unchanged", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func promotionSyncNotFoundStaysPending() async throws {
        // Lifetime 1 is killed right before its last commit's step 4: its synced index.tmp is the newest generation.
        let (killed, entry, _) = try await StoreRecoveryTests.killedInLastCommit { $0.kind == .rename && $0.url.lastPathComponent == "index.bin" }
        let loaded = StoreRecoveryTests.loadRule(killed)
        #expect(loaded.chosen == .temporary)
        let promoted = try #require(loaded.content?.generation)
        let temporary = CoreFixture.layout.indexURL(.temporary).path
        let before = try #require(killed.files[temporary])
        // Lifetime 2: the launch commit's promotion finds index.tmp, and its sync reports notFound.
        let second = CoreHarness.make(disk: killed)
        second.fileSystem.addFault(FaultRule(operation: .synchronizeFile, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .notFound))
        let report = try await second.store.open()
        #expect(report.generation < promoted, "the launch commit failed: the store reports the surviving generation")
        #expect(await second.state.core.commits.pendingPromotion == promoted, "the promotion stays pending")
        #expect(await second.state.core.committedGeneration == report.generation)
        #expect(second.fileSystem.survivingDisk().files[temporary] == before, "index.tmp is unchanged")
        #expect(!second.fileSystem.operations.contains { $0.kind == .write && $0.url.lastPathComponent == "index.tmp" }, "nothing wrote over index.tmp")
        // The next attempt's stat finds the file and promotes it.
        try await second.store.flush(.durable)
        #expect(await second.state.core.commits.pendingPromotion == nil)
        let committed = await second.state.core.committedGeneration
        #expect(committed > promoted)
        await second.store.close()
        let third = CoreHarness.make(disk: second.fileSystem.survivingDisk())
        let thirdReport = try await third.store.open()
        #expect(!thirdReport.degraded && thirdReport.launchEpoch > committed)
        #expect(await third.state.core.records[entry.identifier] != nil, "the record of the promoted generation survives")
    }

    /// Close-out cycle 4, found by enumerating the kill survivors whose index names are not yet ordered (review
    /// "state-space enumeration: pruning justification"): a launch reads the names a killed process renamed but never
    /// synced. `open()`'s root barrier orders them; when that barrier failed, the store still counted the loaded
    /// generation committed, although a power loss can revert it. With the launch commit failing as well (a full
    /// volume), the reaper then unlinked a blob that generation had dropped while the older generation a power loss
    /// brings back still lists its entry: the bytes it would have adopted again were gone (a needless download). A
    /// launch now counts nothing committed until a root sync ordered the names it read (ADR draft B-36).
    @Test("R-CLN-5: a launch whose root barrier fails unlinks nothing a power loss could still need, until a commit succeeds", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func failedLaunchBarrierBlocksTheReaper() async throws {
        // Lifetime 1 prunes `a` and is killed right before that commit's root sync: index.bin names the generation that
        // dropped `a`'s blob, and only a kill keeps that name.
        let (clean, _, _) = try await StoreDeletionTests.prunedStore()
        let start = clean.fileSystem.operations.count
        _ = try await clean.store.apply(CoreFixture.manifest([CoreFixture.entry("b", CoreFixture.bytes(71))]), etag: nil, eviction: nil)
        let operations = clean.fileSystem.operations
        let rootSync = try #require(operations[start...].first { $0.kind == .synchronizeDirectory && $0.url == clean.layout.root })
        let crashPoint = operations[..<rootSync.index].filter(\.kind.isMutation).count
        let killed = CoreHarness.make(crashBefore: crashPoint, mode: .processKill)
        let entryA = CoreFixture.entry("a", CoreFixture.bytes(70))
        let keyA = CoreFixture.key(CoreFixture.bytes(70))
        _ = try await killed.store.open()
        _ = try await killed.store.apply(CoreFixture.manifest([entryA, CoreFixture.entry("b", CoreFixture.bytes(71))]), etag: nil, eviction: nil)
        try await killed.publish(CoreFixture.bytes(70), [entryA], sequence: 1)
        try await killed.publish(CoreFixture.bytes(71), [CoreFixture.entry("b", CoreFixture.bytes(71))], sequence: 2)
        await #expect(throws: StoreError.self) {
            _ = try await killed.store.apply(CoreFixture.manifest([CoreFixture.entry("b", CoreFixture.bytes(71))]), etag: nil, eviction: nil)
        }
        #expect(killed.fileSystem.crashed)
        let survivor = killed.fileSystem.survivingDisk()
        let loaded = try #require(StoreRecoveryTests.loadRule(survivor).content)
        #expect(loaded.records[entryA.identifier] == nil, "the kill keeps the generation that pruned a")
        let reverted = try #require(StoreRecoveryTests.loadRule(IndexSpace.surviving(survivor, .powerLossDropUnsynced)).content)
        #expect(reverted.records[entryA.identifier] != nil && reverted.generation < loaded.generation, "a power loss brings back the generation that still lists a")
        // Lifetime 2: open()'s root barrier fails and the volume is full, so the launch commit fails too.
        let second = CoreHarness.make(disk: survivor, mode: .powerLossDropUnsynced)
        second.fileSystem.addFault(FaultRule(operation: .synchronizeDirectory, matching: URLMatcher(lastComponentSuffix: second.layout.root.lastPathComponent), occurrence: .nth(1), error: .io))
        second.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .every, error: .noSpace))
        _ = try await second.store.open()
        let barrier = try #require(second.fileSystem.operations.first { $0.kind == .synchronizeDirectory && $0.url == second.layout.root })
        #expect(barrier.failure == .io, "the fault hit open()'s root barrier")
        #expect(StoreRecoveryTests.isDoomed(await second.state.core.blobTable[keyA], .unreferenced))
        await second.store.publishSnapshot(urgency: .userInitiated)
        second.time.advance(by: 3_600)
        let work = await second.store.runDueWork()
        #expect(work.reapedKeys == 0 && second.exists(second.layout.blobURL(keyA)), "nothing is unlinked on the strength of a generation whose name is not ordered")
        #expect(await second.store.deletionBlocker(keyA) == .commit)
        // A file system also persists metadata on its own; the fake does so only on a sync, so the test syncs the blob's
        // fan-out as the system would (only the root's sync failed): an unlink made above would now survive a power loss.
        try second.fileSystem.synchronizeDirectory(at: second.layout.blobURL(keyA).deletingLastPathComponent(), level: .barrier)
        // A power loss now: lifetime 3 loads the generation that still lists a, finds its bytes and binds them again.
        let third = CoreHarness.make(disk: second.fileSystem.survivingDisk())
        _ = try await third.store.open()
        #expect(await third.store.location(for: entryA.identifier, extensions: [], recordingAccess: false) != nil, "a's bytes survive")
    }

    /// Close-out cycle 3, found by the state-space enumeration: an I/O error while the launch read an index file made
    /// the load rule see that file as absent (a failed stat) or torn (a failed read), so the launch committed over it:
    /// it rewrote or moved the newest valid generation it had not read (with only index.tmp valid, a fresh empty store
    /// overwrote it). A launch that cannot read its index files now serves what it loaded read-only and writes nothing.
    @Test(
        "R-STO-4: a launch that cannot read an index file serves read-only and never writes over it",
        .timeLimit(.minutes(1)),
        arguments: [FSOpKind.itemInfo, .read]
    )
    @available(macOS 15.0, *)
    func unreadableIndexOpensReadOnly(failing operation: FSOpKind) async throws {
        let first = CoreHarness.make()
        try await StoreRecoveryTests.quarantine(first)
        try await first.store.markSyncDue()
        await first.store.close()
        let disk = first.fileSystem.survivingDisk()
        let indexFiles = IndexFile.allCases.map { disk.files[CoreFixture.layout.indexURL($0).path] }
        let newest = try #require(StoreRecoveryTests.loadRule(disk).content?.generation)
        // Lifetime 2: the first stat or read of index.bin fails with EIO.
        let second = CoreHarness.make(disk: disk)
        second.fileSystem.addFault(FaultRule(operation: operation, matching: URLMatcher(lastComponentSuffix: "index.bin"), occurrence: .nth(1), error: .io))
        let report = try await second.store.open()
        #expect(report.degraded)
        #expect(await second.state.core.unavailable == .ioFailure)
        await #expect(throws: StoreError.storageUnavailable(.ioFailure)) {
            try await second.store.markSyncDue()
        }
        await second.store.close()
        let indexMutations = second.mutations.filter { $0.url.lastPathComponent.hasPrefix("index.") || $0.destination?.lastPathComponent.hasPrefix("index.") == true }
        #expect(indexMutations.isEmpty, "\(operation): the launch wrote \(indexMutations.map { "\($0.kind) \($0.url.lastPathComponent)" })")
        let after = second.fileSystem.survivingDisk()
        #expect(IndexFile.allCases.map { after.files[CoreFixture.layout.indexURL($0).path] } == indexFiles, "\(operation): every index file is unchanged")
        // Lifetime 3 reads everything again.
        let third = CoreHarness.make(disk: after)
        let thirdReport = try await third.store.open()
        #expect(!thirdReport.degraded && thirdReport.launchEpoch > newest)
        #expect(await third.state.core.unavailable == nil)
        #expect(await third.state.core.records[QuarantineFixture.entry.identifier] != nil)
        #expect(StoreRecoveryTests.isDoomed(await third.state.core.blobTable[QuarantineFixture.key], .corrupt))
    }

    /// ADR draft B-34 tells an index file that cannot be read (an error: the launch writes nothing) from one that ends
    /// early (no error, fewer bytes than its size: torn, as a torn write leaves it, and the launch commits as usual).
    @Test("R-STO-4: an index file whose read ends early is torn, not unreadable, and the launch still commits", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func shortIndexReadIsTorn() async throws {
        let slice = IndexSpaceSlice(bin: .newer, previous: .committed, temporary: .absent)
        let fake = IndexSpace.fake(IndexSpace.disk(slice))
        let shortening = MisreportingFileSystem(fake, failing: 0, shortReads: URLMatcher(lastComponentSuffix: "index.bin"))
        let outcome = await IndexLoader.load(layout: IndexSpace.layout, fileSystem: shortening, metadata: InlineBlockingExecutor(), bulk: InlineBlockingExecutor())
        #expect(outcome.unreadable.isEmpty, "a short read is not an error")
        #expect(outcome.chosen == .previous && outcome.content?.generation == 10 && outcome.degraded, "index.bin is torn: index.prev loads, degraded")
        let launch = LaunchState.build(outcome: outcome, onDisk: [:], blobsRecreated: false, seed: IndexSpace.seed, now: IndexSpace.now, layout: IndexSpace.layout)
        #expect(launch.unavailable == nil && launch.degraded, "the launch commits as usual")
    }

    /// Open → apply → publish → the blob rots and is quarantined (`corrupt` doom) → durable flush → one more commit,
    /// stopped between its renames; returns the disk the killed process leaves.
    @available(macOS 15.0, *)
    static func interruptedBetweenRenames(_ interruption: StepFiveInterruption) async throws -> (DiskImage, ManifestEntry, BlobKey) {
        switch interruption {
        case .eio:
            let harness = CoreHarness.make()
            try await StoreRecoveryTests.quarantine(harness)
            harness.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(1), error: .io))
            await #expect(throws: StoreError.fileSystem(.io)) {
                try await harness.store.markSyncDue()
            }
            return (harness.fileSystem.survivingDisk(), QuarantineFixture.entry, QuarantineFixture.key)
        case .crash:
            return try await StoreRecoveryTests.killedInLastCommit { $0.kind == .rename && $0.url.lastPathComponent == "index.tmp" }
        }
    }

    /// The asset `quarantine(_:)` publishes and dooms `corrupt`.
    enum QuarantineFixture {
        static let bytes = CoreFixture.bytes(501)
        static let entry = CoreFixture.entry("a", QuarantineFixture.bytes)
        static let key = CoreFixture.key(QuarantineFixture.bytes)
    }

    /// Open → apply → publish → the blob rots and is quarantined (`corrupt` doom) → durable flush.
    @available(macOS 15.0, *)
    static func quarantine(_ harness: CoreHarness) async throws {
        let entry = QuarantineFixture.entry
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest([entry]), etag: ETag(rawValue: "\"e1\""), eviction: nil)
        try await harness.publish(QuarantineFixture.bytes, [entry], urgency: .userInitiated)
        var rotten = QuarantineFixture.bytes
        rotten[rotten.startIndex] ^= 0xFF
        try harness.fileSystem.write(rotten, to: harness.layout.blobURL(QuarantineFixture.key), mode: .truncate)
        await harness.store.setResidency(.quarantined(until: Date(timeIntervalSinceReferenceDate: 1e9)), of: entry.identifier, dooming: .corrupt)
        try await harness.store.flush(.durable)
    }

    /// `quarantine(_:)`, then one more commit (`markSyncDue`) in a process killed (`.processKill`) right before the
    /// first mutation of that commit that `isCrashPoint` matches in a clean run; returns the disk the killed process
    /// leaves.
    @available(macOS 15.0, *)
    static func killedInLastCommit(before isCrashPoint: (FSOpRecord) -> Bool) async throws -> (DiskImage, ManifestEntry, BlobKey) {
        let clean = CoreHarness.make()
        try await StoreRecoveryTests.quarantine(clean)
        let start = clean.fileSystem.operations.count
        try await clean.store.markSyncDue()
        let operations = clean.fileSystem.operations
        let match = operations[start...].first(where: isCrashPoint)
        let point = try #require(match, "the clean commit performs the crash point")
        let crashPoint = operations[..<point.index].filter(\.kind.isMutation).count
        let harness = CoreHarness.make(crashBefore: crashPoint, mode: .processKill)
        try await StoreRecoveryTests.quarantine(harness)
        await #expect(throws: StoreError.self) {
            try await harness.store.markSyncDue()
        }
        #expect(harness.fileSystem.crashed)
        return (harness.fileSystem.survivingDisk(), QuarantineFixture.entry, QuarantineFixture.key)
    }

    /// The load rule over the index files of `disk`.
    static func loadRule(_ disk: DiskImage) -> IndexLoadOutcome {
        IndexLoadRule.choose(
            Dictionary(uniqueKeysWithValues: IndexFile.allCases.compactMap { file -> (IndexFile, IndexFileRead)? in
                disk.files[CoreFixture.layout.indexURL(file).path].map { (file, IndexFileRead(size: Int64($0.count), bytes: $0)) }
            })
        )
    }

    /// Whether `blobState` is a doom for `reason`.
    static func isDoomed(_ blobState: BlobState?, _ reason: DoomReason) -> Bool {
        if case .doomed(let info)? = blobState {
            return info.reason == reason
        }
        return false
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
