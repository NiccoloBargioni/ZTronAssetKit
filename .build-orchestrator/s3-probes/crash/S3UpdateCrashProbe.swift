import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

@testable import ZTronAssetStorage

/// S3 probe (lens crash): SPEC §7.3 "crash at every boundary during: checksum-change update · directory change ·
/// removal". v1 {a, b, c} is published and durable; v2 changes a's bytes, moves b, removes c; a's new bytes are
/// published, the old blob of a and c's blob are reaped after the acknowledgement and the grace; durable flush; close.
@available(macOS 15.0, iOS 18.0, *)
enum S3UpdateRun {
    static let a1 = CleanupFixture.asset("a", seed: 7_001, count: 400)
    static let b1 = CleanupFixture.asset("b", seed: 7_002, count: 350)
    static let c1 = CleanupFixture.asset("c", seed: 7_003, count: 300)
    static let a2 = CleanupFixture.asset("a", seed: 7_011, count: 420)
    static var b2: CleanupFixture.Asset {
        var entry = S3UpdateRun.b1.entry
        entry.localPathComponents = ["moved"]
        return CleanupFixture.Asset(entry: entry, bytes: S3UpdateRun.b1.bytes)
    }
    static let v1 = CoreFixture.manifest([S3UpdateRun.a1.entry, S3UpdateRun.b1.entry, S3UpdateRun.c1.entry], etagSeed: "v1")
    static let v2 = CoreFixture.manifest([S3UpdateRun.a2.entry, S3UpdateRun.b2.entry], etagSeed: "v2")

    static func setUp(_ harness: CoreHarness) async throws {
        try await harness.seed([S3UpdateRun.a1, S3UpdateRun.b1, S3UpdateRun.c1])
        try await harness.store.flush(.durable)
        harness.time.advance(by: 3_600)
    }

    struct Trace {
        var committed: UInt64 = 0
        var v2Committed = false
        var a2Returned = false
        var a2Committed = false
    }

    static func update(_ harness: CoreHarness) async -> Trace {
        var trace = Trace()
        do {
            trace.committed = try await harness.store.apply(S3UpdateRun.v2, etag: nil, eviction: nil).generation
            trace.v2Committed = true
            try await harness.publish(S3UpdateRun.a2.bytes, [S3UpdateRun.a2.entry], urgency: .userInitiated, sequence: 9)
            trace.a2Returned = true
            try await harness.store.flush(.ordered)
            trace.a2Committed = true
            trace.committed = await harness.state.core.committedGeneration
            await harness.settleDeletions()
            try await harness.store.flush(.durable)
            trace.committed = await harness.state.core.committedGeneration
            await harness.store.close()
        } catch {
            // The crash.
        }
        return trace
    }
}

@Suite("S3 probe: crash at every boundary during an update, a directory change and a removal")
struct S3UpdateCrashProbe {
    @Test(
        "R-STO-5: crash at every boundary during a checksum-change update, a directory change and a removal preserves I-1…I-5",
        .serialized,
        .timeLimit(.minutes(1)),
        arguments: CrashMode.allCases
    )
    @available(macOS 15.0, iOS 18.0, *)
    func crashDuringUpdate(mode: CrashMode) async throws {
        let clean = CoreHarness.cleanup()
        try await S3UpdateRun.setUp(clean)
        let start = clean.fileSystem.mutationCount
        let cleanTrace = await S3UpdateRun.update(clean)
        #expect(cleanTrace.a2Committed)
        let total = clean.fileSystem.mutationCount
        let unlinked = Set(CoreInvariants.blobRemovals(clean.fileSystem.operations, layout: clean.layout))
        #expect(unlinked.count == 2, "the clean run reaps a's old blob and c's blob: \(unlinked)")
        for point in start..<total {
            await Task.yield()
            let label = "\(mode) before mutation \(point)"
            let harness = CoreHarness.cleanup(crashBefore: point, mode: mode)
            try await S3UpdateRun.setUp(harness)
            let trace = await S3UpdateRun.update(harness)
            #expect(harness.fileSystem.crashed, "\(label): the crash happened")
            // I-3 in the crashed lifetime: nothing the readers' current snapshot holds was unlinked.
            let installed = await harness.sink.installed
            let disk = harness.fileSystem.survivingDisk()
            for id in [S3UpdateRun.a1.id, S3UpdateRun.b1.id, S3UpdateRun.c1.id] {
                if mode == .processKill || mode == .processKillTornWrite, let location = installed.location(for: id, extensions: []) {
                    let held = disk.files[location.url.path] != nil
                    #expect(held, "\(label): I-3, the installed snapshot hands out \(location.url.lastPathComponent), which is gone")
                }
            }
            let reopened = CoreHarness.cleanup(disk: disk, time: harness.time)
            let report = try await reopened.store.open()
            await CleanupCrashTests.checkGenerations(reopened, disk: disk, committed: trace.committed, report: report, label: label)
            let violations = await CoreInvariants.violations(of: reopened)
            #expect(violations.isEmpty, "\(label): \(violations)")
            // The reopened lifetime's reaper must not unlink anything still referenced.
            await reopened.settleDeletions()
            let afterReap = await CoreInvariants.violations(of: reopened)
            #expect(afterReap.isEmpty, "\(label) after the relaunch's reap: \(afterReap)")
            // Converge on v2.
            _ = try await reopened.store.apply(S3UpdateRun.v2, etag: nil, eviction: nil)
            var downloaded: Set<String> = []
            for asset in [S3UpdateRun.a2, S3UpdateRun.b2] where !(await reopened.isPresent(asset.id, at: asset.key)) {
                try await reopened.publish(asset.bytes, [asset.entry], urgency: .userInitiated, sequence: 50)
                downloaded.insert(asset.id.rawValue)
            }
            if mode == .processKill || mode == .processKillTornWrite {
                #expect(!downloaded.contains("b"), "\(label): b was re-downloaded")
                if trace.a2Returned {
                    #expect(!downloaded.contains("a"), "\(label): a's new bytes were re-downloaded")
                }
            } else if trace.a2Committed {
                #expect(!downloaded.contains("a"), "\(label): a's committed new bytes were re-downloaded")
            }
            await reopened.settleDeletions()
            try await reopened.store.flush(.durable)
            for asset in [S3UpdateRun.a2, S3UpdateRun.b2] {
                let location = await reopened.store.location(for: asset.id, extensions: [], recordingAccess: false)
                let converged = location.flatMap { reopened.content($0.url) } == asset.bytes
                let residency = await reopened.record(asset.id)?.residency
                #expect(converged, "\(label): \(asset.id.rawValue) did not converge: \(String(describing: residency)) downloaded \(downloaded)")
            }
            #expect(await reopened.store.location(for: S3UpdateRun.c1.id, extensions: [], recordingAccess: false) == nil, "\(label): c is gone")
            let after = await CoreInvariants.violations(of: reopened)
            #expect(after.isEmpty, "\(label) after convergence: \(after)")
            await reopened.store.close()
        }
        print("S3 probe \(mode): \(total - start) crash points")
    }
}
