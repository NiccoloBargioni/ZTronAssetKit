import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// The model-based test of SPEC §7.3 (store.md §9.3): seeded random sequences of store, relocate, remove, evict, reap,
/// crash and reopen steps, checked after every step against a trivial in-memory oracle and against I-1…I-5. The reap
/// step drives the deletion protocol to its end (`runDueWork()`, the grace, `runDueWork()` again), so blobs are really
/// unlinked and I-3 is audited at every unlink (`CleanupAuditSink`: not held by the readers' snapshot, after an
/// acknowledged snapshot without it and its grace); a quarter of the lifetimes run with a sink that acknowledges nothing,
/// where no blob may be unlinked at all (Stage 3 ruling S3C-6, S3-CRAS-02).
@Suite("Cleanup: model-based oracle (R-STO-5)")
struct OracleTests {
    /// SplitMix64: a seeded generator, so a failing sequence is reproduced from the seed it prints.
    struct Generator {
        var state: UInt64

        mutating func next() -> UInt64 {
            self.state &+= 0x9E37_79B9_7F4A_7C15
            var z = self.state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func below(_ bound: Int) -> Int {
            Int(self.next() % UInt64(max(1, bound)))
        }
    }

    /// The oracle: what the store must show for each id.
    struct Model: Equatable, CustomStringConvertible {
        struct Asset: Equatable {
            var version: Int
            var directory: Int
            var present: Bool
            /// Evicted: absent, but its blob is adoptable again by hash (ADR-018), so a power loss that brings back the
            /// unsynced unlink lets the next launch or `apply` bind it again; either is correct.
            var evicted = false
        }

        /// Ids in the applied manifest.
        var assets: [String: Asset] = [:]

        var description: String {
            self.assets.keys.sorted().map { id in
                let asset = self.assets[id]!
                return "\(id)@v\(asset.version)/d\(asset.directory)\(asset.present ? "+" : asset.evicted ? "~" : "-")"
            }.joined(separator: " ")
        }

        /// Whether `observed` shows exactly this oracle (the eviction flag is the oracle's own bookkeeping).
        func shows(_ observed: Model) -> Bool {
            Set(self.assets.keys) == Set(observed.assets.keys) && self.assets.allSatisfy { id, asset in
                let seen = observed.assets[id]!
                return seen.version == asset.version && seen.directory == asset.directory && seen.present == asset.present
            }
        }

        /// After a crash: the oracle `observed` is consistent with, or `nil`: equal, except that an evicted asset may be
        /// present again (its unsynced unlink was lost, so its blob is adopted again).
        func matching(_ observed: Model) -> Model? {
            guard Set(self.assets.keys) == Set(observed.assets.keys) else {
                return nil
            }
            var matched = self
            for (id, asset) in self.assets {
                let seen = observed.assets[id]!
                guard seen.version == asset.version, seen.directory == asset.directory else {
                    return nil
                }
                if seen.present != asset.present {
                    guard asset.evicted, seen.present else {
                        return nil
                    }
                    matched.assets[id] = Asset(version: asset.version, directory: asset.directory, present: true)
                }
            }
            return matched
        }
    }

    static let ids = (0..<5).map { "m\($0)" }

    /// The bytes of `id` at `version` (unique per pair, so no two versions share a blob).
    static func bytes(_ id: String, _ version: Int) -> Data {
        CoreFixture.bytes(UInt64((Int(id.dropFirst()) ?? 0) * 1_000 + version), count: 64 + version % 7)
    }

    static func entry(_ id: String, _ asset: Model.Asset) -> ManifestEntry {
        var entry = CoreFixture.entry(id, OracleTests.bytes(id, asset.version))
        entry.localPathComponents = ["dir\(asset.directory)"]
        return entry
    }

    static func manifest(_ model: Model) -> ValidatedManifest {
        CoreFixture.manifest(model.assets.keys.sorted().map { OracleTests.entry($0, model.assets[$0]!) })
    }

