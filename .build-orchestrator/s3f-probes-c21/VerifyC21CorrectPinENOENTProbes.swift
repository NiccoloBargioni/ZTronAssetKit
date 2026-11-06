import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch probe (s3f close-out verification, cycle 21, correctness lens). Never committed.
///
/// PROBE-C21C-PIN-ENOENT-404: rr21-T8b's shape (`owedReroutePinnedToARequeuedJobFollowsTheCopy`,
/// `EngineFollowBarrierRerouteRequeueTests.swift`) with X's fresh attempt failing terminally (a 404) where rr21-T8b's
/// commits. The draft lists this as an UNCONFIRMED sibling ("the pin's caller with a terminal failure of the fresh
/// attempt", under "Step 7"): the InboundMove caller's twin, PROBE (ii), broke and was fixed in `58b278e`, but the pin's
/// `waitingTarget(_:epoch:)` was left unchanged.
///
/// `owe == true` is rr21-T8b's own tuning (`followIDsPerTurn = 4`, so O's commit owes W1…W3's re-routes as one batch,
/// K1's layer pins them to X publishing, X's ENOENT re-queues it, and the replay follows K1's copy onto W's content).
/// `owe == false` keeps the default tuning: O's commit fits its turn and re-routes W1…W3 at once under K0's copy onto X
/// publishing, K1's visit passes X, the ENOENT re-queues X with their interests, and X's fresh attempt answers them,
/// which is the visit-first reference RR-21's owing must not change (S3-R20 item 3, S3-R26 item 1). The probe records
/// every waiter's answer in all four cases; it expects W1…W3's answers to be the same with and without owing.
extension EngineFollowBarrierTests {
    struct PinENOENTRun: Sendable, CustomStringConvertible {
        var owedBatches: [Int] = []
        var joinsAfterCommit: [String] = []
        var pinned = false
        var requeuedAtPinEpoch = false
        var wJobExists = false
        var xIDs: [AssetID] = []
        var wIDs: [AssetID] = []
        var k = ""
        var v2 = ""
        var w: [String] = []
        var violations: [String] = []

        var description: String {
            "owed \(self.owedBatches) waiting joins after O's commit \(self.joinsAfterCommit) pinned \(self.pinned) requeued@pin \(self.requeuedAtPinEpoch); after the replay X holds \(self.xIDs.map(\.rawValue)), W holds \(self.wIDs.map(\.rawValue)) (W's job \(self.wJobExists)); K \(self.k); V2 \(self.v2); W1…W3 \(self.w); violations \(self.violations.prefix(2))"
        }
    }

