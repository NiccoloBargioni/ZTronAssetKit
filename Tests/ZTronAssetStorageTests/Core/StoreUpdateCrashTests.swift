import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// The scripted catalog updates of R-STO-5 (SPEC §7.3 "crash at every boundary during: … checksum-change update ·
/// directory change · removal"; Stage 3 S3-CONF-01, S3-CRAS-01). Every lifetime starts from a durably synced v1 catalog
/// {a, b, c, d} and applies one v2: a's content changes, b moves to another directory, c is removed, or all three at
/// once (d never changes). It publishes a's new bytes when they changed, commits, lets the deletion grace pass so the
/// reaper unlinks the blobs v2 dropped, flushes durably and closes.
@available(macOS 15.0, iOS 18.0, *)
enum CatalogUpdateRun {
    /// What v2 changes against v1.
    enum Scenario: String, CaseIterable, Sendable {
        /// a's checksum (and size) change: its old blob is released once the new bytes are bound.
        case checksumChange
        /// b's directory and file name change: same content, so the same blob.
        case directoryChange
        /// c leaves the manifest: its record is pruned and its blob reaped.
        case removal
        /// The three above in one apply.
        case allThree

        var changesA: Bool {
            self == .checksumChange || self == .allThree
        }

        var movesB: Bool {
            self == .directoryChange || self == .allThree
        }

        var removesC: Bool {
            self == .removal || self == .allThree
        }
    }

    static let oldA = CoreFixture.bytes(910, count: 500)
    static let newA = CoreFixture.bytes(911, count: 520)
    static let bBytes = CoreFixture.bytes(912, count: 480)
    static let cBytes = CoreFixture.bytes(913, count: 460)
    static let dBytes = CoreFixture.bytes(914, count: 440)

    static let v1: [ManifestEntry] = [
        CoreFixture.entry("a", CatalogUpdateRun.oldA),
        CoreFixture.entry("b", CatalogUpdateRun.bBytes),
        CoreFixture.entry("c", CatalogUpdateRun.cBytes),
        CoreFixture.entry("d", CatalogUpdateRun.dBytes),
    ]

    /// v2's entries for `scenario`, in v1's order.
    static func v2(_ scenario: Scenario) -> [ManifestEntry] {
        var entries: [ManifestEntry] = []
        entries.append(scenario.changesA ? CoreFixture.entry("a", CatalogUpdateRun.newA) : CatalogUpdateRun.v1[0])
        var b = CatalogUpdateRun.v1[1]
        if scenario.movesB {
            b.localPathComponents = ["moved", "deeper"]
            b.localFileName = "renamed"
        }
        entries.append(b)
        if !scenario.removesC {
            entries.append(CatalogUpdateRun.v1[2])
        }
        entries.append(CatalogUpdateRun.v1[3])
        return entries
    }

    /// The bytes each v2 id must serve once converged.
    static func expected(_ scenario: Scenario) -> [AssetID: Data] {
        var bytes: [AssetID: Data] = [
            AssetID("a"): scenario.changesA ? CatalogUpdateRun.newA : CatalogUpdateRun.oldA,
            AssetID("b"): CatalogUpdateRun.bBytes,
            AssetID("d"): CatalogUpdateRun.dBytes,
        ]
        if !scenario.removesC {
            bytes[AssetID("c")] = CatalogUpdateRun.cBytes
        }
        return bytes
    }

    /// The blobs the clean update unlinks: a's old blob and c's blob, as far as v2 drops them.
    static func reaped(_ scenario: Scenario) -> Set<String> {
        var keys: Set<String> = []
        if scenario.changesA {
            keys.insert(CoreFixture.key(CatalogUpdateRun.oldA).fileName)
        }
        if scenario.removesC {
            keys.insert(CoreFixture.key(CatalogUpdateRun.cBytes).fileName)
        }
        return keys
    }

    /// The durably committed v1 store every enumerated lifetime starts from.
    static func baseDisk() async throws -> DiskImage {
        let harness = CoreHarness.make()
        _ = try await harness.store.open()
        _ = try await harness.store.apply(CoreFixture.manifest(CatalogUpdateRun.v1, etagSeed: "v1"), etag: nil, eviction: nil)
        let payloads = [CatalogUpdateRun.oldA, CatalogUpdateRun.bBytes, CatalogUpdateRun.cBytes, CatalogUpdateRun.dBytes]
        for (index, entry) in CatalogUpdateRun.v1.enumerated() {
            try await harness.publish(payloads[index], [entry], sequence: UInt32(index + 1))
        }
        _ = await harness.store.runDueWork()
        try await harness.store.flush(.durable)
        await harness.store.close()
        return harness.fileSystem.survivingDisk()
    }