    /// What the store shows, as the oracle's shape.
    @available(macOS 15.0, iOS 18.0, *)
    static func observe(_ harness: CoreHarness, versions: [String: [ContentHash: Int]]) async -> Model {
        var model = Model()
        let state = await harness.state
        for entry in state.core.appliedManifest.entries {
            let id = entry.identifier.rawValue
            guard let checksum = entry.checksum, let version = versions[id]?[checksum], let record = state.core.records[entry.identifier] else {
                model.assets[id] = Model.Asset(version: -1, directory: -1, present: false)
                continue
            }
            let directory = Int(entry.localPathComponents.first?.dropFirst(3) ?? "") ?? -1
            var present = false
            if let blob = record.referencedBlob, !record.isStale {
                present = harness.content(harness.layout.blobURL(blob)) == OracleTests.bytes(id, version)
            }
            model.assets[id] = Model.Asset(version: version, directory: directory, present: present)
        }
        return model
    }

    enum Step: CustomStringConvertible {
        case add(String)
        case change(String)
        case publish(String)
        case relocate(String)
        case remove(String)
        case evict(String)
        case reap
        case reopen

        var description: String {
            switch self {
            case .add(let id): return "add \(id)"
            case .change(let id): return "change \(id)"
            case .publish(let id): return "publish \(id)"
            case .relocate(let id): return "relocate \(id)"
            case .remove(let id): return "remove \(id)"
            case .evict(let id): return "evict \(id)"
            case .reap: return "reap"
            case .reopen: return "reopen"
            }
        }
    }

    /// A random step that is valid in `model`; one in four is a reap.
    static func step(_ model: Model, _ random: inout Generator) -> Step {
        if random.below(4) == 0 {
            return .reap
        }
        let id = OracleTests.ids[random.below(OracleTests.ids.count)]
        guard let asset = model.assets[id] else {
            return random.below(6) == 0 ? .reopen : .add(id)
        }
        switch random.below(12) {
        case 0, 1:
            return .change(id)
        case 2, 3, 4, 5:
            return asset.present ? .evict(id) : .publish(id)
        case 6:
            return .relocate(id)
        case 7:
            return .remove(id)
        case 8:
            return .reopen
        default:
            return asset.present ? .relocate(id) : .publish(id)
        }
    }

    /// The oracle after `step`.
    static func apply(_ step: Step, to model: Model, nextVersion: inout Int) -> Model {
        var next = model
        switch step {
        case .add(let id), .change(let id):
            nextVersion += 1
            next.assets[id] = Model.Asset(version: nextVersion, directory: model.assets[id]?.directory ?? 0, present: false)
        case .publish(let id):
            next.assets[id]?.present = true
            next.assets[id]?.evicted = false
        case .relocate(let id):
            next.assets[id]?.directory += 1
        case .remove(let id):
            next.assets[id] = nil
        case .evict(let id):
            next.assets[id]?.present = false
            next.assets[id]?.evicted = true
        case .reap, .reopen:
            // A reap unlinks only doomed blobs; an evicted asset may still come back after a power loss that loses an
            // unsynced unlink, so `evicted` stays.
            break
        }
        return next
    }

    /// Runs `step` on the store, ending with the commit that makes it durable; throws when the fake crashed. Every move
    /// of the clock is reported to `audit`.
    @available(macOS 15.0, iOS 18.0, *)
    static func run(_ step: Step, _ harness: CoreHarness, audit: CleanupAuditSink, target: Model, sequence: inout UInt32) async throws {
        switch step {
        case .add, .change, .relocate, .remove:
            _ = try await harness.store.apply(OracleTests.manifest(target), etag: nil, eviction: nil)
        case .publish(let id):
            let asset = try #require(target.assets[id])
            sequence += 1
            try await harness.publish(OracleTests.bytes(id, asset.version), [OracleTests.entry(id, asset)], urgency: .bulk, sequence: sequence)
            try await harness.store.flush(.ordered)
        case .evict(let id):
            // Every asset is older than the residency window; everything but `id` is protected.
            harness.time.advance(by: 60)
            await audit.clockMoved()
            let others = Set(target.assets.keys.filter { $0 != id }.map { AssetID($0) })
            let plan = try #require(await harness.store.evictionPlan(toFree: 1, protecting: others))
            #expect(plan.victims.map(\.id) == [AssetID(id)])
            _ = try await harness.store.apply(OracleTests.manifest(target), etag: nil, eviction: plan)
            // Not reaped here: the later steps run `apply` within the deletion grace, which must not adopt the evicted
            // record again (OI-1, ruling R3 at the L3 close-out); the doomed blob waits for a reap step or a relaunch.
            try await harness.store.flush(.ordered)
        case .reap:
            // Everything doomed whose snapshot was acknowledged goes once the grace passed (and nothing, when the sink
            // acknowledges nothing).
            await harness.settleDeletions(audited: audit)
        case .reopen:
            break
        }
        if harness.fileSystem.crashed {
            throw StoreError.closed
        }
    }

