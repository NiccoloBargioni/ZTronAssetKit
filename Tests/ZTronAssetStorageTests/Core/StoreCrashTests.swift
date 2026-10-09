import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// The scripted first sync of R-STO-5: open → apply → four publications (a resumable pair with its sidecar, two
/// identifiers sharing one transfer, a checksum-less entry committed before it returns, a dedupe onto a live blob)
/// → the coalesced commit → a durable flush → close.
@available(macOS 15.0, *)
enum FirstSync {
    struct Asset {
        let entries: [ManifestEntry]
        let bytes: Data
        let sidecar: Bool
    }

    static let assets: [Asset] = {
        let a = CoreFixture.bytes(900, count: 700)
        let b = CoreFixture.bytes(901, count: 650)
        let c = CoreFixture.bytes(902, count: 600)
        return [
            Asset(entries: [CoreFixture.entry("a", a)], bytes: a, sidecar: true),
            Asset(entries: [CoreFixture.entry("b1", b), CoreFixture.entry("b2", b, ext: "png")], bytes: b, sidecar: false),
            Asset(entries: [CoreFixture.entry("c", c, ext: "wav", checksum: false)], bytes: c, sidecar: false),
            Asset(entries: [CoreFixture.entry("d", a)], bytes: a, sidecar: false),
        ]
    }()

    static let manifest = CoreFixture.manifest(FirstSync.assets.flatMap(\.entries))

    /// What the run achieved before it stopped.
    struct Trace {
        /// Ids whose publication returned.
        var returned: Set<AssetID> = []
        /// Ids whose publication returned before a commit that returned.
        var committed: Set<AssetID> = []
        /// The newest generation whose commit returned.
        var generation: UInt64 = 0
    }

    /// Runs the scenario until it completes or the fake crashes.
    static func run(_ harness: CoreHarness) async -> Trace {
        var trace = Trace()
        do {
            let store = harness.store
            _ = try await store.open()
            trace.generation = try await store.apply(FirstSync.manifest, etag: ETag(rawValue: "\"v1\""), eviction: nil).generation
            for (index, asset) in FirstSync.assets.enumerated() {
                let staged = try await harness.stage(asset.bytes, for: asset.entries[0], sequence: UInt32(index + 1), sidecar: asset.sidecar)
                _ = try await store.publish(staged, binding: asset.entries.map(\.identifier), expecting: asset.entries[0].contentIdentity, urgency: .bulk)
                trace.returned.formUnion(asset.entries.map(\.identifier))
                if asset.entries[0].checksum == nil {
                    trace.committed.formUnion(asset.entries.map(\.identifier))
                }
            }
            if await store.runDueWork().committed {
                trace.committed = trace.returned
                trace.generation = await store.state.core.committedGeneration
            }
            try await store.flush(.durable)
            trace.committed = trace.returned
            trace.generation = await store.state.core.committedGeneration
            await store.close()
        } catch {
            // The crash: every call after it fails.
        }
        return trace
    }

    /// Reopens `disk`, checks the invariants, completes the sync and returns what had to be downloaded again.
    static func reopenAndConverge(_ disk: DiskImage, after trace: Trace, mode: CrashMode, label: String) async -> Set<AssetID> {
        let harness = CoreHarness.make(disk: disk)
        let headers = [IndexFile.current, .previous, .temporary].compactMap { disk.files[CoreFixture.layout.indexURL($0).path].flatMap(IndexHeader.parse) }
        do {
            let report = try await harness.store.open()
            let loaded = await harness.state.core.committedGeneration
            #expect(loaded >= trace.generation, "\(label): I-5, generation \(loaded) < returned \(trace.generation)")
            #expect(headers.allSatisfy { report.launchEpoch > $0.generation }, "\(label): I-5, epoch \(report.launchEpoch) reuses a generation")
            let violations = await CoreInvariants.violations(of: harness)
            #expect(violations.isEmpty, "\(label): \(violations)")
            _ = try await harness.store.apply(FirstSync.manifest, etag: nil, eviction: nil)
            var downloaded: Set<AssetID> = []
            for (index, asset) in FirstSync.assets.enumerated() {
                var missing: [AssetID] = []
                for entry in asset.entries where await harness.store.location(for: entry.identifier, extensions: [], recordingAccess: false) == nil {
                    missing.append(entry.identifier)
                }
                guard !missing.isEmpty else {
                    continue
                }
                let entry = asset.entries.first { missing.contains($0.identifier) }!
                let staged = try await harness.stage(asset.bytes, for: entry, sequence: UInt32(100 + index))
                _ = try await harness.store.publish(staged, binding: missing, expecting: entry.contentIdentity, urgency: .bulk)
                downloaded.formUnion(missing)
            }
            _ = await harness.store.runDueWork()
            try await harness.store.flush(.durable)
            for asset in FirstSync.assets {
                for entry in asset.entries {
                    let location = await harness.store.location(for: entry.identifier, extensions: [], recordingAccess: false)
                    #expect(location.flatMap { harness.content($0.url) } == asset.bytes, "\(label): \(entry.identifier.rawValue) did not converge")
                }
            }
            let after = await CoreInvariants.violations(of: harness)
            #expect(after.isEmpty, "\(label) after convergence: \(after)")
            // I-3: the convergence prunes nothing and lets no grace pass, so no blob a reader may hold is unlinked.
            let unlinked = CoreInvariants.blobRemovals(harness.fileSystem.operations, layout: harness.layout)
            #expect(unlinked.isEmpty, "\(label) after convergence: \(unlinked)")
            await harness.store.close()
            return downloaded
        } catch {
            Issue.record("\(label): reopen or convergence failed with \(error)")
            return []
        }
    }
}