    /// Drives the deletion protocol to its end: the install that drops the doomed keys (acknowledged), the awake-clock
    /// grace, then the fresh install and the reap of `runDueWork()` (§4.4).
    static func settle(_ harness: CoreHarness) async {
        _ = await harness.store.runDueWork()
        harness.time.advance(by: harness.configuration.policy.deletionGrace)
        _ = await harness.store.runDueWork()
    }

    /// What the run achieved before it stopped.
    struct Trace {
        /// a's new bytes were published (the call returned).
        var newAReturned = false
        /// A commit that returned covered a's new bytes.
        var newACommitted = false
        /// The newest generation whose commit returned.
        var generation: UInt64 = 0
        /// How many mutations ran before the deletion grace started to pass: no blob may be unlinked before.
        var graceStart: Int?
    }

    /// Runs the update until it completes or the fake crashes.
    static func run(_ harness: CoreHarness, _ scenario: Scenario) async -> Trace {
        var trace = Trace()
        let entries = CatalogUpdateRun.v2(scenario)
        do {
            _ = try await harness.store.open()
            let manifest = CoreFixture.manifest(entries, etagSeed: "v2")
            trace.generation = try await harness.store.apply(manifest, etag: ETag(rawValue: "\"v2\""), eviction: nil).generation
            if scenario.changesA {
                let staged = try await harness.stage(CatalogUpdateRun.newA, for: entries[0], sequence: 7)
                _ = try await harness.store.publish(staged, binding: [entries[0].identifier], expecting: entries[0].contentIdentity, urgency: .bulk)
                trace.newAReturned = true
                if await harness.store.runDueWork().committed {
                    trace.newACommitted = true
                    trace.generation = await harness.state.core.committedGeneration
                }
            }
            trace.graceStart = harness.fileSystem.mutationCount
            await CatalogUpdateRun.settle(harness)
            try await harness.store.flush(.durable)
            trace.newACommitted = trace.newAReturned
            trace.generation = await harness.state.core.committedGeneration
            await harness.store.close()
        } catch {
            // The crash: every later call fails.
        }
        return trace
    }

    /// Reopens `disk`, checks I-1…I-5 (I-3 through the relaunch's own reap), converges to v2 and returns the ids that
    /// had to be downloaded again.
    static func reopenAndConverge(_ disk: DiskImage, _ scenario: Scenario, after trace: Trace, label: String) async -> Set<AssetID> {
        let harness = CoreHarness.make(disk: disk)
        let headers = IndexFile.allCases.compactMap { disk.files[CoreFixture.layout.indexURL($0).path].flatMap(IndexHeader.parse) }
        let entries = CatalogUpdateRun.v2(scenario)
        let expected = CatalogUpdateRun.expected(scenario)
        do {
            let report = try await harness.store.open()
            let loaded = await harness.state.core.committedGeneration
            #expect(loaded >= trace.generation, "\(label): I-5, generation \(loaded) < returned \(trace.generation)")
            #expect(headers.allSatisfy { report.launchEpoch > $0.generation }, "\(label): I-5, epoch \(report.launchEpoch) reuses a generation")
            let violations = await CoreInvariants.violations(of: harness)
            #expect(violations.isEmpty, "\(label): \(violations)")
            // I-3 and I-2 across the relaunch: its reaper unlinks only what no record references.
            await CatalogUpdateRun.settle(harness)
            let afterReap = await CoreInvariants.violations(of: harness)
            #expect(afterReap.isEmpty, "\(label) after the relaunch's reap: \(afterReap)")
            _ = try await harness.store.apply(CoreFixture.manifest(entries, etagSeed: "v2"), etag: nil, eviction: nil)
            var downloaded: Set<AssetID> = []
            // A changed asset keeps serving its old bytes, stale, until its new content is published (R-INT-3).
            for entry in entries where await harness.store.location(for: entry.identifier, extensions: [], recordingAccess: false).map(\.isStale) ?? true {
                let bytes = try #require(expected[entry.identifier])
                try await harness.publish(bytes, [entry], sequence: 40)
                downloaded.insert(entry.identifier)
            }
            await CatalogUpdateRun.settle(harness)
            try await harness.store.flush(.durable)
            for entry in entries {
                let location = await harness.store.location(for: entry.identifier, extensions: [], recordingAccess: false)
                #expect(location.flatMap { harness.content($0.url) } == expected[entry.identifier], "\(label): \(entry.identifier.rawValue) did not converge")
                #expect(location?.isStale == false, "\(label): \(entry.identifier.rawValue) is still stale")
            }
            if scenario.removesC {
                #expect(await harness.store.location(for: AssetID("c"), extensions: [], recordingAccess: false) == nil, "\(label): the removed asset is still served")
            }
            let after = await CoreInvariants.violations(of: harness)
            #expect(after.isEmpty, "\(label) after convergence: \(after)")
            // R-CLN-1: once converged and past the grace, every blob on disk is referenced or a launch orphan left to
            // orphan GC (WP-C); nothing v2 dropped lingers in the blob table.
            let state = await harness.state
            let referenced = Set(state.core.records.values.compactMap(\.referencedBlob))
            let blobsPrefix = harness.layout.blobsDirectory.path + "/"
            for path in harness.fileSystem.survivingDisk().files.keys where path.hasPrefix(blobsPrefix) {
                guard let key = StoreLayout.parseBlobName(URL(fileURLWithPath: path).lastPathComponent) else {
                    continue
                }
                #expect(referenced.contains(key) || state.core.orphans[key] != nil, "\(label): \(key.fileName) lingers unreferenced")
            }
            await harness.store.close()
            return downloaded
        } catch {
            Issue.record("\(label): reopen or convergence failed with \(error)")
            return []
        }
    }
}

