import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// S3 probe (lens crash): the shipped model-based oracle never calls `runDueWork()`, so no blob is ever unlinked in
/// its sequences and I-3 holds there vacuously. This probe runs the same seeded sequences with a reap (the deletion
/// protocol driven to its end: acknowledged install, grace, fresh install, unlink) after random steps and after every
/// relaunch, with the readers' snapshot audited for I-3 at every unlink.
@Suite("S3 probe: model-based oracle with reaping", .serialized)
struct S3OracleReapProbe {
    @Test(
        "R-STO-5: seeded random store, relocate, remove, evict, reap, crash and reopen sequences match the oracle with I-1…I-5 after every step",
        .timeLimit(.minutes(1)),
        arguments: Array(UInt64(1)...UInt64(16))
    )
    @available(macOS 15.0, iOS 18.0, *)
    func oracleWithReaping(seed: UInt64) async throws {
        var random = OracleTests.Generator(state: seed)
        var model = OracleTests.Model()
        var nextVersion = 0
        var versions: [String: [ContentHash: Int]] = [:]
        var disk = DiskImage()
        let time = ManualTimeSource()
        var sequence: UInt32 = 0
        var steps = 0
        var history: [String] = []
        var lifetimes = 0
        var reaped = 0
        lifetimes: while steps < 40, lifetimes < 200 {
            lifetimes += 1
            let crashBefore = random.below(2) == 0 ? 8 + random.below(60) : nil
            let drawn = CrashMode.allCases[random.below(CrashMode.allCases.count)]
            let mode = crashBefore == nil ? CrashMode.processKill : drawn
            let (harness, audit) = CoreHarness.audited(disk: disk, crashBefore: crashBefore, mode: mode, time: time)
            let label = "seed \(seed), lifetime crash \(String(describing: crashBefore)) \(mode)"
            do {
                _ = try await harness.store.open()
                if !harness.fileSystem.crashed {
                    let observed = await OracleTests.observe(harness, versions: versions)
                    guard let match = model.matching(observed) else {
                        Issue.record("\(label): after the relaunch in \(history): store \(observed) ≠ oracle \(model)")
                        return
                    }
                    model = match
                }
            } catch {
                disk = harness.fileSystem.survivingDisk()
                continue lifetimes
            }
            while steps < 40 {
                await Task.yield()
                // A reap between steps: everything doomed and acknowledged goes once the grace passed.
                if random.below(3) == 0 {
                    history.append("reap")
                    let before = harness.fileSystem.operations.count
                    _ = await harness.settleDeletions()
                    reaped += harness.fileSystem.operations[before...].filter { $0.kind == .removeItem }.count
                    let i3 = await audit.violations(harness.fileSystem.operations, layout: harness.layout)
                    #expect(i3.isEmpty, "\(label): after \(history): \(i3)")
                    if harness.fileSystem.crashed {
                        let committed = await harness.state.core.committedGeneration
                        disk = try await S3OracleReapProbe.reconcile(harness.fileSystem.survivingDisk(), time: time, model: &model, candidates: [model], committed: committed, versions: versions, label: label, history: history)
                        continue lifetimes
                    }
                    let observed = await OracleTests.observe(harness, versions: versions)
                    // A reap changes nothing the oracle shows, except that an evicted asset can no longer come back.
                    #expect(model.shows(observed), "\(label): after \(history): store \(observed) ≠ oracle \(model)")
                    let violations = await CoreInvariants.violations(of: harness)
                    #expect(violations.isEmpty, "\(label): after \(history): \(violations)")
                }
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
                    let i3 = await audit.violations(harness.fileSystem.operations, layout: harness.layout)
                    #expect(i3.isEmpty, "\(label): after \(history): \(i3)")
                    if harness.fileSystem.crashed {
                        let committed = await harness.state.core.committedGeneration
                        disk = try await S3OracleReapProbe.reconcile(disk, time: time, model: &model, candidates: [model], committed: committed, versions: versions, label: label, history: history)
                    }
                    continue lifetimes
                }
                do {
                    try await OracleTests.run(step, harness, target: target, sequence: &sequence)
                    let observed = await OracleTests.observe(harness, versions: versions)
                    #expect(target.shows(observed), "\(label): after \(history): store \(observed) ≠ oracle \(target)")
                    let violations = await CoreInvariants.violations(of: harness)
                    #expect(violations.isEmpty, "\(label): after \(history): \(violations)")
                    guard target.shows(observed), violations.isEmpty else {
                        return
                    }
                    model = target
                } catch {
                    #expect(harness.fileSystem.crashed, "\(label): \(step) failed without a crash: \(error)")
                    let committed = await harness.state.core.committedGeneration
                    disk = try await S3OracleReapProbe.reconcile(harness.fileSystem.survivingDisk(), time: time, model: &model, candidates: [model, target], committed: committed, versions: versions, label: label, history: history)
                    continue lifetimes
                }
            }
            await harness.store.close()
            let i3 = await audit.violations(harness.fileSystem.operations, layout: harness.layout)
            #expect(i3.isEmpty, "\(label): after \(history): \(i3)")
            disk = harness.fileSystem.survivingDisk()
        }
        print("S3 oracle with reaping, seed \(seed): \(steps) steps, \(lifetimes) lifetimes, \(reaped) unlinks")
    }

    /// `OracleTests.reconcile`, then the relaunch's reap (audited), checked again.
    @available(macOS 15.0, iOS 18.0, *)
    static func reconcile(
        _ disk: DiskImage,
        time: ManualTimeSource,
        model: inout OracleTests.Model,
        candidates: [OracleTests.Model],
        committed: UInt64,
        versions: [String: [ContentHash: Int]],
        label: String,
        history: [String]
    ) async throws -> DiskImage {
        let reconciled = try await OracleTests.reconcile(disk, time: time, model: &model, candidates: candidates, committed: committed, versions: versions, label: label, history: history)
        let (reopened, audit) = CoreHarness.audited(disk: reconciled, time: time)
        _ = try await reopened.store.open()
        await reopened.settleDeletions()
        let violations = await CoreInvariants.violations(of: reopened)
        #expect(violations.isEmpty, "\(label): after the relaunch's reap in \(history): \(violations)")
        let observed = await OracleTests.observe(reopened, versions: versions)
        if let match = model.matching(observed) {
            model = match
        } else {
            Issue.record("\(label): after the relaunch's reap in \(history): store \(observed) ≠ oracle \(model)")
        }
        await reopened.store.close()
        let i3 = await audit.violations(reopened.fileSystem.operations, layout: reopened.layout)
        #expect(i3.isEmpty, "\(label): relaunch reap: \(i3)")
        return reopened.fileSystem.survivingDisk()
    }
}