    /// I-3 over the unlinks of `harness`'s lifetime so far.
    @available(macOS 15.0, iOS 18.0, *)
    static func expectI3(_ harness: CoreHarness, _ audit: CleanupAuditSink, _ label: String, _ history: [String]) async {
        let violations = await audit.violations(harness.fileSystem.operations, layout: harness.layout, grace: harness.configuration.policy.deletionGrace)
        #expect(violations.isEmpty, "\(label): after \(history): \(violations)")
    }

    @Test(
        "R-STO-5: seeded random store, relocate, remove, evict, reap, crash and reopen sequences match the oracle with I-1…I-5 after every step",
        .serialized,
        .timeLimit(.minutes(1)),
        arguments: Array(UInt64(1)...UInt64(16))
    )
    @available(macOS 15.0, iOS 18.0, *)
    func oracle(seed: UInt64) async throws {
        var random = Generator(state: seed)
        var model = Model()
        var nextVersion = 0
        var versions: [String: [ContentHash: Int]] = [:]
        var disk = DiskImage()
        let time = ManualTimeSource()
        var sequence: UInt32 = 0
        var steps = 0
        var history: [String] = []
        var lifetimes = 0
        var unlinks = 0
        lifetimes: while steps < 40, lifetimes < 200 {
            lifetimes += 1
            // Each lifetime may crash before a random mutation, in a random mode.
            let crashBefore = random.below(2) == 0 ? 8 + random.below(60) : nil
            // A lifetime without a crash ends with a clean close (a kill keeps everything); one with a crash may lose
            // whatever was not synced.
            let drawn = CrashMode.allCases[random.below(CrashMode.allCases.count)]
            let mode = crashBefore == nil ? CrashMode.processKill : drawn
            // One lifetime in four installs into a sink that acknowledges nothing: no blob may be unlinked in it.
            let acknowledging = random.below(4) != 0
            let (harness, audit) = CoreHarness.audited(disk: disk, crashBefore: crashBefore, mode: mode, time: time, acknowledging: acknowledging)
            let label = "seed \(seed), lifetime crash \(String(describing: crashBefore)) \(mode)\(acknowledging ? "" : ", unacknowledged")"
            do {
                let report = try await harness.store.open()
                let headers = IndexFile.allCases.compactMap { disk.files[harness.layout.indexURL($0).path].flatMap(IndexHeader.parse) }
                #expect(headers.allSatisfy { report.launchEpoch > $0.generation }, "\(label): I-5 epoch, after \(history)")
                // Launch adoption binds an evicted record whose doomed blob is still on disk (ADR-018): an evicted asset
                // may be present again after any relaunch, never after an `apply` (OI-1). A fake that crashed inside
                // open() (a tolerated launch-commit failure) is reconciled by the first step, which then fails.
                if !harness.fileSystem.crashed {
                    let observed = await OracleTests.observe(harness, versions: versions)
                    if let match = model.matching(observed) {
                        model = match
                    } else {
                        Issue.record("\(label): after the relaunch in \(history): store \(observed) ≠ oracle \(model)")
                        return
                    }
                }
            } catch {
                // Crashed inside open(): nothing changed for the oracle.
                disk = harness.fileSystem.survivingDisk()
                continue lifetimes
            }
            while steps < 40 {
                await Task.yield()
                let step = OracleTests.step(model, &random)
                steps += 1
                history.append(step.description)
                let target = OracleTests.apply(step, to: model, nextVersion: &nextVersion)
                for (id, asset) in target.assets {
                    versions[id, default: [:]][ContentHash.sha256(of: OracleTests.bytes(id, asset.version))] = asset.version
                }
                if case .reopen = step {
                    await harness.store.close()
                    disk = harness.fileSystem.survivingDisk()
                    await OracleTests.expectI3(harness, audit, label, history)
                    unlinks += OracleTests.unlinks(harness)
                    if harness.fileSystem.crashed {
                        let committed = await harness.state.core.committedGeneration
                        disk = try await OracleTests.reconcile(disk, time: time, model: &model, candidates: [model], committed: committed, versions: versions, label: label, history: history)
                    }
                    continue lifetimes
                }
                do {
                    try await OracleTests.run(step, harness, audit: audit, target: target, sequence: &sequence)
                    let observed = await OracleTests.observe(harness, versions: versions)
                    #expect(target.shows(observed), "\(label): after \(history): store \(observed) ≠ oracle \(target)")
                    let violations = await CoreInvariants.violations(of: harness)
                    #expect(violations.isEmpty, "\(label): after \(history): \(violations)")
                    await OracleTests.expectI3(harness, audit, label, history)
                    guard target.shows(observed), violations.isEmpty else {
                        return
                    }
                    model = target
                } catch {
                    #expect(harness.fileSystem.crashed, "\(label): \(step) failed without a crash: \(error)")
                    await OracleTests.expectI3(harness, audit, label, history)
                    unlinks += OracleTests.unlinks(harness)
                    let committed = await harness.state.core.committedGeneration
                    disk = try await OracleTests.reconcile(harness.fileSystem.survivingDisk(), time: time, model: &model, candidates: [model, target], committed: committed, versions: versions, label: label, history: history)
                    continue lifetimes
                }
            }
            await harness.store.close()
            await OracleTests.expectI3(harness, audit, label, history)
            unlinks += OracleTests.unlinks(harness)
            disk = harness.fileSystem.survivingDisk()
        }
        print("R-STO-5 oracle, seed \(seed): \(steps) steps, \(lifetimes) lifetimes, \(unlinks) blob unlinks")
    }