/// Every case gives its cooperative thread back once per crash point (`await Task.yield()`, ADR draft `ios.md` item 8),
/// as `StoreCrashTests` does.
@Suite("Core: crash consistency of a catalog update (R-STO-5)")
struct StoreUpdateCrashTests {
    @Test(
        "R-STO-5: crash at every file-system boundary during a checksum-change update, a directory change and a removal preserves I-1…I-5",
        .timeLimit(.minutes(1)),
        arguments: CatalogUpdateRun.Scenario.allCases, CrashMode.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func crashAtEveryBoundaryOfAnUpdate(scenario: CatalogUpdateRun.Scenario, mode: CrashMode) async throws {
        let base = try await CatalogUpdateRun.baseDisk()
        let clean = CoreHarness.make(disk: base)
        let cleanTrace = await CatalogUpdateRun.run(clean, scenario)
        #expect(cleanTrace.newACommitted == scenario.changesA)
        let cleanUnlinked = Set(CoreInvariants.blobRemovals(clean.fileSystem.operations, layout: clean.layout))
        #expect(cleanUnlinked == Set(CatalogUpdateRun.reaped(scenario).map { "I-3: \($0) was unlinked" }), "the clean run reaps what v2 dropped")
        let total = clean.fileSystem.mutationCount
        let cleanOps = clean.fileSystem.operations.filter(\.kind.isMutation)
        #expect(total > 10)
        var crashes = 0
        for point in 0..<total {
            await Task.yield()
            let label = "\(scenario), \(mode) at \(point)"
            let harness = CoreHarness.make(disk: base, crashBefore: point, mode: mode)
            let trace = await CatalogUpdateRun.run(harness, scenario)
            guard harness.fileSystem.crashed else {
                Issue.record("\(label): the crash point was never reached")
                continue
            }
            crashes += 1
            let mutations = harness.fileSystem.operations.filter(\.kind.isMutation)
            // The crash run performs the clean run's operations, in the same order, up to the crash (store-2 S2-08).
            #expect(mutations.prefix(point).map { "\($0.kind) \($0.url.path)" } == cleanOps.prefix(point).map { "\($0.kind) \($0.url.path)" }, "\(label)")
            // I-3 in the crashed lifetime: no blob is unlinked before the grace started to pass, and nothing the
            // readers' installed snapshot hands out is gone from the killed process's namespace.
            let early = CoreInvariants.blobRemovals(Array(mutations.prefix(trace.graceStart ?? mutations.count)), layout: harness.layout)
            #expect(early.isEmpty, "\(label): \(early)")
            let disk = harness.fileSystem.survivingDisk()
            if mode == .processKill || mode == .processKillTornWrite {
                let installed = await harness.sink.installed
                for entry in CatalogUpdateRun.v1 {
                    if let location = installed.location(for: entry.identifier, extensions: []) {
                        #expect(disk.files[location.url.path] != nil, "\(label): I-3, the installed snapshot hands out \(location.url.lastPathComponent), which is gone")
                    }
                }
            }
            let downloaded = await CatalogUpdateRun.reopenAndConverge(disk, scenario, after: trace, label: label)
            // Content that did not change never costs a download (a move included); a's new bytes do not either once
            // the killed process published them, or once a commit covered them before a power loss.
            var protected: Set<AssetID> = Set(CatalogUpdateRun.v2(scenario).map(\.identifier))
            if scenario.changesA {
                let kept = mode == .processKill || mode == .processKillTornWrite ? trace.newAReturned : trace.newACommitted
                if !kept {
                    protected.remove(AssetID("a"))
                }
            }
            #expect(downloaded.isDisjoint(with: protected), "\(label): re-downloaded \(downloaded.intersection(protected))")
        }
        #expect(crashes == total)
        print("R-STO-5 update \(scenario), \(mode): \(total) crash points enumerated")
    }
}