    static func describe(_ result: Result<AssetLocation, AssetError>) -> String {
        switch result {
        case .success(let location):
            return "ok(\(location.byteSize) B)"
        case .failure(let error):
            return "failed(\(error))"
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func pinENOENT404(_ visit: LaneDropVisit, owe: Bool) async throws -> PinENOENTRun {
        var run = PinENOENTRun()
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
        let metadata = SteppedBlockingExecutor(holding: false)
        let harness = EngineHarness.make(time: time, storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60), metadata: metadata, bulk: bulk, fileSystem: fileSystem, remote: source)
        try await harness.start()
        _ = await harness.engine.sync(.force)
        let engine = harness.engine
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        if owe {
            await engine.readForTests { $0.state.followIDsPerTurn = Self.owedIDsPerTurn }
        }
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
        run.owedBatches = await engine.readForTests { e in Self.owedBatches(e).map(\.items.count) }
        run.joinsAfterCommit = await engine.readForTests { e in
            e.state.eventsAfterFollow.compactMap { event -> String? in
                guard case .join(let join) = event, ids.contains(join.asset) else {
                    return nil
                }
                return "\(join.asset.rawValue)->\(join.entry.transferID == xT ? "X" : "?") chain \(join.chain != nil)"
            }
        }
        let k1 = try ValidatedManifest(entries: manifest([x] + onW, round: 2), digest: ContentHash.sha256(of: Data("k1-requeue-\(seed)".utf8)))
        await engine.readForTests { $0.holdFollowFollowUps() }
        let applied = await engine.applyAndFollow(k1, etag: nil, eviction: nil)
        #expect((try? applied.get()) != nil, "setup: K1 is applied: \(applied)")
        let pin = await engine.readForTests { e in (pins: Self.owedBatches(e).first?.layers.map { $0.ends[xT] }, epoch: e.state.jobs[xT]?.epoch) }
        run.pinned = pin.pins == [pin.epoch] && pin.epoch != nil
        await claim.release(xUnit)
        await engine.awaitCondition { $0.state.jobs[xT]?.state == .queued }
        let requeued = await engine.readForTests { e in e.state.jobs[xT]?.epoch }
        run.requeuedAtPinEpoch = requeued == pin.epoch
        while await engine.readForTests({ $0.followOwed || !$0.state.eventsAfterFollow.isEmpty }) {
            _ = await Self.runOneHeldTurn(engine)
            run.violations += await engine.invariantViolations()
        }
        await engine.readForTests { e in
            e.releaseDrainFollowUps()
            e.releaseFollowFollowUps()
        }
        (run.xIDs, run.wIDs, run.wJobExists) = await engine.readForTests { e in (e.state.jobs[xT]?.assets.sorted() ?? [], e.state.jobs[wT]?.assets.sorted() ?? [], e.state.jobs[wT] != nil) }
        await held.stop()
        await claim.stop()
        // X's fresh attempt fails terminally (a 404) where rr21-T8b's commits; W's job, if one exists, serves W's bytes.
        await engine.awaitCondition { $0.state.jobs[xT]?.state == .downloading }
        await engine.waitForHandle(xT)
        let xIndex2 = try #require(await source.requests.lastIndex { $0.id == xT })
        await source.deliver(xIndex2, .failed(.permanentMissing(httpStatus: 404)))
        if run.wJobExists {
            await engine.awaitCondition { $0.state.jobs[wT]?.state == .downloading }
            await engine.waitForHandle(wT)
            let request = try #require(await source.requests.last { $0.id == wT })
            let index = try #require(await source.requests.lastIndex { $0.id == wT })
            try sink.createPartial(request.partialName)
            _ = try sink.appendPartial(wBytes, to: request.partialName)
            await source.deliver(index, .staged(StagedFile(name: request.partialName, byteCount: Int64(wBytes.count), resumed: false, httpStatus: 200, etag: nil)))
        }
        let kResult = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: k) }
        let v2Result = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: v2) }
        var wResults: [Result<AssetLocation, AssetError>] = []
        for waiter in w {
            wResults.append(await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: waiter) })
        }
        run.k = Self.describe(kResult)
        run.v2 = Self.describe(v2Result)
        run.w = wResults.map(Self.describe)
        run.violations += await engine.invariantViolations()
        await engine.shutdown()
        return run
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C21C-PIN-ENOENT-404", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func probePinENOENT404(_ visit: LaneDropVisit) async throws {
        var reference = PinENOENTRun()
        var owed = PinENOENTRun()
        for round in 1...2 {
            reference = try await Self.pinENOENT404(visit, owe: false)
            print("PROBE-C21C-PIN-ENOENT-404 \(visit) round \(round) owe=false (the commit re-routes at once): \(reference)")
            owed = try await Self.pinENOENT404(visit, owe: true)
            print("PROBE-C21C-PIN-ENOENT-404 \(visit) round \(round) owe=true (rr21-T8b's tuning, the commit owes): \(owed)")
        }
        #expect(reference.owedBatches.isEmpty, "setup: without the low budget the commit owes nothing: \(reference)")
        #expect(owed.owedBatches == [3] && owed.pinned && owed.requeuedAtPinEpoch, "setup: rr21-T8b's owed batch, K1's pin of X and X's re-queue at the pin's epoch: \(owed)")
        #expect(reference.violations.isEmpty && owed.violations.isEmpty, "invariants: \(reference.violations.prefix(2)) \(owed.violations.prefix(2))")
        #expect(owed.k == reference.k && owed.v2 == reference.v2, "K and V2 the same with and without owing: \(owed.k) \(owed.v2) vs \(reference.k) \(reference.v2)")
        #expect(owed.w == reference.w, "PROBE-C21C-PIN-ENOENT-404 \(visit): W1…W3 answered the same whether O's commit owes their re-routes (\(owed.w)) or makes them at once (\(reference.w))")
    }
}