@Suite("Core: crash consistency (R-STO-5)")
struct StoreCrashTests {
    @Test(
        "R-STO-5: crash at every file-system boundary during a first sync preserves I-1…I-5",
        .timeLimit(.minutes(1)),
        arguments: CrashMode.allCases
    )
    @available(macOS 15.0, *)
    func crashAtEveryBoundary(mode: CrashMode) async throws {
        let clean = CoreHarness.make()
        let cleanTrace = await FirstSync.run(clean)
        #expect(cleanTrace.returned.count == 5 && cleanTrace.committed == cleanTrace.returned)
        #expect(CoreInvariants.blobRemovals(clean.fileSystem.operations, layout: clean.layout).isEmpty)
        let total = clean.fileSystem.mutationCount
        let cleanOps = clean.fileSystem.operations.filter(\.kind.isMutation)
        #expect(total > 40)
        var crashes = 0
        for point in 0..<total {
            let harness = CoreHarness.make(crashBefore: point, mode: mode)
            let trace = await FirstSync.run(harness)
            guard harness.fileSystem.crashed else {
                Issue.record("\(mode) at \(point): the crash point was never reached")
                continue
            }
            crashes += 1
            // I-3 in the crashed lifetime: nothing it handed out was unlinked.
            #expect(CoreInvariants.blobRemovals(harness.fileSystem.operations, layout: harness.layout).isEmpty, "\(mode) at \(point)")
            // The crash run performs the clean run's operations, in the same order, up to the crash (store-2 S2-08).
            let ran = harness.fileSystem.operations.filter(\.kind.isMutation).prefix(point)
            #expect(Array(ran).map { "\($0.kind) \($0.url.path)" } == cleanOps.prefix(point).map { "\($0.kind) \($0.url.path)" }, "\(mode) at \(point)")
            let downloaded = await FirstSync.reopenAndConverge(harness.fileSystem.survivingDisk(), after: trace, mode: mode, label: "\(mode) at \(point)")
            let protected = mode == .processKill || mode == .processKillTornWrite ? trace.returned : trace.committed
            #expect(downloaded.isDisjoint(with: protected), "\(mode) at \(point): re-downloaded \(downloaded.intersection(protected))")
        }
        #expect(crashes == total)
        print("R-STO-5 \(mode): \(total) crash points enumerated")
    }

