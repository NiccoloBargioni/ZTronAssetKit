import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch probes (s3f close-out verification, cycle 4, correctness lens). Never committed.
@Suite("VerifyC4Correct probes")
struct VerifyC4CorrectProbes {
    @available(macOS 15.0, iOS 18.0, *)
    static func fillers(_ seed: UInt64) -> [ManifestEntry] {
        (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
    }

    /// PROBE-C4-SPACE-ORIG: the cycle-3 verifier's PROBE-C3-SPACE, unchanged in substance (300-byte reclaim, 1 MB room),
    /// run against HEAD: the waiter of a listed id must be answered from its 16-byte new content.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C4-SPACE-ORIG: a space sweep during the follow does not answer a moved id with its replaced content's figures", .timeLimit(.minutes(3)))
    func spaceSweepOrig() async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 20_000_000, opportunisticCapacity: reserve + 20_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = EngineFixture.bytes(779_001, count: 300)
        let qBytes = EngineFixture.bytes(779_002, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([x, q])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let old = EngineHarness.onDemand("zz-target", Data(repeating: 0x6F, count: 5_000_000))
        await harness.serveManifest([q] + Self.fillers(720_000) + [old], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(1_000_000, harness: harness, fileSystem: fileSystem)
        let pending = try await harness.store.freeSpace().pendingReclaim
        #expect(pending == Int64(xBytes.count), "setup: x's bytes wait for reclaim")
        await engine.refreshFreeSpace()
        await harness.source.script(old.transferID, [.hold])
        let waiter = Task { await engine.awaitAsset(old.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[old.transferID]?.state == .blocked(.awaitingSpace) }
        let replacement = EngineHarness.onDemand("zz-target", EngineFixture.bytes(779_004, count: 16))
        await harness.source.script(replacement.transferID, [.stage(EngineFixture.bytes(779_004, count: 16))])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + Self.fillers(820_000) + [replacement], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        let before = await engine.readForTests { engine in
            (listed: engine.state.applied.entry(for: old.identifier)?.transferID == replacement.transferID,
             oldState: engine.state.jobs[old.transferID]?.state,
             unfollowed: engine.state.unfollowed.contains(old.transferID),
             owed: engine.followOwed)
        }
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[old.transferID]?.state != .blocked(.awaitingSpace) }
        }
        let mid = await engine.readForTests { engine in
            (oldState: engine.state.jobs[old.transferID]?.state, owed: engine.followOwed, violations: engine.invariantViolations())
        }
        print("PROBE-C4-SPACE-ORIG before the reap: \(before); after the reap: owed \(mid.owed), old job \(String(describing: mid.oldState))")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let answer = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: waiter) }
        _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        print("PROBE-C4-SPACE-ORIG answer: \(answer)")
        #expect(before.listed && before.owed && !before.unfollowed, "setup: \(before)")
        #expect(mid.owed, "the sweep ran while the follow was owed")
        #expect(mid.violations.isEmpty, "\(mid.violations.prefix(3))")
        #expect((try? answer.get())?.byteSize == 16, "PROBE-C4-SPACE-ORIG FAIL: the waiter of a listed id was answered \(answer)")
        await engine.shutdown()
    }

    /// PROBE-C4-SPACE-PARTIAL: the replaced content is shared by two listed ids (`zz-keep`, `zz-target`, same 5 MB bytes,
    /// one transfer); the apply moves only `zz-target` to a 16-byte content. During the owed follow the reclaim's sweep
    /// either re-parks the old job (0.5 MB room before the 4 MB reclaim) or re-queues it (2 MB). The moved id must be
    /// answered from its new content; the kept id from the old content: `insufficientSpace(required: 5,000,000, ...)` when
    /// re-parked, success at 5,000,000 bytes when re-queued. Exercises the fix's "keeps some ids, read again" path.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C4-SPACE-PARTIAL: a space sweep during the follow answers a shared content's moved and kept ids each from its own content", .timeLimit(.minutes(3)), arguments: [Int64(500_000), Int64(2_000_000)])
    func spaceSweepPartial(_ roomBeforeReclaim: Int64) async throws {
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), fileSystem: fileSystem)
        let engine = harness.engine
        let xBytes = Data(repeating: 0x78, count: 4_000_000)
        let qBytes = EngineFixture.bytes(779_102, count: 300)
        let x = EngineFixture.entry("x", xBytes)
        let q = EngineFixture.entry("q", qBytes)
        await harness.serveManifest([x, q])
        await harness.scriptTransfers([(x, xBytes), (q, qBytes)])
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        try await harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        let oldBytes = Data(repeating: 0x6F, count: 5_000_000)
        let keep = EngineHarness.onDemand("zz-keep", oldBytes)
        let target = EngineHarness.onDemand("zz-target", oldBytes)
        #expect(keep.transferID == target.transferID, "setup: one transfer for both ids")
        await harness.serveManifest([q] + Self.fillers(730_000) + [keep, target], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        _ = try await EngineRegressionCycle6Tests.leaveRoom(4_000_000, harness: harness, fileSystem: fileSystem)
        #expect(try await harness.store.freeSpace().pendingReclaim == Int64(xBytes.count), "setup: x's bytes wait for the reclaim")
        await engine.refreshFreeSpace()
        await harness.source.script(keep.transferID, [.stage(oldBytes)])
        let waiterKeep = Task { await engine.awaitAsset(keep.identifier, lane: .userInitiated) }
        let waiterTarget = Task { await engine.awaitAsset(target.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[keep.transferID]?.state == .blocked(.awaitingSpace) && $0.state.jobs[keep.transferID]?.interests.count == 2 }
        let replacement = EngineHarness.onDemand("zz-target", EngineFixture.bytes(779_104, count: 16))
        await harness.source.script(replacement.transferID, [.stage(EngineFixture.bytes(779_104, count: 16))])
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest([q] + Self.fillers(830_000) + [keep, replacement], etag: "v3")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        let before = await engine.readForTests { engine in
            (listed: engine.state.applied.entry(for: target.identifier)?.transferID == replacement.transferID,
             keepListed: engine.state.applied.entry(for: keep.identifier)?.transferID == keep.transferID,
             parked: engine.state.jobs[keep.transferID]?.state,
             reached: engine.state.unfollowed.contains(keep.transferID),
             owed: engine.followOwed)
        }
        try await EngineSyncTests.leaveRoom(roomBeforeReclaim, harness: harness, fileSystem: fileSystem)
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[keep.transferID]?.state != .blocked(.awaitingSpace) }
        }
        let mid = await engine.readForTests { engine in
            (assets: engine.state.jobs[keep.transferID]?.assets.sorted().map(\.rawValue),
             state: engine.state.jobs[keep.transferID]?.state,
             owed: engine.followOwed,
             violations: engine.invariantViolations())
        }
        print("PROBE-C4-SPACE-PARTIAL[\(roomBeforeReclaim)] before: \(before); after the sweep: \(mid.assets ?? []) \(String(describing: mid.state)) owed \(mid.owed)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let answerTarget = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: waiterTarget) }
        let answerKeep = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: waiterKeep) }
        let outcome = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        let violations = await engine.invariantViolations()
        print("PROBE-C4-SPACE-PARTIAL[\(roomBeforeReclaim)] target: \(answerTarget); keep: \(answerKeep); run: \(outcome)")
        #expect(before.listed && before.keepListed && before.parked == .blocked(.awaitingSpace) && !before.reached && before.owed, "setup: \(before)")
        #expect(mid.owed, "the sweep ran while the follow was owed")
        // Re-parked, its last waiter answered, the old job is removed (nil); re-queued, it keeps only the unmoved id.
        #expect(mid.assets == nil || mid.assets == ["zz-keep"], "the old job keeps only the unmoved id: \(String(describing: mid.assets))")
        #expect(mid.violations.isEmpty, "\(mid.violations.prefix(3))")
        #expect((try? answerTarget.get())?.byteSize == 16, "PROBE-C4-SPACE-PARTIAL FAIL: the moved id was answered \(answerTarget)")
        if roomBeforeReclaim < 1_000_000 {
            var required: Int64?
            if case .failure(.insufficientSpace(let needed, _)) = answerKeep { required = needed }
            #expect(required == 5_000_000, "the kept id gets its own content's figures: \(answerKeep)")
        } else {
            #expect((try? answerKeep.get())?.byteSize == 5_000_000, "the kept id is answered from its content: \(answerKeep)")
        }
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await engine.shutdown()
    }
}
