import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch probes (s3f close-out verification, cycle 22, correctness lens, HEAD 9aa337c). Never committed.
///
/// PROBE-C22C-PIN-ENOENT-404: cycle 21's correct #1 (PROBE-C21C-PIN-ENOENT-404) re-run on HEAD with the visit-first
/// answers asserted explicitly, in both orders, owing and not, two rounds: W1…W3 and V2 `failed(notFound)` from X's
/// re-queued attempt's 404, and no request for W's content.
///
/// PROBE-C22C-TS-DRAIN-JOIN: the fixer's cycle-22 residual (1). A transfer's ENOSPC records `Job.transferSpaceEnd`
/// only (no `AttemptEnd.stamped`), so `metInItsAttempt` returns false outside a visit, and the drain's replay inside the
/// ENOSPC's reads of a user join that arrived while T downloaded re-queues T (T20); `decideSpaceFailure` then gives no
/// verdict. `beforeEnd`: V's request for zz-a arrives before T's transfer fails ENOSPC; visit-first it joined T
/// downloading, whose re-lane re-queues nothing, and the ENOSPC's verdict at the cap of one attempt answered A, X and V
/// with the space figures, T started once. `inRead` (the control): V's request arrives inside T's held read; visit-first
/// it met T failed with its verdict to come and re-queued it (T20): A, X and V are served by T's second attempt.
extension EngineFollowBarrierTests {
    // MARK: PROBE-C22C-PIN-ENOENT-404

    struct C22PinRun: Sendable, CustomStringConvertible {
        var owedBatches: [Int] = []
        var pinned = false
        var requeuedAtPinEpoch = false
        var wJobExists = false
        var xIDs: [AssetID] = []
        var wIDs: [AssetID] = []
        var k = ""
        var v2 = ""
        var w: [String] = []
        var wRequests = 0
        var xRequests = 0
        var violations: [String] = []

        var description: String {
            "owed \(self.owedBatches) pinned \(self.pinned) requeued@pin \(self.requeuedAtPinEpoch); after the replay X holds \(self.xIDs.map(\.rawValue)), W holds \(self.wIDs.map(\.rawValue)) (W's job \(self.wJobExists)); K \(self.k); V2 \(self.v2); W1…W3 \(self.w); X requests \(self.xRequests), W requests \(self.wRequests); violations \(self.violations.prefix(2))"
        }
    }