    /// The pairs are enumerated in full; the work is split by power-loss mode and by kill point modulo
    /// `StoreCrashTests.slices`, so every test case stays far inside its time limit, sanitizers included.
    @Test(
        "R-STO-5: a process kill followed by a power loss in the next lifetime preserves I-1…I-5",
        .timeLimit(.minutes(1)),
        arguments: [CrashMode.powerLossDropUnsynced, .powerLossKeepMetadata], 0..<StoreCrashTests.slices
    )
    @available(macOS 15.0, *)
    func killThenPowerLoss(mode: CrashMode, slice: Int) async throws {
        let clean = CoreHarness.make()
        _ = await FirstSync.run(clean)
        let total = clean.fileSystem.mutationCount
        var pairs = 0
        for point in stride(from: slice, to: total, by: StoreCrashTests.slices) {
            let first = CoreHarness.make(crashBefore: point, mode: .processKill)
            let trace = await FirstSync.run(first)
            let killed = first.fileSystem.survivingDisk()
            // Lifetime 2 opens on the killed process's volatile namespace, re-applies and flushes; it loses power at
            // every one of its boundaries, and after its last one.
            let probe = CoreHarness.make(disk: killed)
            await StoreCrashTests.secondLifetime(probe)
            let secondTotal = probe.fileSystem.mutationCount
            for secondPoint in 0...secondTotal {
                let second = CoreHarness.make(disk: killed, crashBefore: secondPoint < secondTotal ? secondPoint : nil, mode: mode)
                await StoreCrashTests.secondLifetime(second)
                let label = "kill at \(point), \(mode) at \(secondPoint)"
                #expect(CoreInvariants.blobRemovals(second.fileSystem.operations, layout: second.layout).isEmpty, "\(label)")
                // What a commit of the first lifetime covered survives the second lifetime's power loss.
                let downloaded = await FirstSync.reopenAndConverge(second.fileSystem.survivingDisk(), after: FirstSync.Trace(), mode: mode, label: label)
                #expect(downloaded.isDisjoint(with: trace.committed), "\(label): \(downloaded)")
                pairs += 1
            }
        }
        print("R-STO-5 kill→power-loss pairs, \(mode), slice \(slice): \(pairs)")
        #expect(pairs >= total / StoreCrashTests.slices)
    }

    /// How many slices the pair enumeration is split into.
    static let slices = 4

    /// A fault injected at one commit step of the first sync (SPEC §7.3 "EIO on rename", "ENOSPC"; review round 3,
    /// probe 1).
    enum CommitFault: String, CaseIterable, Sendable {
        /// EIO on step 5, `index.tmp → index.bin` (the unit rolls step 4 back).
        case renameTemporary
        /// EIO on step 4, `index.bin → index.prev`.
        case renameCurrent
        /// EIO on step 6, the root's sync after both renames.
        case syncRoot
        /// ENOSPC on step 2, the write of `index.tmp` (the fallback's retry fails too).
        case writeTemporary

