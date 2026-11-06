import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// e1-PR (Stage 3 close-out cycle 22, ruling S3-R27 item 12.2; e1 §3's untraced removal edge): rr21-T8b's shape with
/// X's only interest withdrawn behind the barrier before O's commit, so the drain replays the withdrawal before the
/// batch: X, re-queued by its ENOENT with the pin kept and no apply since, is dropped before the batch's replay. The
/// kept pin (e1-R1) returns the pin layer's outgoing copy, which maps zz-a1…zz-a3 to X's content, so the replay joins a
/// new job of that content; a visit-first engine's commit had joined them to X publishing, and they rode X's fresh
/// attempt. Either way X's content is fetched once more and its commit, under K1's copy, re-routes them to W's content.
/// The window exists only in `sweepFollowsFirst`: visited first, the withdrawal applies at once, before O's commit.
extension EngineFollowBarrierTests {
    /// e1-PR: X's job as the batch's replay finds it and after it is recorded with the answers; the answers are
    /// visit-first's: K O's bytes, V2 its cancellation, W1…W3 W's bytes.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-11: an owed re-route pinned to a job an ENOENT re-queued, which a withdrawal replayed before the batch drops, rides a new job of its content, with the visit-first answers (F-28, D-13, e1-PR)", .timeLimit(.minutes(3)))
    func owedReroutePinnedToARequeuedJobDroppedBeforeTheReplayKeepsTheVisitFirstAnswers() async throws {
        let seed: UInt64 = 2_029_201
        let visit = LaneDropVisit.sweepFollowsFirst
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
        try await Self.applyHeld(manifest([x] + onX, round: 1), tag: "k0-requeue-removal-\(seed)", setup, visit: visit)
        await engine.readForTests { $0.holdDrainFollowUps() }
        // V2 withdraws behind the barrier, before O's commit: its removal waits ahead of the batch.
        v2.cancel()
        let v2Result = await v2.value
        #expect(v2Result == .failure(.cancelled), "V2's cancelled request is answered at once: \(v2Result)")
        await engine.awaitCondition { e in
            e.state.eventsAfterFollow.contains { event in
                if case .removal(_, let transfer) = event {
                    return transfer == xT
                }
                return false
            }
        }
        await held.release(oUnit)
        await engine.awaitCondition { $0.state.jobs[oT] == nil }
        let owed = await engine.readForTests { e in Self.owedBatches(e).map(\.items.count) }
        try #require(owed == [3], "setup: O's commit owes the three re-routes as one batch: \(owed)")
        let k1 = try ValidatedManifest(entries: manifest([x] + onW, round: 2), digest: ContentHash.sha256(of: Data("k1-requeue-removal-\(seed)".utf8)))
        await engine.readForTests { $0.holdFollowFollowUps() }
        let applied = await engine.applyAndFollow(k1, etag: nil, eviction: nil)
        #expect((try? applied.get()) != nil, "setup: K1 is applied: \(applied)")
        let pin = await engine.readForTests { e in (pins: Self.owedBatches(e).first?.layers.map { $0.ends[xT] }, epoch: e.state.jobs[xT]?.epoch) }
        try #require(pin.pins == [pin.epoch] && pin.epoch != nil, "setup: K1's layer pins X at its publication's epoch: \(pin)")
        await claim.release(xUnit)
        await engine.awaitCondition { $0.state.jobs[xT]?.state == .queued }
        let requeued = await engine.readForTests { e in
            (epoch: e.state.jobs[xT]?.epoch, waiting: !Self.owedBatches(e).isEmpty, removalFirst: e.state.eventsAfterFollow.first.map { event -> Bool in
                if case .removal = event {
                    return true
                }
                return false
            })
        }
        try #require(requeued.epoch == pin.epoch && requeued.waiting && requeued.removalFirst == true, "setup: X's ENOENT re-queues it at the same epoch while the removal and then the batch wait: \(requeued)")
        var violations: [String] = []
        // X's job as the turn that replays the batch finds it (the last turn while the batch waits), recorded only.
        var atReplay = ""
        while await engine.readForTests({ $0.followOwed || !$0.state.eventsAfterFollow.isEmpty }) {
            let waiting = await engine.readForTests { e in
                Self.owedBatches(e).isEmpty ? nil : e.state.jobs[xT].map { "\($0.state) at epoch \($0.epoch) holding \($0.assets.sorted().map(\.rawValue))" } ?? "gone"
            }
            atReplay = waiting ?? atReplay
            _ = await Self.runOneHeldTurn(engine)
            violations += await engine.invariantViolations()
        }
        await engine.readForTests { e in
            e.releaseDrainFollowUps()
            e.releaseFollowFollowUps()
        }
        let replayed = await engine.readForTests { e in
            e.state.jobs[xT].map { "\($0.state) at epoch \($0.epoch) holding \($0.assets.sorted().map(\.rawValue))" } ?? "gone"
        }
        await held.stop()
        await claim.stop()
        // X's content first: W's job appears only at its commit, which re-routes W1…W3 under K1's copy.
        for (transfer, bytes) in [(xT, xBytes), (wT, wBytes)] {
            await engine.awaitCondition { $0.state.jobs[transfer]?.state == .downloading }
            await engine.waitForHandle(transfer)
            let request = try #require(await source.requests.last { $0.id == transfer })
            let index = try #require(await source.requests.lastIndex { $0.id == transfer })
            try sink.createPartial(request.partialName)
            _ = try sink.appendPartial(bytes, to: request.partialName)
            await source.deliver(index, .staged(StagedFile(name: request.partialName, byteCount: Int64(bytes.count), resumed: false, httpStatus: 200, etag: nil)))
        }
        let kResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: k) }
        var wResults: [Result<AssetLocation, AssetError>] = []
        for waiter in w {
            wResults.append(await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        let xRequests = await source.requests.filter { $0.id == xT }.count
        let wRequests = await source.requests.filter { $0.id == wT }.count
        let observed = "X at the replay \(atReplay), after it \(replayed) (pin epoch \(String(describing: pin.epoch))); X's content requested \(xRequests) times, W's \(wRequests)"
        #expect(Self.sizes([kResult]) == [16] && Self.sizes(wResults) == [20, 20, 20], "K gets O's bytes and W1…W3 W's (visit-first): K \(kResult), W \(Self.sizes(wResults)); \(observed)")
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        let after = await engine.invariantViolations()
        #expect(after.isEmpty, "\(after.prefix(3))")
        await engine.shutdown()
    }
}
