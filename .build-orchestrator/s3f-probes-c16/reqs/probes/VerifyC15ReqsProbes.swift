import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch probes (s3f close-out verification, cycle 15, requirements lens). Never committed. Each runs in both orders
/// (`LaneDropVisit`) and expects the visit-first outcome.
extension EngineFollowBarrierTests {
    /// PROBE-C15R-REROUTE-STALE. `Job.rerouteOnPass` is never cleared once the visit re-routed its ids. C (100 kB) is
    /// the content of zz-a and zz-b (a user waiter each); C's bytes fail their checksum. v3 moves zz-b to N (16 B, held).
    /// C's publication begins (held) while v3's follow is owed (sweep-first) or after it (visit-first). v4 maps zz-b back
    /// to C's content while C still publishes: N's visit supersedes N and B's interest joins C. v5 moves zz-b to N2
    /// (24 B) while the same publication still verifies. Visit-first, v5's follow passed C (publishing), so B rides C's
    /// outcome: `integrityFailure`. Sweep-first, v5's visit finds zz-b in the stale `rerouteOnPass` and re-routes it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C15R-REROUTE-STALE", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func probeC15RRerouteStale(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_515_002
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let n2Bytes = EngineFixture.bytes(seed + 6, count: 24)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        let bMoved2 = EngineHarness.onDemand("zz-b", n2Bytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong)])
        await s.harness.source.script(bMoved.transferID, [.hold, .stage(nBytes)])
        await s.harness.source.script(bMoved2.transferID, [.stage(n2Bytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        try await Self.applyHeld([s.q] + fillers + [a, bMoved] + later, tag: "v3-stale-\(seed)", s, visit: visit)
        let releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        await engine.awaitCondition { $0.state.jobs[bMoved.transferID]?.state == .downloading }
        let atV3 = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, cAssets: e.state.jobs[a.transferID]?.assets.sorted(), reroute: e.state.jobs[a.transferID]?.rerouteOnPass?.sorted(), n: e.state.jobs[bMoved.transferID]?.state)
        }
        print("PROBE-C15R-REROUTE-STALE \(visit) after v3: \(atV3)")
        try #require(atV3.c == .verifying && atV3.cAssets == [a.identifier], "setup: C publishes with zz-a only, B on N: \(atV3)")
        // v4 maps zz-b back to C's content while C publishes: N's visit supersedes N, and B's interest joins C.
        try await Self.applyHeld([s.q] + fillers + [a, b] + later, tag: "v4-stale-\(seed)", s, visit: .followVisitedFirst)
        let atV4 = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, cAssets: e.state.jobs[a.transferID]?.assets.sorted(), interests: e.state.jobs[a.transferID]?.interests.count, n: e.state.jobs[bMoved.transferID]?.state)
        }
        print("PROBE-C15R-REROUTE-STALE \(visit) after v4: \(atV4)")
        try #require(atV4.c == .verifying && atV4.cAssets == [a.identifier, b.identifier], "setup: B rejoined C, which still publishes: \(atV4)")
        // v5 moves zz-b to N2 while the same publication still verifies.
        try await Self.applyHeld([s.q] + fillers + [a, bMoved2] + later, tag: "v5-stale-\(seed)", s, visit: .followVisitedFirst)
        let atV5 = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, cAssets: e.state.jobs[a.transferID]?.assets.sorted(), n2: e.state.jobs[bMoved2.transferID]?.state)
        }
        print("PROBE-C15R-REROUTE-STALE \(visit) after v5: \(atV5)")
        try #require(atV5.c == .verifying, "setup: the same publication still verifies at v5: \(atV5)")
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("PROBE-C15R-REROUTE-STALE \(visit) a=\(aResult) b=\(bResult)")
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "PROBE-C15R-REROUTE-STALE: B gets C's integrity failure: v5's follow passed C, publishing (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
    }

    /// PROBE-C15R-VERDICT-LATER-APPLY (the cycle-15 draft's "Put to the orchestrator: a verdict that waits across a
    /// later apply", unprobed there). C (100 kB) downloads for A (zz-a) and B (zz-b), both users. v3 changes only the
    /// fillers. C gets a 404 while v3's follow is owed (sweep-first: its verdict waits). Then v4 moves zz-b to N (16 B)
    /// while v3's follow still owes its visits. Visit-first, the 404 answered A and B `notFound` before v4 existed.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C15R-VERDICT-LATER-APPLY", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func probeC15RVerdictLaterApply(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_515_302
        let (s, _) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(cBytes)])
        await s.harness.source.script(bMoved.transferID, [.stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        try await Self.applyHeld([s.q] + fillers + [a, b] + later, tag: "v3-verdict-\(seed)", s, visit: visit)
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        if visit == .sweepFollowsFirst {
            // c16 adaptation (a wait only): the 404 transitions before its store awaits (`sparePresent`, `recordFailure`)
            // and defers its verdict after them, so the cycle-15 wait could read inside that window (c16 run 1).
            await engine.awaitCondition { $0.state.verdictsAfterFollow[a.transferID] != nil }
        } else {
            await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        }
        let atFail = await engine.readForTests { e in
            (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, verdict: e.state.verdictsAfterFollow[a.transferID])
        }
        print("PROBE-C15R-VERDICT-LATER-APPLY \(visit) after the 404: \(atFail)")
        if visit == .sweepFollowsFirst {
            try #require(atFail.owed && atFail.verdict != nil, "setup: the 404's verdict waits for v3's follow: \(atFail)")
        }
        // v4 moves zz-b while (sweep-first) v3's follow still owes its visits.
        try await Self.applyHeld([s.q] + fillers + [a, bMoved] + later, tag: "v4-verdict-\(seed)", s, visit: visit)
        if visit == .sweepFollowsFirst {
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("PROBE-C15R-VERDICT-LATER-APPLY \(visit) a=\(aResult) b=\(bResult)")
        #expect(aResult == .failure(.notFound), "A gets C's 404 (visit-first): \(aResult)")
        #expect(bResult == .failure(.notFound), "PROBE-C15R-VERDICT-LATER-APPLY: B gets C's 404, answered before v4 existed (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
    }
    /// PROBE-C15R-SPACE-EPOCH (the surviving mutant `spaceFailureEpochDropped`; the draft says it "only writes its
    /// lastError"). C (1 MB) is zz-a's content; v3 moves zz-a to N (16 B) and maps zz-x onto C's content. While v3's follow
    /// is owed (300 prefetch members before zz-a keep C's visit owed past the ENOSPC read's own follow turn), a user asks
    /// for zz-x (the join waits), then C's attempt fails ENOSPC reporting 20 MB with 5 MB of room (the verdict waits). The
    /// follow's visit supersedes C, the drain's join creates a new job C' for C's content, and the `.spaceFailure` replay
    /// must skip it. Visited first, C was superseded at the apply, C' started for zz-x and served it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C15R-SPACE-EPOCH", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func probeC15RSpaceEpoch(_ visit: LaneDropVisit) async throws {
        let (s, _) = try await FollowBarrier.setUp(seed: 1_515_602)
        let engine = s.engine
        let cBytes = Data(repeating: 0xA7, count: 1_000_000)
        let xBytes = EngineFixture.bytes(1_515_603, count: 40)
        let nBytes = EngineFixture.bytes(1_515_604, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let aMoved = EngineHarness.onDemand("zz-a", nBytes)
        let xMoved = EngineHarness.onDemand("zz-x", cBytes)
        try #require(xMoved.transferID == a.transferID, "setup: v3's zz-x is C's content")
        let members = (0..<300).map { EngineHarness.onDemand(String(format: "g%03d", $0), EngineFixture.bytes(1_515_700 + UInt64($0), count: 16)) }
        let movedMembers = (0..<300).map { EngineHarness.onDemand(String(format: "g%03d", $0), EngineFixture.bytes(1_516_100 + UInt64($0), count: 16)) }
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(1_516_500) + members + [a, x], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(aMoved.transferID, [.stage(nBytes)])
        for entry in members + movedMembers {
            await s.harness.source.script(entry.transferID, [.hold])
        }
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading }
        let group = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { current in members.allSatisfy { current.state.jobs[$0.transferID] != nil } }
        let sync = await FollowBarrier.apply([s.q] + FollowBarrier.fillers(1_516_900) + movedMembers + [aMoved, xMoved], s, visit: visit)
        let xWaiter = Task { await engine.awaitAsset(x.identifier, lane: .userInitiated) }
        if visit == .sweepFollowsFirst {
            await engine.awaitCondition { FollowBarrier.joinWaits($0, xMoved) }
            let before = await engine.readForTests { e in (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, found: e.state.unfollowed.contains(a.transferID)) }
            print("PROBE-C15R-SPACE-EPOCH \(visit) before the ENOSPC: \(before)")
            try await Self.leaveRoom(5_000_000, harness: s.harness, fileSystem: s.fileSystem)
            await s.harness.source.release(a.transferID, with: .failed(.insufficientSpace(requiredBytes: 20_000_000)))
            await engine.awaitCondition { e in
                e.state.eventsAfterFollow.contains { if case .spaceFailure = $0 { return true }; return false } || e.state.jobs[a.transferID]?.state != .downloading && !e.followBarrier
            }
            let waits = await engine.readForTests { e in
                (waits: e.state.eventsAfterFollow.contains { if case .spaceFailure = $0 { return true }; return false }, c: e.state.jobs[a.transferID]?.state, epoch: e.state.jobs[a.transferID]?.epoch)
            }
            print("PROBE-C15R-SPACE-EPOCH \(visit) after the ENOSPC: \(waits)")
            // The ENOSPC read's space sweep drives the follow by its own follow-up turns (`advanceFollowForSpaceSweep`), so the
            // drain may already have run here; the mutant's difference shows the stale-epoch replay was reached.
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        } else {
            try await Self.leaveRoom(5_000_000, harness: s.harness, fileSystem: s.fileSystem)
        }
        let after = await engine.readForTests { e in (c: e.state.jobs[a.transferID]?.state, lastError: e.state.jobs[a.transferID]?.lastError) }
        print("PROBE-C15R-SPACE-EPOCH \(visit) after the drain: \(after)")
        let xResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: xWaiter) }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        print("PROBE-C15R-SPACE-EPOCH \(visit) x=\(xResult) a=\(aResult)")
        #expect((try? xResult.get())?.byteSize == Int64(cBytes.count), "PROBE-C15R-SPACE-EPOCH: zz-x's caller is served C's content by a new job (visit-first): \(xResult)")
        #expect((try? aResult.get())?.byteSize == 16, "A is served N (visit-first): \(aResult)")
        await engine.releaseGroup(group)
        await FollowBarrier.finish(s, sync: sync)
    }
    /// PROBE-C15R-AWAIT-WINDOW (the cycle-15 draft's "Put to the orchestrator: the publication failure's await window",
    /// unprobed there). C (100 kB, zz-a and zz-b, a user waiter each) publishes bytes that fail their checksum; its
    /// publication begins before v3's apply, which moves zz-b to N (16 B). Visited first, the follow passed C (publishing)
    /// and the failure answered both users `integrityFailure`. Behind the barrier, C's bytes fail before the follow's turn
    /// that finds C, and that turn runs while `integrityFailed` awaits the store (its bulk units held): the job is failed
    /// with no waiting verdict yet, so the visit moves zz-b as a download's.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C15R-AWAIT-WINDOW", .timeLimit(.minutes(3)), arguments: LaneDropVisit.allCases)
    func probeC15RAwaitWindow(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_515_902
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        try #require(a.transferID == b.transferID, "setup: zz-a and zz-b share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong)])
        await s.harness.source.script(bMoved.transferID, [.stage(nBytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 2 }
        // C's publication is held at its first store unit before the apply.
        await engine.awaitCondition { !$0.state.storeWorkInFlight }
        await bulk.setHolding(true)
        await s.harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .verifying }
        try await bulk.requireHeldUnits(atLeast: 1)
        let unit = try #require(await bulk.heldUnits.first)
        let releaser = Task {
            while !Task.isCancelled {
                await bulk.waitForHeldUnits(atLeast: 2)
                for other in await bulk.heldUnits where other != unit {
                    await bulk.release(other)
                }
            }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + [a, bMoved] + Self.laterFillers(seed + 6_000), tag: "v3-window-\(seed)", s, visit: visit)
        releaser.cancel()
        await releaser.value
        if visit == .sweepFollowsFirst {
            // C's verification runs and fails; the units of the failure's bookkeeping stay held.
            await bulk.release(unit)
            await engine.awaitCondition { e in
                if case .failed? = e.state.jobs[a.transferID]?.state { return true }
                return false
            }
            let held = await bulk.heldUnits.count
            let window = await engine.readForTests { e in
                (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, verdict: e.state.verdictsAfterFollow[a.transferID], holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true)
            }
            print("PROBE-C15R-AWAIT-WINDOW \(visit) in the window: \(window) heldUnits=\(held)")
            await Self.runOneFollowTurn(engine)
            let afterTurn = await engine.readForTests { e in
                (owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, verdict: e.state.verdictsAfterFollow[a.transferID], holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, visited: !e.state.followOrder[e.state.followNext...].contains(a.transferID))
            }
            print("PROBE-C15R-AWAIT-WINDOW \(visit) after the turn that finds C: \(afterTurn)")
            await bulk.setHolding(false)
            await bulk.releaseAll()
            await engine.readForTests { $0.releaseFollowFollowUps() }
        } else {
            await bulk.setHolding(false)
            await bulk.releaseAll()
        }
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        print("PROBE-C15R-AWAIT-WINDOW \(visit) a=\(aResult) b=\(bResult)")
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(bResult == .failure(.integrityFailure), "PROBE-C15R-AWAIT-WINDOW: B gets C's integrity failure: the follow passed C, publishing at the apply (visit-first): \(bResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
    }

    /// PROBE-C15R-RETRY-RACE: `barrierAnswersAPassedJobsRetryAsVisitedFirst` with N's publication made to run after the
    /// test adds its `.verifying` read fault (N held until then), the order the TSan run's time-out suggests.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C15R-RETRY-RACE", .timeLimit(.minutes(1)), arguments: LaneDropVisit.allCases)
    func probeC15RRetryRace(_ visit: LaneDropVisit) async throws {
        let seed: UInt64 = 1_317_002
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed)
        let engine = s.engine
        let cBytes = EngineFixture.bytes(seed + 3, count: 100_000)
        let wrong = EngineFixture.bytes(seed + 4, count: 100_000)
        let nBytes = EngineFixture.bytes(seed + 5, count: 16)
        let n2Bytes = EngineFixture.bytes(seed + 6, count: 24)
        let a = EngineHarness.onDemand("zz-a", cBytes)
        let b = EngineHarness.onDemand("zz-b", cBytes)
        let c = EngineHarness.onDemand("zz-c", cBytes)
        let bMoved = EngineHarness.onDemand("zz-b", nBytes)
        let cMoved = EngineHarness.onDemand("zz-c", n2Bytes)
        try #require(a.transferID == b.transferID && a.transferID == c.transferID, "setup: zz-a, zz-b and zz-c share C")
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + [a, b, c] + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        await s.harness.source.script(a.transferID, [.hold, .stage(cBytes)])
        await s.harness.source.script(bMoved.transferID, visit == .sweepFollowsFirst ? [.hold, .stage(nBytes)] : [.stage(nBytes)])
        await s.harness.source.script(cMoved.transferID, [.stage(n2Bytes)])
        let aWaiter = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.conditions != nil && $0.state.jobs[a.transferID]?.state == .downloading }
        }
        let bWaiter = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        let cWaiter = Task { await engine.awaitAsset(c.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.interests.count == 3 }
        let fillers = FollowBarrier.fillers(seed + 200)
        let later = Self.laterFillers(seed + 6_000)
        try await Self.applyHeld([s.q] + fillers + [a, bMoved, c] + later, tag: "v3-retry-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            // Visited first, C's visit moved B onto N at the apply; N is served before C's bytes arrive.
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[bMoved.transferID] == nil }
            }
        }
        var releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        if visit == .sweepFollowsFirst {
            await Self.runOneFollowTurn(engine)
            let passed = await engine.readForTests { e in
                (
                    owed: e.followOwed, c: e.state.jobs[a.transferID]?.state, visited: !e.state.followOrder[e.state.followNext...].contains(a.transferID),
                    holdsB: e.state.jobs[a.transferID]?.assets.contains(b.identifier) == true, unfollowed: e.state.unfollowed.contains(a.transferID)
                )
            }
            // C's publication began after the apply: the visit re-routed its moved id at once (S3-R18 item 2).
            #expect(passed.owed && passed.c == .verifying && passed.visited && !passed.holdsB && !passed.unfollowed, "setup: the follow's second turn visited C while it verified and stays owed: \(passed)")
            await engine.readForTests { $0.releaseFollowFollowUps() }
            await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        }
        releaser.cancel()
        await releaser.value
        // The held unit is the first chunk of C's hash: its read of the claimed staging file fails, and C is retried.
        var nUnit: Int?
        if visit == .sweepFollowsFirst {
            // N's bytes arrive after the releaser stopped: its publication's first unit is held beside C's.
            await engine.awaitCondition { $0.state.jobs[bMoved.transferID]?.state == .downloading }
            let before = await bulk.heldUnits
            await s.harness.source.release(bMoved.transferID, with: .progress(received: 0, expected: nil))
            try await bulk.requireHeldUnits(atLeast: before.count + 1)
            nUnit = await bulk.heldUnits.first { !before.contains($0) }
            print("PROBE-C15R-RETRY-RACE held before=\(before) n=\(String(describing: nUnit))")
        }
        s.fileSystem.addFault(FaultRule(operation: .read, matching: URLMatcher(lastComponentSuffix: ".verifying"), occurrence: .nth(1), error: .io))
        await s.harness.source.script(a.transferID, [.hold, .stage(wrong)])
        if let nUnit {
            // N's verification read runs first, as `setHolding(false)` lets both run at once.
            await bulk.release(nUnit)
            await engine.awaitCondition { $0.state.jobs[bMoved.transferID]?.state != .verifying }
            let n = await engine.readForTests { e in (n: e.state.jobs[bMoved.transferID]?.state, attempts: e.state.jobs[bMoved.transferID]?.attempts) }
            print("PROBE-C15R-RETRY-RACE after N's read: \(n)")
        }
        await bulk.setHolding(false)
        let bResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: bWaiter) }
        #expect((try? bResult.get())?.byteSize == 16, "B is served N, the content v3 maps zz-b to (visit-first): \(bResult)")
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading && $0.state.jobs[a.transferID]?.attempts == 1 }
        }
        // C's retry publishes; v4 moves zz-c while that publication, begun before v4's apply, verifies.
        releaser = try await Self.holdPublication(of: a.transferID, s, bulk: bulk)
        try await Self.applyHeld([s.q] + fillers + [a, bMoved, cMoved] + later, tag: "v4-retry-\(seed)", s, visit: .followVisitedFirst)
        let passedAgain = await engine.readForTests { e in
            (c: e.state.jobs[a.transferID]?.state, holdsC: e.state.jobs[a.transferID]?.assets.contains(c.identifier) == true, unfollowed: e.state.unfollowed.contains(a.transferID))
        }
        #expect(passedAgain.c == .verifying && passedAgain.holdsC && passedAgain.unfollowed, "setup: v4's follow passed C's second publication, begun before its apply: \(passedAgain)")
        releaser.cancel()
        await releaser.value
        await bulk.setHolding(false)
        let aResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: aWaiter) }
        let cResult = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await EngineHarness.value(of: cWaiter) }
        #expect(aResult == .failure(.integrityFailure), "A gets C's integrity failure (visit-first): \(aResult)")
        #expect(cResult == .failure(.integrityFailure), "zz-c's user gets C's integrity failure: v4's follow passed C publishing, in both orders (visit-first): \(cResult)")
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        await Self.finishHeld(s)
    }
}