        /// The rules that make the `occurrence`-th matching operation of one commit fail.
        func rules(occurrence: Int) -> [FaultRule] {
            switch self {
            case .renameTemporary:
                return [FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth(occurrence), error: .io)]
            case .renameCurrent:
                return [FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: "index.bin"), occurrence: .nth(occurrence), error: .io)]
            case .syncRoot:
                return [FaultRule(operation: .synchronizeDirectory, matching: URLMatcher(lastComponentSuffix: "v1"), occurrence: .nth(occurrence), error: .io)]
            case .writeTemporary:
                // Every earlier attempt wrote once, so attempt n writes the n-th time; its fallback's retry is the next
                // write: fail both.
                return [occurrence, occurrence + 1].map {
                    FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .nth($0), error: .noSpace)
                }
            }
        }

        /// How many operations of the clean first sync a rule of this fault can match (one per commit attempt).
        func occurrences(in operations: [FSOpRecord]) -> Int {
            switch self {
            case .renameTemporary:
                return operations.filter { $0.kind == .rename && $0.url.lastPathComponent == "index.tmp" }.count
            case .renameCurrent:
                return operations.filter { $0.kind == .rename && $0.url.lastPathComponent == "index.bin" }.count
            case .syncRoot:
                return operations.filter { $0.kind == .synchronizeDirectory && $0.url == CoreFixture.layout.root }.count
            case .writeTemporary:
                return operations.filter { $0.kind == .write && $0.url.lastPathComponent == "index.tmp" }.count
            }
        }
    }

    /// How the full-volume lifetime of the enumerations below ends: killed (the volatile state survives), or by a power
    /// loss that drops what it never synced (review close-out, probe VP7: an unsynced generation promoted at launch
    /// was lost only once the power failed). Both enumerations run their cases one at a time (`.serialized`, close-out
    /// cycle 3): run side by side with everything else, each case took about a third of its time limit under TSan.
    static let fullVolumeEnds: [CrashMode] = [.processKill, .powerLossDropUnsynced, .powerLossKeepMetadata]

    @Test(
        "R-STO-5: a fault at every commit step, a kill, then a launch on a full volume that ends in a kill or a power loss preserve I-1…I-5",
        .timeLimit(.minutes(1)),
        .serialized,
        arguments: CommitFault.allCases, StoreCrashTests.fullVolumeEnds
    )
    @available(macOS 15.0, *)
    func faultAtEveryCommitThenFullVolume(fault: CommitFault, end: CrashMode) async throws {
        let clean = CoreHarness.make()
        _ = await FirstSync.run(clean)
        let occurrences = fault.occurrences(in: clean.fileSystem.operations)
        // Five commits (launch, apply, the checksum-less publication, the coalesced one, the durable flush); the first
        // finds no index.bin to rename.
        #expect(occurrences >= (fault == .renameCurrent ? 4 : 5), "every commit of the first sync is a fault point")
        for occurrence in 1...occurrences {
            let harness = CoreHarness.make()
            let rules = fault.rules(occurrence: occurrence)
            for rule in rules {
                harness.fileSystem.addFault(rule)
            }
            let trace = await FirstSync.run(harness)
            let label = "\(fault) at commit \(occurrence), full volume ending in \(end)"
            let fired = harness.fileSystem.operations.contains { operation in
                rules.contains { $0.operation == operation.kind && $0.matching.matches(operation.url) && $0.error == operation.failure }
            }
            #expect(fired, "\(label): the fault never fired")
            // The process is killed right after; the next launch finds the volume full.
            let disk = await StoreCrashTests.fullVolumeLifetime(harness.fileSystem.survivingDisk(), endingIn: end, label: label)
            #expect((StoreRecoveryTests.loadRule(disk).content?.generation ?? 0) >= trace.generation, "\(label): I-5, a committed generation was lost")
            let downloaded = await FirstSync.reopenAndConverge(disk, after: trace, mode: .processKill, label: label)
            // A power loss keeps only what a returned commit covered.
            let protected = end == .processKill ? trace.returned : trace.committed
            #expect(downloaded.isDisjoint(with: protected), "\(label): re-downloaded \(downloaded.intersection(protected))")
        }
        print("R-STO-5 \(fault), full volume ending in \(end): \(occurrences) commit fault points enumerated")
    }

    @Test(
        "R-STO-5: crash at every boundary, then a launch on a full volume that ends in a kill or a power loss, preserves I-1…I-5",
        .timeLimit(.minutes(1)),
        .serialized,
        arguments: CrashMode.allCases, StoreCrashTests.fullVolumeEnds
    )
    @available(macOS 15.0, *)
    func crashThenFullVolume(mode: CrashMode, end: CrashMode) async throws {
        let clean = CoreHarness.make()
        _ = await FirstSync.run(clean)
        let total = clean.fileSystem.mutationCount
        for point in 0..<total {
            let harness = CoreHarness.make(crashBefore: point, mode: mode)
            let trace = await FirstSync.run(harness)
            let label = "\(mode) at \(point), then a full volume ending in \(end)"
            let disk = await StoreCrashTests.fullVolumeLifetime(harness.fileSystem.survivingDisk(), endingIn: end, label: label)
            let downloaded = await FirstSync.reopenAndConverge(disk, after: trace, mode: mode, label: label)
            let killedOnly = (mode == .processKill || mode == .processKillTornWrite) && end == .processKill
            let protected = killedOnly ? trace.returned : trace.committed
            #expect(downloaded.isDisjoint(with: protected), "\(label): re-downloaded \(downloaded.intersection(protected))")
        }
        print("R-STO-5 \(mode) then a full volume ending in \(end): \(total) crash points enumerated")
    }

    /// A lifetime on a full volume (every write of `index.tmp` fails with ENOSPC): open, then close, then `end` (a kill,
    /// or a power loss right after `close()` returned). It must unlink no blob, and never leave the disk with fewer
    /// valid generations than the same `end` would have left had it struck before the lifetime did anything: whatever
    /// the launch loaded and promoted, it must not make the last durable generation depend on unsynced data (review
    /// close-out, probe VP7).
    @available(macOS 15.0, *)
    static func fullVolumeLifetime(_ disk: DiskImage, endingIn end: CrashMode = .processKill, label: String) async -> DiskImage {
        let before = StoreRecoveryTests.loadRule(CoreHarness.make(disk: disk, mode: end).fileSystem.survivingDisk())
        let harness = CoreHarness.make(disk: disk, mode: end)
        harness.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .every, error: .noSpace))
        do {
            _ = try await harness.store.open()
            let violations = await CoreInvariants.violations(of: harness)
            #expect(violations.isEmpty, "\(label), full-volume launch: \(violations)")
        } catch {
            Issue.record("\(label): the full-volume launch failed with \(error)")
        }
        await harness.store.close()
        #expect(CoreInvariants.blobRemovals(harness.fileSystem.operations, layout: harness.layout).isEmpty, "\(label), full-volume launch")
        let after = harness.fileSystem.survivingDisk()
        let left = StoreRecoveryTests.loadRule(after)
        #expect((left.content?.generation ?? 0) >= (before.content?.generation ?? 0), "\(label): the full-volume launch lost generation \(before.content?.generation ?? 0)")
        // A power loss may resurrect an index file that held no valid generation (a torn first `index.tmp`, whose
        // name `open()`'s root sync made durable while its data never was): degraded then loses nothing, because
        // nothing valid was there; wherever a valid generation was, it must still load.
        let nothingValidToLose = end != .processKill && before.content == nil
        #expect(!left.degraded || before.degraded || nothingValidToLose, "\(label): the full-volume launch left no valid index")
        return after
    }

    /// Review close-out, probe VP7: the load rule accepts a complete `index.tmp` that a killed process wrote at commit
    /// step 2 and never synced (step 3). The launch promoted it by renaming it to `index.bin` without syncing its data,
    /// then counted its generation as committed; on a full volume the fallback removed `index.prev`, the last synced
    /// generation, and a power loss left no valid index: the epoch restarted at 1, the record was lost, and the
    /// `corrupt`-doomed name was re-adopted and served.
    @Test(
        "R-STO-5: a launch that promotes an index.tmp written but never synced before a kill keeps a valid generation through a full volume and a power loss",
        .timeLimit(.minutes(1)),
        arguments: [CrashMode.powerLossKeepMetadata, .powerLossDropUnsynced]
    )
    @available(macOS 15.0, *)
    func promotedUnsyncedTemporarySurvivesPowerLoss(mode: CrashMode) async throws {
        // Lifetime 1: a durable commit dooms the rotten blob `corrupt`; the next commit is killed right before it syncs
        // index.tmp.
        let (killed, entry, key) = try await StoreRecoveryTests.killedInLastCommit {
            $0.kind == .synchronizeFile && $0.url.lastPathComponent == "index.tmp"
        }
        let loaded = StoreRecoveryTests.loadRule(killed)
        #expect(loaded.chosen == .temporary, "the killed commit's generation is only in the unsynced index.tmp")
        let lastDurable = try #require(StoreRecoveryTests.loadRule(CoreHarness.make(disk: killed, mode: mode).fileSystem.survivingDisk()).content?.generation)
        #expect((loaded.content?.generation ?? 0) > lastDurable)
        // Lifetime 2: the volume is full (every write of index.tmp fails); open, close, then the power fails.
        let second = CoreHarness.make(disk: killed, mode: mode)
        second.fileSystem.addFault(FaultRule(operation: .write, matching: URLMatcher(lastComponentSuffix: "index.tmp"), occurrence: .every, error: .noSpace))
        let report = try await second.store.open()
        #expect(!report.degraded)
        #expect(report.generation == loaded.content?.generation, "the loaded index.tmp was promoted before any write")
        await second.store.close()
        #expect(CoreInvariants.blobRemovals(second.fileSystem.operations, layout: second.layout).isEmpty)
        let afterPowerLoss = second.fileSystem.survivingDisk()
        let left = StoreRecoveryTests.loadRule(afterPowerLoss)
        #expect(!left.degraded, "\(mode): a valid index.bin is left after the power loss")
        #expect((left.content?.generation ?? 0) >= lastDurable, "\(mode): the last durable generation was lost")
        // Lifetime 3: space is back.
        let headers = IndexFile.allCases.compactMap { afterPowerLoss.files[CoreFixture.layout.indexURL($0).path].flatMap(IndexHeader.parse) }
        let third = CoreHarness.make(disk: afterPowerLoss)
        let thirdReport = try await third.store.open()
        #expect(!thirdReport.degraded)
        #expect(thirdReport.launchEpoch > lastDurable, "I-5: the launch epoch \(thirdReport.launchEpoch) restarts below generation \(lastDurable)")
        #expect(headers.allSatisfy { thirdReport.launchEpoch > $0.generation }, "I-5: the launch epoch reuses a generation")
        #expect(await third.state.core.records[entry.identifier] != nil, "the quarantined record survived")
        _ = try await third.store.apply(CoreFixture.manifest([entry]), etag: nil, eviction: nil)
        #expect(await third.store.location(for: entry.identifier, extensions: [], recordingAccess: false) == nil, "the corrupt name is never re-adopted (§4.4)")
        #expect(StoreRecoveryTests.isDoomed(await third.state.core.blobTable[key], .corrupt))
        #expect(await CoreInvariants.violations(of: third).isEmpty)
    }

    /// The second lifetime of the pair test: open (adoption, launch commit), re-apply, flush durably.
    @available(macOS 15.0, *)
    static func secondLifetime(_ harness: CoreHarness) async {
        do {
            _ = try await harness.store.open()
            _ = try await harness.store.apply(FirstSync.manifest, etag: nil, eviction: nil)
            try await harness.store.flush(.durable)
            await harness.store.close()
        } catch {
            // The power loss.
        }
    }

    @Test("R-STO-5: power loss after a durable commit keeps the store root reachable", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func powerLossAfterDurableCommit() async throws {
        for mode in [CrashMode.powerLossDropUnsynced, .powerLossKeepMetadata] {
            let harness = CoreHarness.make(mode: mode)
            let asset = FirstSync.assets[0]
            _ = try await harness.store.open()
            _ = try await harness.store.apply(FirstSync.manifest, etag: nil, eviction: nil)
            try await harness.publish(asset.bytes, asset.entries)
            try await harness.store.flush(.durable)
            let generation = await harness.state.core.committedGeneration
            // The power fails right after the durable flush returned: nothing else ran.
            let disk = harness.fileSystem.survivingDisk()
            #expect(disk.directories.contains(CoreFixture.layout.root.path), "\(mode): the root is reachable")
            let reopened = CoreHarness.make(disk: disk)
            _ = try await reopened.store.open()
            #expect(await reopened.state.core.committedGeneration >= generation)
            let location = await reopened.store.location(for: asset.entries[0].identifier, extensions: [], recordingAccess: false)
            #expect(location.flatMap { reopened.content($0.url) } == asset.bytes, "\(mode)")
            #expect(await CoreInvariants.violations(of: reopened).isEmpty)
        }
    }

    @Test("R-STO-5: blobs published before a rate-limited commit are adopted after a crash, never re-downloaded", .timeLimit(.minutes(1)))
    @available(macOS 15.0, *)
    func windowBlobsAreAdopted() async throws {
        let harness = CoreHarness.make(configuration: CoreFixture.configuration(commitInterval: 0.25))
        let assets = FirstSync.assets.filter { $0.entries[0].checksum != nil }
        _ = try await harness.store.open()
        // The apply right after the launch commit waits for the coalescing window.
        let applying = Task {
            try await harness.store.apply(FirstSync.manifest, etag: nil, eviction: nil)
        }
        try await harness.time.requireSleepers(atLeast: 1)
        harness.time.advance(by: 0.25)
        _ = try await applying.value
        for (index, asset) in assets.enumerated() {
            let staged = try await harness.stage(asset.bytes, for: asset.entries[0], sequence: UInt32(index + 1))
            _ = try await harness.store.publish(staged, binding: asset.entries.map(\.identifier), expecting: asset.entries[0].contentIdentity, urgency: .bulk)
        }
        // Killed inside the coalescing window: the publications are on disk, not in index.bin.
        let disk = harness.fileSystem.survivingDisk()
        let reopened = CoreHarness.make(disk: disk)
        let report = try await reopened.store.open()
        #expect(report.missingBlobs == 0)
        for asset in assets {
            for entry in asset.entries {
                #expect(await reopened.store.location(for: entry.identifier, extensions: [], recordingAccess: false) != nil, "\(entry.identifier.rawValue)")
            }
        }
        #expect(await CoreInvariants.violations(of: reopened).isEmpty)
        // Adoption dirtied the fan-outs: the launch commit barrier-synced them before writing the index (S1-01).
        let mutations = reopened.mutations
        let firstIndexWrite = try #require(mutations.firstIndex { $0.kind == .write && $0.url.lastPathComponent == "index.tmp" })
        for asset in assets {
            let fanOut = reopened.layout.fanOutDirectory(for: ContentHash.sha256(of: asset.bytes))
            let synced = mutations.firstIndex { $0.kind == .synchronizeDirectory && $0.url == fanOut }
            #expect(synced.map { $0 < firstIndexWrite } == true, "\(fanOut.lastPathComponent)")
        }
    }
}