    /// The blob unlinks of `harness`'s lifetime that succeeded.
    @available(macOS 15.0, iOS 18.0, *)
    static func unlinks(_ harness: CoreHarness) -> Int {
        let prefix = harness.layout.blobsDirectory.path + "/"
        return harness.fileSystem.operations.filter {
            $0.kind == .removeItem && $0.failure == nil && $0.url.path.hasPrefix(prefix) && StoreLayout.parseBlobName($0.url.lastPathComponent) != nil
        }.count
    }

    /// Reopens a crash survivor, checks I-1…I-5, and requires the store to show the oracle before or after the step
    /// that crashed (a committed prefix, I-5); the oracle continues from whichever it shows; then reaps what the
    /// relaunch may (audited for I-3) and checks again. Returns the disk the reopened store left at its close.
    @available(macOS 15.0, iOS 18.0, *)
    static func reconcile(
        _ disk: DiskImage,
        time: ManualTimeSource,
        model: inout Model,
        candidates: [Model],
        committed: UInt64,
        versions: [String: [ContentHash: Int]],
        label: String,
        history: [String]
    ) async throws -> DiskImage {
        let (reopened, audit) = CoreHarness.audited(disk: disk, time: time)
        let report = try await reopened.store.open()
        let headers = IndexFile.allCases.compactMap { disk.files[reopened.layout.indexURL($0).path].flatMap(IndexHeader.parse) }
        #expect(headers.allSatisfy { report.launchEpoch > $0.generation }, "\(label): I-5 epoch after the crash in \(history)")
        let loaded = await reopened.state.core.committedGeneration
        #expect(loaded >= committed, "\(label): I-5, generation \(loaded) < committed \(committed) after \(history)")
        let violations = await CoreInvariants.violations(of: reopened)
        #expect(violations.isEmpty, "\(label): after the crash in \(history): \(violations)")
        let observed = await OracleTests.observe(reopened, versions: versions)
        if let match = candidates.lazy.compactMap({ $0.matching(observed) }).first {
            model = match
        } else {
            Issue.record("\(label): after the crash in \(history): store \(observed) matches none of \(candidates)")
        }
        await reopened.settleDeletions(audited: audit)
        let reaped = await CoreInvariants.violations(of: reopened)
        #expect(reaped.isEmpty, "\(label): after the relaunch's reap in \(history): \(reaped)")
        let afterReap = await OracleTests.observe(reopened, versions: versions)
        #expect(model.matching(afterReap) != nil, "\(label): after the relaunch's reap in \(history): store \(afterReap) ≠ oracle \(model)")
        await reopened.store.close()
        await OracleTests.expectI3(reopened, audit, label + ", relaunch", history)
        return reopened.fileSystem.survivingDisk()
    }
}