    static func c22Describe(_ result: Result<AssetLocation, AssetError>) -> String {
        switch result {
        case .success(let location):
            return "ok(\(location.byteSize) B)"
        case .failure(let error):
            return "failed(\(error))"
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func c22PinENOENT404(_ visit: LaneDropVisit, owe: Bool) async throws -> C22PinRun {
        var run = C22PinRun()
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
        try await Self.applyHeld(manifest([x] + onX, round: 1), tag: "k0-requeue-c22-\(seed)", setup, visit: visit)
        await engine.readForTests { $0.holdDrainFollowUps() }
        await held.release(oUnit)
        await engine.awaitCondition { $0.state.jobs[oT] == nil }
        run.owedBatches = await engine.readForTests { e in Self.owedBatches(e).map(\.items.count) }
        let k1 = try ValidatedManifest(entries: manifest([x] + onW, round: 2), digest: ContentHash.sha256(of: Data("k1-requeue-c22-\(seed)".utf8)))
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
        // X's fresh attempt fails terminally (a 404); W's job, if one exists, serves W's bytes.
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
        run.k = Self.c22Describe(kResult)
        run.v2 = Self.c22Describe(v2Result)
        run.w = wResults.map(Self.c22Describe)
        run.wRequests = await source.requests.filter { $0.id == wT }.count
        run.xRequests = await source.requests.filter { $0.id == xT }.count
        run.violations += await engine.invariantViolations()
        await engine.shutdown()
        return run
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C22C-PIN-ENOENT-404", .timeLimit(.minutes(10)))
    func probeC22PinENOENT404() async throws {
        var runs: [String: C22PinRun] = [:]
        for round in 1...2 {
            for visit in LaneDropVisit.allCases {
                for owe in [false, true] {
                    let run = try await Self.c22PinENOENT404(visit, owe: owe)
                    print("PROBE-C22C-PIN-ENOENT-404 round \(round) \(visit) owe=\(owe): \(run)")
                    runs["\(visit) owe=\(owe) round \(round)"] = run
                }
            }
        }
        let reference = try #require(runs["\(LaneDropVisit.followVisitedFirst) owe=false round 1"])
        for (key, run) in runs.sorted(by: { $0.key < $1.key }) {
            #expect(run.w == Array(repeating: "failed(notFound)", count: 3), "PROBE-C22C-PIN-ENOENT-404 \(key): W1…W3 get X's re-queued attempt's 404 (visit-first): \(run)")
            #expect(run.v2 == "failed(notFound)", "PROBE-C22C-PIN-ENOENT-404 \(key): V2 gets X's 404 (visit-first): \(run)")
            #expect(run.wRequests == 0, "PROBE-C22C-PIN-ENOENT-404 \(key): W's content is never requested (visit-first): \(run)")
            #expect(run.k == reference.k, "PROBE-C22C-PIN-ENOENT-404 \(key): K as visit-first: \(run.k) vs \(reference.k)")
            #expect(run.violations.isEmpty, "PROBE-C22C-PIN-ENOENT-404 \(key): invariants: \(run.violations.prefix(3))")
            if key.contains("owe=true") {
                #expect(run.owedBatches == [3] && run.pinned && run.requeuedAtPinEpoch, "PROBE-C22C-PIN-ENOENT-404 \(key): setup: the owed batch, K1's pin of X and X's re-queue at the pin's epoch: \(run)")
            }
        }
    }

    // MARK: PROBE-C22C-TS-DRAIN-JOIN

    enum C22TSJoin: String, Sendable, CaseIterable {
        case beforeEnd
        case inRead
    }

    struct C22TSRun: Sendable, CustomStringConvertible {
        var a = ""
        var x = ""
        var v = ""
        var tStarts = 0
        var deferred = false
        var atRead = ""
        var afterDrain = ""
        var drainedInRead = false
        var violations: [String] = []

        var description: String {
            "A \(self.a); X \(self.x); V \(self.v); T starts \(self.tStarts); V's join deferred \(self.deferred); at the held read: \(self.atRead); the drain ran inside the read \(self.drainedInRead), after it: \(self.afterDrain); violations \(self.violations.prefix(2))"
        }
    }

    /// A user request for `entry`'s id: once its join waits behind the barrier (`deferred`), or once it joined the job.
    @available(macOS 15.0, iOS 18.0, *)
    static func c22Join(_ entry: ManifestEntry, _ engine: SyncEngine, deferred: Bool) async -> Task<Result<AssetLocation, AssetError>, Never> {
        let id = entry.identifier
        let transfer = entry.transferID
        let before = await engine.readForTests { e in
            (joins: e.state.joinsAfterFollow.values.filter { $0[id] == transfer }.count, interests: e.state.jobs[transfer]?.interests.count ?? 0)
        }
        let waiter = Task { await engine.awaitAsset(id, lane: .userInitiated) }
        if deferred {
            await engine.awaitCondition { e in e.state.joinsAfterFollow.values.filter { $0[id] == transfer }.count > before.joins }
        } else {
            await engine.awaitCondition { e in (e.state.jobs[transfer]?.interests.count ?? 0) > before.interests }
        }
        return waiter
    }

    static func c22JobLine(_ e: isolated SyncEngine, _ transfer: TransferID) -> String {
        guard let job = e.state.jobs[transfer] else {
            return "gone"
        }
        return "\(job.state) epoch \(job.epoch) transferSpaceEnd \(String(describing: job.transferSpaceEnd)) attemptEnd \(job.attemptEnd != nil) holding \(job.assets.sorted().map(\.rawValue)) interests \(job.interests.count)"
    }

    @available(macOS 15.0, iOS 18.0, *)
    static func c22TransferSpaceDrainJoin(_ visit: LaneDropVisit, join: C22TSJoin, seed: UInt64) async throws -> C22TSRun {
        var run = C22TSRun()
        var interactive = RetryPolicy.interactive
        interactive.maxAttemptsPerRun = 1
        let metadata = SteppedBlockingExecutor(holding: false)
        let (s, _) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: interactive), metadata: metadata)
        let engine = s.engine
        let tBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let a = EngineHarness.onDemand("zz-a", tBytes)
        let x = EngineHarness.onDemand("zz-x", hBytes)
        let xOnT = EngineHarness.onDemand("zz-x", tBytes)
        try #require(xOnT.transferID == a.transferID && x.transferID != a.transferID, "setup: v3 maps zz-x from H to T")
        let tID = a.transferID
        let h = x.transferID
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, x] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(tID, [.hold, .fail(.insufficientSpace(requiredBytes: Int64(tBytes.count))), .stage(tBytes)])
        await s.harness.source.script(h, [.hold, .stage(hBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[tID]?.state == .downloading }
        }
        let xWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[h]?.state == .downloading }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [a, xOnT] + Self.laterFillers(seed + 6_000), tag: "v3-c22-ts-drain-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { e in (h: e.state.jobs[h]?.assets.sorted(), t: e.state.jobs[tID]?.state, owed: e.followOwed) }
            try #require(owed.h == [x.identifier] && owed.t == .downloading && owed.owed, "setup: H's visit is owed while T downloads: \(owed)")
        }
        var vWaiter: Task<Result<AssetLocation, AssetError>, Never>?
        if join == .beforeEnd {
            vWaiter = await Self.c22Join(a, engine, deferred: visit == .sweepFollowsFirst)
            run.deferred = visit == .sweepFollowsFirst
        }
        // T's transfer fails ENOSPC. The store's metadata units are held from here and released as they come until T
        // has failed with its end recorded: the unit held then is one of the ENOSPC's reads.
        await metadata.setHolding(true)
        await s.harness.source.release(tID, with: .progress(received: 0, expected: nil))
        var read: Int?
        while read == nil {
            try await metadata.requireHeldUnits(atLeast: 1)
            let failed = await engine.readForTests { e -> Bool in
                e.state.jobs[tID]?.state.kind == .failed && e.state.jobs[tID]?.transferSpaceEnd != nil
            }
            if failed {
                read = await metadata.heldUnits.first
            } else {
                await metadata.releaseAll()
            }
        }
        let readUnit = try #require(read, "setup: one of T's ENOSPC reads is held at the store")
        let others = Self.releasing(except: [readUnit], metadata)
        run.atRead = await engine.readForTests { e in "T \(Self.c22JobLine(e, tID)); owed \(e.followOwed) barrier \(e.followBarrier) waiting events \(e.state.eventsAfterFollow.count)" }
        if join == .inRead {
            vWaiter = await Self.c22Join(a, engine, deferred: visit == .sweepFollowsFirst)
            run.deferred = visit == .sweepFollowsFirst
        }
        if visit == .sweepFollowsFirst {
            // The follow's remaining turns run while the read is held: H's visit, then the drain's replay of V's join.
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let stillHeld = await metadata.heldUnits.contains(readUnit)
        let barrier = await engine.readForTests { $0.followBarrier }
        run.drainedInRead = stillHeld && !barrier
        run.afterDrain = await engine.readForTests { e in "T \(Self.c22JobLine(e, tID)); H \(Self.c22JobLine(e, h))" }
        others.cancel()
        await others.value
        await metadata.setHolding(false)
        let vTask = try #require(vWaiter)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let xResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: xWaiter) }
        let vResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: vTask) }
        run.a = Self.c22Describe(aResult)
        run.x = Self.c22Describe(xResult)
        run.v = Self.c22Describe(vResult)
        run.tStarts = await s.harness.source.starts.filter { $0.id == tID }.count
        run.violations = await engine.invariantViolations()
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return run
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C22C-TS-DRAIN-JOIN", .timeLimit(.minutes(10)))
    func probeC22TransferSpaceDrainJoin() async throws {
        var runs: [String: C22TSRun] = [:]
        for round in 1...2 {
            for join in C22TSJoin.allCases {
                for visit in LaneDropVisit.allCases {
                    let seed: UInt64 = join == .beforeEnd ? 2_029_101 : 2_029_201
                    let run = try await Self.c22TransferSpaceDrainJoin(visit, join: join, seed: seed)
                    print("PROBE-C22C-TS-DRAIN-JOIN round \(round) \(join) \(visit): \(run)")
                    runs["\(join) \(visit) round \(round)"] = run
                }
            }
        }
        for (key, run) in runs.sorted(by: { $0.key < $1.key }) {
            #expect(run.violations.isEmpty, "PROBE-C22C-TS-DRAIN-JOIN \(key): invariants: \(run.violations.prefix(3))")
            if key.hasPrefix("beforeEnd") {
                #expect(run.a.hasPrefix("failed(insufficientSpace") && run.x == run.a && run.v == run.a && run.tStarts == 1, "PROBE-C22C-TS-DRAIN-JOIN \(key): A, X and V get the ENOSPC's verdict at the cap and T starts once (visit-first): \(run)")
            } else {
                #expect(run.a == "ok(100000 B)" && run.x == run.a && run.v == run.a && run.tStarts == 2, "PROBE-C22C-TS-DRAIN-JOIN \(key): V's request inside the read re-queued T (T20): A, X and V are served by T's second attempt (visit-first): \(run)")
            }
        }
        for join in C22TSJoin.allCases {
            for round in 1...2 {
                let first = try #require(runs["\(join) \(LaneDropVisit.followVisitedFirst) round \(round)"])
                let swept = try #require(runs["\(join) \(LaneDropVisit.sweepFollowsFirst) round \(round)"])
                #expect(first.a == swept.a && first.x == swept.x && first.v == swept.v && first.tStarts == swept.tStarts, "PROBE-C22C-TS-DRAIN-JOIN \(join) round \(round): the same answers in both orders (S3-R16 1(a)): visit-first \(first) / swept first \(swept)")
            }
        }
    }

    // MARK: PROBE-C22C-APPLY-IN-READ (the fixer's cycle-22 residual (2))

    /// T (zz-a, 100 kB) downloads for A and zz-x waits on H (16 bytes, held) for X, both user waiters; T's publication
    /// is held at its first store unit and v3 maps zz-x to T's content (swept first, H's visit is owed). T's placement
    /// rename fails ENOSPC, and its free-space read is held; inside the read v4, which changes only the leading fillers,
    /// is applied, and swept first the follow's remaining turns run before the read returns. Visit-first, v3's visit
    /// joined zz-x to T publishing and v4's visit moves nothing, so the ENOSPC's verdict at the cap of one attempt answers
    /// A and X with the space figures and T starts once.
    @available(macOS 15.0, iOS 18.0, *)
    static func c22ApplyInRead(_ visit: LaneDropVisit, seed: UInt64) async throws -> C22TSRun {
        var run = C22TSRun()
        var interactive = RetryPolicy.interactive
        interactive.maxAttemptsPerRun = 1
        let metadata = SteppedBlockingExecutor(holding: false)
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: interactive), metadata: metadata)
        let engine = s.engine
        let tBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let hBytes = EngineFixture.bytes(seed + 4, count: 16)
        let a = EngineHarness.onDemand("zz-a", tBytes)
        let x = EngineHarness.onDemand("zz-x", hBytes)
        let xOnT = EngineHarness.onDemand("zz-x", tBytes)
        try #require(xOnT.transferID == a.transferID && x.transferID != a.transferID, "setup: v3 maps zz-x from H to T")
        let tID = a.transferID
        let h = x.transferID
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, x] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(tID, [.hold, .stage(tBytes), .stage(tBytes)])
        await s.harness.source.script(h, [.hold, .stage(hBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[tID]?.state == .downloading }
        }
        let xWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[h]?.state == .downloading }
        }
        let releaser = try await Self.holdPublication(of: tID, s, bulk: bulk)
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [a, xOnT] + Self.laterFillers(seed + 6_000), tag: "v3-c22-apply-in-read-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            let owed = await engine.readForTests { e in (h: e.state.jobs[h]?.assets.sorted(), owed: e.followOwed) }
            try #require(owed.h == [x.identifier] && owed.owed, "setup: H's visit is owed while T publishes: \(owed)")
        }
        // T's placement rename fails ENOSPC. The store's metadata units are held from here and released as they come
        // until T's attempt has failed with its end recorded: the unit held then is the free-space read.
        s.fileSystem.addFault(FaultRule(operation: .rename, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .noSpace))
        await metadata.setHolding(true)
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        var read: Int?
        while read == nil {
            try await metadata.requireHeldUnits(atLeast: 1)
            let failed = await engine.readForTests { e -> Bool in
                e.state.jobs[tID]?.state.kind == .failed && e.state.jobs[tID]?.attemptEnd != nil
            }
            if failed {
                read = await metadata.heldUnits.first
            } else {
                await metadata.releaseAll()
            }
        }
        let readUnit = try #require(read, "setup: T's free-space read is held at the store")
        let others = Self.releasing(except: [readUnit], metadata)
        run.atRead = await engine.readForTests { e in "T \(Self.c22JobLine(e, tID)) failedAfter \(String(describing: e.state.jobs[tID]?.attemptEnd?.failedAfter)) applies \(e.state.appliesFollowed); owed \(e.followOwed) barrier \(e.followBarrier)" }
        // v4, which changes only the leading fillers, is applied inside the read.
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 300) + [a, xOnT] + Self.laterFillers(seed + 6_000), tag: "v4-c22-apply-in-read-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let stillHeld = await metadata.heldUnits.contains(readUnit)
        let barrier = await engine.readForTests { $0.followBarrier }
        run.drainedInRead = stillHeld && !barrier
        run.afterDrain = await engine.readForTests { e in "T \(Self.c22JobLine(e, tID)) applies \(e.state.appliesFollowed); H \(Self.c22JobLine(e, h))" }
        others.cancel()
        await others.value
        await metadata.setHolding(false)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let xResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: xWaiter) }
        run.a = Self.c22Describe(aResult)
        run.x = Self.c22Describe(xResult)
        run.v = "-"
        run.tStarts = await s.harness.source.starts.filter { $0.id == tID }.count
        run.violations = await engine.invariantViolations()
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
        return run
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C22C-APPLY-IN-READ", .timeLimit(.minutes(10)))
    func probeC22ApplyInRead() async throws {
        var runs: [String: C22TSRun] = [:]
        for round in 1...2 {
            for visit in LaneDropVisit.allCases {
                let run = try await Self.c22ApplyInRead(visit, seed: 2_029_301)
                print("PROBE-C22C-APPLY-IN-READ round \(round) \(visit): \(run)")
                runs["\(visit) round \(round)"] = run
            }
        }
        for (key, run) in runs.sorted(by: { $0.key < $1.key }) {
            #expect(run.violations.isEmpty, "PROBE-C22C-APPLY-IN-READ \(key): invariants: \(run.violations.prefix(3))")
            #expect(run.a.hasPrefix("failed(insufficientSpace") && run.x == run.a && run.tStarts == 1, "PROBE-C22C-APPLY-IN-READ \(key): A and X get the ENOSPC's verdict at the cap and T starts once (visit-first): \(run)")
        }
    }

    // MARK: PROBE-C22C-SHUTDOWN-BUCKET-RACE (sync run 3's failure of shutdownClearsTheJoinsBehindAVerdict, visited first)

    /// `shutdownClearsTheJoinsBehindAVerdict(.followVisitedFirst)`'s inputs, read where the test shuts the engine down:
    /// O's state and request count after `deferBucketSetUp` and after `deferBucketApplyV4`. `serve`: the same inputs with O's
    /// job let end before the shutdown (the other interleaving), then the answers.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C22C-SHUTDOWN-BUCKET-RACE", .timeLimit(.minutes(5)))
    func probeC22ShutdownBucketRace() async throws {
        for round in 1...2 {
            for serve in [false, true] {
                let b = try await self.deferBucketSetUp(.followVisitedFirst, seed: 2_022_781, ending: .timeout, wanters: .users, members: 10)
                let engine = b.s.engine
                let oT = b.o.transferID
                let afterSetUp = await engine.readForTests { e in e.state.jobs[oT].map { "\($0.state) interests \($0.interests.count)" } ?? "gone" }
                let startsAfterSetUp = await b.s.harness.source.starts.filter { $0.id == oT }.count
                try await self.deferBucketApplyV4(b, .followVisitedFirst)
                let afterV4 = await engine.readForTests { e in e.state.jobs[oT].map { "\($0.state) holding \($0.assets.count) interests \($0.interests.count)" } ?? "gone" }
                let startsAfterV4 = await b.s.harness.source.starts.filter { $0.id == oT }.count
                if serve {
                    await EngineRegressionCycle6Tests.driving([b.s.time], fence: engine) {
                        await engine.awaitCondition { $0.state.jobs[oT] == nil }
                    }
                }
                await engine.shutdown()
                let oWaiter = try #require(b.oWaiter)
                let oAnswer = Self.c22Describe(await oWaiter.value)
                var answers: [String] = []
                for caller in b.callers {
                    answers.append(Self.c22Describe(await caller.value))
                }
                let startsAtEnd = await b.s.harness.source.starts.filter { $0.id == oT }.count
                print("PROBE-C22C-SHUTDOWN-BUCKET-RACE round \(round) serve=\(serve): after the set-up O \(afterSetUp), O requests \(startsAfterSetUp); after v4 O \(afterV4), O requests \(startsAfterV4); at the end O requests \(startsAtEnd); zz-o \(oAnswer); members \(Set(answers)) x\(answers.count)")
                if !serve {
                    #expect(oAnswer == "failed(shutDown)" && answers.allSatisfy { $0 == "failed(shutDown)" }, "the committed test's expectation: \(oAnswer) \(answers)")
                }
                await b.probe.stop()
            }
        }
    }

    /// PROBE-C22C-SHUTDOWN-HELD-RETRY: the committed `shutdownClearsTheJoinsBehindAVerdict` shape with the one change
    /// proposed for its flake, `holdRetry: true`, so O's retry (re-queued by T20 when v4's visit moves the user
    /// waiters onto it) holds at the source until the shutdown. Both orders, three rounds each; answers only.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C22C-SHUTDOWN-HELD-RETRY", .timeLimit(.minutes(5)))
    func probeC22ShutdownHeldRetry() async throws {
        for visit in LaneDropVisit.allCases {
            for round in 1...3 {
                let b = try await self.deferBucketSetUp(visit, seed: 2_022_781, ending: .timeout, wanters: .users, members: 10, holdRetry: true)
                let engine = b.s.engine
                let oT = b.o.transferID
                try await self.deferBucketApplyV4(b, visit)
                let behind = await engine.readForTests { e in e.state.joinsBehindVerdicts.values.reduce(0) { $0 + $1.count } }
                let afterV4 = await engine.readForTests { e in e.state.jobs[oT].map { "\($0.state) interests \($0.interests.count)" } ?? "gone" }
                let starts = await b.s.harness.source.starts.filter { $0.id == oT }.count
                await engine.shutdown()
                let oWaiter = try #require(b.oWaiter)
                let oAnswer = Self.c22Describe(await oWaiter.value)
                var answers: [String] = []
                for caller in b.callers {
                    answers.append(Self.c22Describe(await caller.value))
                }
                print("PROBE-C22C-SHUTDOWN-HELD-RETRY \(visit) round \(round): behind \(behind); after v4 O \(afterV4), O requests \(starts); zz-o \(oAnswer); members \(Set(answers)) x\(answers.count)")
                if visit == .sweepFollowsFirst {
                    #expect(behind > 0, "the committed test's set-up check still holds")
                }
                #expect(oAnswer == "failed(shutDown)" && answers.allSatisfy { $0 == "failed(shutDown)" }, "\(oAnswer) \(answers)")
                await b.probe.stop()
            }
        }
    }
}
