import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// A pin left by an ENOENT re-queue (Stage 3 close-out cycle 21, ruling S3-R26 item 12's answer 6.3;
/// `integrate-rr21.md`'s rr21-T8b): a batch layer pins its ids to a job publishing at that layer's apply, and the job's
/// publication then ends in ENOENT for an attempt the engine had cancelled, which re-queues the job at the same epoch
/// (`publicationFailed`, ARCHITECTURE §7.6). `waitingTarget`'s `.queued` arm leaves the pin, so the replay follows the
/// copy then. The transfers run on `RacingSource`, whose cancel does not end the stream, so a cancelled attempt's
/// completion arrives after its cancel; the test writes every staged file itself.
extension EngineFollowBarrierTests {
    /// rr21-T8b (rr21-B17's left pin, `waitingTarget`'s `.queued` arm): O (zz-o, K's, and zz-a1…zz-a3, W1…W3's) and X
    /// (zz-x) download; V's request for zz-x is cancelled and V2's arrives while X's cancelled attempt drains, whose
    /// completion then comes with no staged bytes, so X's job publishes the drained file, held at its claim (on the
    /// store's metadata executor), while O publishes too. K0 maps zz-a1…zz-a3 to X's content, O's commit owes their
    /// re-routes, K1 maps them to W's content while X still publishes (K1's layer pins X), and X's claim then finds
    /// ENOENT: a fresh attempt at the same epoch, queued behind the barrier. Visited first, the commit re-routed W1…W3
    /// onto X publishing, K1's visit passed X, and X's fresh attempt's commit, under K1's copy, re-routed them to W's
    /// content. The replay finds X queued, not at the end K1's layer recorded, and follows the copy then: W1…W3 join W's
    /// job, and X holds none of their ids.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed re-route pinned to a job an ENOENT re-queued before the replay follows the copy then (F-28, T22)", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func owedReroutePinnedToARequeuedJobFollowsTheCopy(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 2_027_451
        let oBytes = Self.owedOBytes(seed)
        let xBytes = EngineFixture.bytes(seed + 5, count: 18)
        let wBytes = EngineFixture.bytes(seed + 6, count: 20)
        let o = EngineHarness.onDemand("zz-o", oBytes)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let ids = (1...3).map { AssetID(rawValue: "zz-a\($0)") }
        let onO = ids.map { EngineHarness.onDemand($0.rawValue, oBytes) }
        let onX = ids.map { EngineFixture.entry($0.rawValue, xBytes, policy: .onDemand) }
        let onW = ids.map { EngineFixture.entry($0.rawValue, wBytes, policy: .onDemand) }
        let oT = o.transferID
        let xT = x.transferID
        let wT = onW[0].transferID
        try #require(onX.allSatisfy { $0.transferID == xT } && wT != xT && wT != oT, "setup: K0 maps the ids onto X's content, K1 onto W's")
        func manifest(_ entries: [ManifestEntry], round: UInt64) -> [ManifestEntry] {
            FollowBarrier.fillers(seed + 100 + 100 * round) + [o] + entries + Self.laterFillers(seed + 3_000 * (round + 1))
        }
        let source = RacingSource(manifest: EngineFixture.manifestData(manifest(onO + [x], round: 0)))
        let time = ManualTimeSource()
        let reserve = StoragePolicy().reserveFreeBytes
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 32_000_000, opportunisticCapacity: reserve + 32_000_000)
        )
        let bulk = SteppedBlockingExecutor(holding: false)
        // The store claims a staged file on the metadata executor (`performPublish`'s rename), where a missing file's
        // ENOENT is found: X's publication of the drained file is held there.
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), metadata: metadata, bulk: bulk, fileSystem: fileSystem, remote: source)
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        await engine.readForTests { $0.state.followIDsPerTurn = Self.owedIDsPerTurn }
        let sink = try await harness.store.makeStagingSink()
        let oID = o.identifier
        let k = Task { await engine.awaitAsset(oID, lane: .userInitiated) }
        let w = ids.map { id in Task { await engine.awaitAsset(id, lane: .userInitiated) } }
        await engine.awaitCondition { $0.state.jobs[oT]?.state == .downloading && $0.state.jobs[oT]?.interests.count == 4 }
        let xID = x.identifier
        let v = Task { await engine.awaitAsset(xID, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[xT]?.state == .downloading }
        await engine.waitForHandle(xT)
        v.cancel()
        #expect(await v.value == .failure(.cancelled), "setup: V's cancelled request is answered at once")
        await engine.awaitCondition { $0.state.jobs[xT] == nil }
        let v2 = Task { await engine.awaitAsset(xID, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[xT]?.state == .queued && $0.state.jobs[xT]?.interests.count == 1 }
        let requests = await source.requests
        let oIndex = try #require(requests.firstIndex { $0.id == oT })
        let xIndex = try #require(requests.firstIndex { $0.id == xT })
        try #require(requests.count == 2, "setup: V2 waits for X's cancelled attempt, which drains: \(requests.map(\.id))")
        let oName = requests[oIndex].partialName
        try sink.createPartial(oName)
        _ = try sink.appendPartial(oBytes, to: oName)
        await engine.awaitCondition { !$0.state.storeWorkInFlight }
        await metadata.setHolding(true)
        // X's cancelled attempt completes with nothing staged: its job, queued, adopts the drained file and publishes it.
        await source.deliver(xIndex, .staged(StagedFile(name: requests[xIndex].partialName, byteCount: Int64(xBytes.count), resumed: false, httpStatus: 200, etag: nil)))
        await engine.awaitCondition { $0.state.jobs[xT]?.state == .verifying }
        try await metadata.requireHeldUnits(atLeast: 1)
        let xUnit = try #require(await metadata.heldUnits.first, "setup: X's claim of the drained file is held at the store")
        var claim = HeldUnits(bulk: metadata, kept: [xUnit], releaser: Self.releasing(except: [xUnit], metadata))
        await bulk.setHolding(true)
        await source.deliver(oIndex, .staged(StagedFile(name: oName, byteCount: Int64(oBytes.count), resumed: false, httpStatus: 200, etag: nil)))
        await engine.awaitCondition { $0.state.jobs[oT]?.state == .verifying }
        try await bulk.requireHeldUnits(atLeast: 1)
        let oUnit = try #require(await bulk.heldUnits.first, "setup: O's publication is held at the store")
        var held = HeldUnits(bulk: bulk, kept: [oUnit], releaser: Self.releasing(except: [oUnit], bulk))
        let setup = FollowBarrier.Setup(time: time, fileSystem: fileSystem, harness: harness, q: o)
        try await Self.applyHeld(manifest([x] + onX, round: 1), tag: "k0-requeue-\(seed)", setup, visit: visit)
        await engine.readForTests { $0.holdDrainFollowUps() }
        await held.release(oUnit)
        await engine.awaitCondition { $0.state.jobs[oT] == nil }
        let owed = await engine.readForTests { e in Self.owedBatches(e).map(\.items.count) }
        try #require(owed == [3], "setup: O's commit owes the three re-routes as one batch: \(owed)")
        let k1 = try ValidatedManifest(entries: manifest([x] + onW, round: 2), digest: ContentHash.sha256(of: Data("k1-requeue-\(seed)".utf8)))
        await engine.readForTests { $0.holdFollowFollowUps() }
        let applied = await engine.applyAndFollow(k1, etag: nil, eviction: nil)
        #expect((try? applied.get()) != nil, "setup: K1 is applied: \(applied)")
        let pin = await engine.readForTests { e in (pins: Self.owedBatches(e).first?.layers.map { $0.ends[xT] }, epoch: e.state.jobs[xT]?.epoch) }
        try #require(pin.pins == [pin.epoch] && pin.epoch != nil, "setup: K1's layer pins X at its publication's epoch: \(pin)")
        await claim.release(xUnit)
        await engine.awaitCondition { $0.state.jobs[xT]?.state == .queued }
        let requeued = await engine.readForTests { e in (epoch: e.state.jobs[xT]?.epoch, waiting: !Self.owedBatches(e).isEmpty) }
        try #require(requeued.epoch == pin.epoch && requeued.waiting, "setup: X's ENOENT re-queues it at the same epoch while the batch waits: \(requeued)")
        var violations: [String] = []
        while await engine.readForTests({ $0.followOwed || !$0.state.eventsAfterFollow.isEmpty }) {
            _ = await Self.runOneHeldTurn(engine)
            violations += await engine.invariantViolations()
        }
        await engine.readForTests { e in
            e.releaseDrainFollowUps()
            e.releaseFollowFollowUps()
        }
        let replayed = await engine.readForTests { e in (x: e.state.jobs[xT]?.assets.sorted() ?? [], w: e.state.jobs[wT]?.assets.sorted() ?? []) }
        #expect(replayed.x == [xID] && replayed.w == ids, "the replay follows K1's copy: W's job holds zz-a1…zz-a3, X only zz-x: \(replayed)")
        await held.stop()
        await claim.stop()
        for (transfer, bytes) in [(wT, wBytes), (xT, xBytes)] {
            await engine.awaitCondition { $0.state.jobs[transfer]?.state == .downloading }
            await engine.waitForHandle(transfer)
            let request = try #require(await source.requests.last { $0.id == transfer })
            let index = try #require(await source.requests.lastIndex { $0.id == transfer })
            try sink.createPartial(request.partialName)
            _ = try sink.appendPartial(bytes, to: request.partialName)
            await source.deliver(index, .staged(StagedFile(name: request.partialName, byteCount: Int64(bytes.count), resumed: false, httpStatus: 200, etag: nil)))
        }
        let kResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: k) }
        let v2Result = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: v2) }
        var wResults: [Result<AssetLocation, AssetError>] = []
        for waiter in w {
            wResults.append(await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        #expect(Self.sizes([kResult, v2Result]) == [16, 18] && Self.sizes(wResults) == [20, 20, 20], "K gets O's bytes, V2 X's, W1…W3 W's (visit-first): K \(kResult), V2 \(v2Result), W \(Self.sizes(wResults))")
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        let after = await engine.invariantViolations()
        #expect(after.isEmpty, "\(after.prefix(3))")
        await engine.shutdown()
    }
}
