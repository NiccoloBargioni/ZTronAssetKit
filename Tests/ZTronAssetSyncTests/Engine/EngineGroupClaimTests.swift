import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Orchestrator ruling L5-R1 (level 5 close-out; `docs/adr-drafts/g.md` CCR-G2): once `registerGroup` returned
/// `.success` for a group naming id x, and until that group is released, no other group's release, no waiter
/// withdrawal and no caller cancellation retires x's job or cancels its transfer, whether or not x had a job at
/// registration and whether or not that group's join has reached x yet (R-CAR-3, sync-1 S1-05). `registerGroup` answers
/// before the group holds any interest (its join adds them later, after a store read), and a re-lane orders the old
/// handle's release after the successor's registration only, so each test places a release between a registration and
/// that registration's join.
///
/// The two windows of the ruling: (1) the successor is registered while the predecessor's job exists, and the
/// predecessor is released before the successor's join; (2) the predecessor's join creates the job after the
/// successor's registration, and the predecessor is released before the successor's join. A registration and a release
/// made in one engine turn (`inOneTurn`) come before any join of that registration. A join held across turns is
/// spawned by the test (`recordGroup`, then `spawnJoin`): the join's store read is a synchronous `AssetStore` call,
/// which no test-target type can hold, so the test holds the join before it.
@Suite("Engine group claims")
struct EngineGroupClaimTests {
    /// Whether `transfer` is downloading with its handle in place (the fake source recorded its start).
    static func inFlight(_ transfer: TransferID, _ engine: isolated SyncEngine) -> Bool {
        engine.state.jobs[transfer]?.state.kind == .downloading && engine.state.jobs[transfer]?.active?.handle != nil
    }

    /// The starts the fake source recorded for `transfer`.
    @available(macOS 15.0, iOS 18.0, *)
    static func starts(of transfer: TransferID, _ harness: EngineHarness) async -> Int {
        await harness.source.starts.filter { $0.id == transfer }.count
    }

    /// The controls the fake source recorded for `transfer`, in order.
    @available(macOS 15.0, iOS 18.0, *)
    static func controls(of transfer: TransferID, _ harness: EngineHarness) async -> [TransferControl] {
        await harness.source.controlLog.filter { $0.transfer == transfer }.map(\.control)
    }

    /// The claim bookkeeping's sizes: pending claims by content, jobs a claim alone keeps, unlisted claims.
    static func claimCounts(_ engine: isolated SyncEngine) -> (claims: Int, held: Int, unlisted: Int) {
        (engine.state.claims.values.reduce(0, +), engine.state.claimHeld.count, engine.state.unlistedClaims)
    }

    /// A started engine whose manifest lists `entries` on demand; their transfers are unscripted, so a started one
    /// parks in the fake source until the engine cancels it.
    @available(macOS 15.0, iOS 18.0, *)
    static func started(_ entries: [ManifestEntry]) async throws -> EngineHarness {
        let harness = EngineHarness.make()
        try await EngineSingleFlightTests.applied(entries, harness: harness)
        return harness
    }

    /// Window 1: the successor is registered while the predecessor's job exists, and the predecessor is released in the
    /// same turn, before the successor's join. The transfer keeps running, and the successor's join promotes it.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-3: a release that overtakes a successor's join keeps the job the successor named, and its join promotes the running transfer", .timeLimit(.minutes(1)))
    func releaseBeforeSuccessorJoinKeepsTheTransfer() async throws {
        let x = EngineHarness.onDemand("x", EngineFixture.bytes(5_101))
        let harness = try await EngineGroupClaimTests.started([x])
        let engine = harness.engine
        let predecessor = try await engine.registerGroup(["x"], lane: .prefetch).get()
        await engine.awaitCondition { EngineGroupClaimTests.inFlight(x.transferID, $0) }
        let (successor, kept) = await engine.inOneTurn { engine -> (InterestToken?, Bool) in
            let successor = try? engine.performRegisterGroup(["x"], lane: .userInitiated).get()
            engine.performReleaseGroup(predecessor)
            return (successor, engine.state.jobs[x.transferID] != nil)
        }
        let token = try #require(successor)
        #expect(kept, "the predecessor's release left the job the successor named")
        await engine.awaitCondition { $0.state.jobs[x.transferID]?.interests[token] != nil }
        #expect(await EngineGroupClaimTests.starts(of: x.transferID, harness) == 1, "the transfer started once")
        let controls = await EngineGroupClaimTests.controls(of: x.transferID, harness)
        #expect(controls == [.setPriority(.userInitiated)], "the promotion reached the transport as a priority change: \(controls)")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations)")
        await engine.releaseGroup(token)
        await engine.waitForJobEnd(x.transferID)
        await engine.shutdown()
    }

    /// Window 2: both groups are registered in one turn while x has no job, the successor with its join held; the
    /// predecessor's join then creates x's job and starts its transfer, and the predecessor is released before the
    /// successor's join runs. No second start.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-3: a job a predecessor's join creates after a successor's registration survives the predecessor's release until the successor joins", .timeLimit(.minutes(1)))
    func predecessorJoinAfterSuccessorRegistration() async throws {
        let x = EngineHarness.onDemand("x", EngineFixture.bytes(5_111))
        let harness = try await EngineGroupClaimTests.started([x])
        let engine = harness.engine
        let (predecessor, successor, noJob) = await engine.inOneTurn { engine -> (InterestToken?, InterestToken, Bool) in
            let predecessor = try? engine.performRegisterGroup(["x"], lane: .prefetch).get()
            let successor = engine.recordGroup(["x"], lane: .userInitiated).token
            return (predecessor, successor, engine.state.jobs[x.transferID] == nil)
        }
        let first = try #require(predecessor)
        #expect(noJob, "setup: x had no job when the successor registered")
        await engine.awaitCondition { EngineGroupClaimTests.inFlight(x.transferID, $0) }
        await engine.releaseGroup(first)
        #expect(await engine.inOneTurn { $0.state.jobs[x.transferID] != nil }, "the predecessor's release left the job the successor named")
        await engine.inOneTurn { $0.spawnJoin(successor, members: ["x"], lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[x.transferID]?.interests[successor] != nil }
        #expect(await EngineGroupClaimTests.starts(of: x.transferID, harness) == 1, "no second start of the transfer")
        let controls = await EngineGroupClaimTests.controls(of: x.transferID, harness)
        #expect(controls == [.setPriority(.userInitiated)], "the successor's join promoted the running transfer: \(controls)")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations)")
        await engine.releaseGroup(successor)
        await engine.waitForJobEnd(x.transferID)
        await engine.shutdown()
    }

    /// The successor that kept the job is released before its join: that was the last claim on the content, so the job
    /// retires in that turn, and nothing is left once the engine is idle.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-4: releasing the only group that claimed a job before its join retires the job in that turn, and nothing leaks", .timeLimit(.minutes(1)))
    func releaseOfTheOnlyClaimRetiresTheJob() async throws {
        let x = EngineHarness.onDemand("x", EngineFixture.bytes(5_121))
        let harness = try await EngineGroupClaimTests.started([x])
        let engine = harness.engine
        let predecessor = try await engine.registerGroup(["x"], lane: .prefetch).get()
        await engine.awaitCondition { EngineGroupClaimTests.inFlight(x.transferID, $0) }
        let (registered, keptByClaim, retired) = await engine.inOneTurn { engine -> (Bool, Bool, Bool) in
            guard let successor = try? engine.performRegisterGroup(["x"], lane: .userInitiated).get() else {
                return (false, false, false)
            }
            engine.performReleaseGroup(predecessor)
            let kept = engine.state.jobs[x.transferID] != nil
            engine.performReleaseGroup(successor)
            return (true, kept, engine.state.jobs[x.transferID] == nil)
        }
        #expect(registered, "setup: the successor registered")
        #expect(keptByClaim, "the successor's claim kept the job through the predecessor's release")
        #expect(retired, "releasing the last claim retired the job in the same turn")
        await engine.waitUntil { $0.jobsByState.isEmpty && $0.groups == 0 && $0.ownedTasks == 0 }
        let state = await engine.introspect()
        #expect(state.jobsByState.isEmpty && state.groups == 0 && state.interests == 0 && state.ownedTasks == 0, "nothing leaks: \(state)")
        let counts = await engine.inOneTurn { EngineGroupClaimTests.claimCounts($0) }
        #expect(counts == (0, 0, 0), "no claim is left: \(counts)")
        #expect(await EngineGroupClaimTests.starts(of: x.transferID, harness) == 1)
        let controls = await EngineGroupClaimTests.controls(of: x.transferID, harness)
        #expect(controls == [.cancel], "the transfer was cancelled once, by the last release: \(controls)")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations)")
        await engine.shutdown()
    }

    /// The invariant names waiter withdrawals too: a resolve's cancellation, ordered after a registration, leaves the job
    /// that registration named.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-4: a waiter's withdrawal that overtakes a group's join keeps the job the group named", .timeLimit(.minutes(1)))
    func waiterWithdrawalKeepsAClaimedJob() async throws {
        let x = EngineHarness.onDemand("x", EngineFixture.bytes(5_131))
        let harness = try await EngineGroupClaimTests.started([x])
        let engine = harness.engine
        let waiter = Task { await engine.awaitAsset("x", lane: .prefetch) }
        await engine.awaitCondition { EngineGroupClaimTests.inFlight(x.transferID, $0) }
        let (group, kept) = await engine.inOneTurn { engine -> (InterestToken?, Bool) in
            let group = try? engine.performRegisterGroup(["x"], lane: .userInitiated).get()
            if let token = engine.state.waiters.first(where: { $0.value.asset == "x" })?.key {
                // What the waiter's cancellation hop does.
                engine.withdraw(token)
            }
            return (group, engine.state.jobs[x.transferID] != nil)
        }
        let token = try #require(group)
        var answeredCancelled = false
        if case .failure(.cancelled) = await waiter.value {
            answeredCancelled = true
        }
        #expect(answeredCancelled, "the withdrawn caller was answered")
        #expect(kept, "the withdrawal left the job the group named")
        await engine.awaitCondition { $0.state.jobs[x.transferID]?.interests[token] != nil }
        #expect(await EngineGroupClaimTests.starts(of: x.transferID, harness) == 1, "the transfer started once")
        let controls = await EngineGroupClaimTests.controls(of: x.transferID, harness)
        #expect(controls == [.setPriority(.userInitiated)], "\(controls)")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations)")
        await engine.releaseGroup(token)
        await engine.waitForJobEnd(x.transferID)
        await engine.shutdown()
    }

    /// Window 1 when the successor names another id with the same content: the job is the content's, so the claim
    /// keeps it too.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-3: a successor naming another id of the same content keeps the job through the predecessor's release", .timeLimit(.minutes(1)))
    func sharedContentClaimKeepsTheJob() async throws {
        let bytes = EngineFixture.bytes(5_141)
        let x = EngineHarness.onDemand("x", bytes)
        let y = EngineHarness.onDemand("y", bytes)
        #expect(x.transferID == y.transferID, "identical bytes share one transfer (ADR-020)")
        let harness = try await EngineGroupClaimTests.started([x, y])
        let engine = harness.engine
        let predecessor = try await engine.registerGroup(["x"], lane: .prefetch).get()
        await engine.awaitCondition { EngineGroupClaimTests.inFlight(x.transferID, $0) }
        let (successor, kept) = await engine.inOneTurn { engine -> (InterestToken?, Bool) in
            let successor = try? engine.performRegisterGroup(["y"], lane: .userInitiated).get()
            engine.performReleaseGroup(predecessor)
            return (successor, engine.state.jobs[x.transferID] != nil)
        }
        let token = try #require(successor)
        #expect(kept, "the predecessor's release left the job of the content the successor named")
        await engine.awaitCondition { $0.state.jobs[x.transferID]?.interests[token] != nil }
        #expect(await EngineGroupClaimTests.starts(of: x.transferID, harness) == 1, "the content's transfer started once")
        let controls = await EngineGroupClaimTests.controls(of: x.transferID, harness)
        #expect(controls == [.setPriority(.userInitiated)], "\(controls)")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations)")
        await engine.releaseGroup(token)
        await engine.waitForJobEnd(x.transferID)
        await engine.shutdown()
    }

    /// Window 2 for groups registered before `start()`, when the engine's copy of the manifest lists nothing yet (a
    /// prefetch made before start, or the facade's re-registration on a replacement engine): the second lifetime of
    /// one disk, whose store already holds the manifest, registers both groups before starting.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-3: groups registered before start keep the job the successor named through the predecessor's release", .timeLimit(.minutes(1)))
    func claimsRecordedBeforeStart() async throws {
        let x = EngineHarness.onDemand("x", EngineFixture.bytes(5_151))
        let first = try await EngineGroupClaimTests.started([x])
        await first.engine.shutdown()
        let harness = EngineHarness.make(fileSystem: first.fileSystem)
        let engine = harness.engine
        await engine.setOwnedTaskPriorityFloor(EngineHarness.ownedTaskPriorityFloor)
        let (predecessor, successor, listed) = await engine.inOneTurn { engine -> (InterestToken?, InterestToken, Bool) in
            let predecessor = try? engine.performRegisterGroup(["x"], lane: .prefetch).get()
            let successor = engine.recordGroup(["x"], lane: .userInitiated).token
            return (predecessor, successor, engine.state.applied.entry(for: "x") != nil)
        }
        let firstGroup = try #require(predecessor)
        #expect(!listed, "setup: the engine's copy listed nothing when both groups registered")
        #expect(await engine.inOneTurn { EngineGroupClaimTests.claimCounts($0) } == (0, 0, 2), "setup: both members claimed unlisted")
        try await harness.start()
        let claimedAtStart = await engine.inOneTurn { $0.state.unlistedClaims == 0 && $0.state.claims[ClaimKey(x)] != nil }
        #expect(claimedAtStart, "the launch's adoption of the store's manifest claimed the members' content")
        await engine.awaitCondition { EngineGroupClaimTests.inFlight(x.transferID, $0) }
        await engine.releaseGroup(firstGroup)
        #expect(await engine.inOneTurn { $0.state.jobs[x.transferID] != nil }, "the predecessor's release left the job the successor named")
        await engine.inOneTurn { $0.spawnJoin(successor, members: ["x"], lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[x.transferID]?.interests[successor] != nil }
        #expect(await EngineGroupClaimTests.starts(of: x.transferID, harness) == 1, "no second start of the transfer")
        let controls = await EngineGroupClaimTests.controls(of: x.transferID, harness)
        #expect(controls == [.setPriority(.userInitiated)], "\(controls)")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations)")
        await engine.releaseGroup(successor)
        await engine.waitForJobEnd(x.transferID)
        await engine.shutdown()
    }
}

extension EngineGroupClaimTests {
    /// A release of a group holding more pending claims than one turn drops (`SyncEngine.releasesPerTurn`) drops them
    /// over several turns (C2); a job only those claims keep retires once its last claim is dropped, and nothing is left.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-CAR-4: a released group's pending claims are dropped at most releasesPerTurn a turn, and the job they kept then retires", .timeLimit(.minutes(1)))
    func claimsOfALargeGroupAreDroppedOverSeveralTurns() async throws {
        let count = SyncEngine.releasesPerTurn + 88
        let entries = (0..<count).map { EngineHarness.onDemand(String(format: "c%04d", $0), EngineFixture.bytes(UInt64(5_300 + $0), count: 32)) }
        let harness = try await EngineGroupClaimTests.started(entries)
        let engine = harness.engine
        let kept = entries[count - 1]
        let predecessor = try await engine.registerGroup([kept.identifier], lane: .prefetch).get()
        await engine.awaitCondition { EngineGroupClaimTests.inFlight(kept.transferID, $0) }
        let (afterRelease, keptAfterPredecessor) = await engine.inOneTurn { engine -> (Int, Bool) in
            // A successor naming every entry, its join held; the predecessor's release leaves the job to its claim.
            let successor = engine.recordGroup(entries.map(\.identifier), lane: .prefetch).token
            engine.performReleaseGroup(predecessor)
            let kept = engine.state.jobs[kept.transferID] != nil
            engine.performReleaseGroup(successor)
            return (EngineGroupClaimTests.claimCounts(engine).claims, kept)
        }
        #expect(keptAfterPredecessor, "the successor's claim kept the job through the predecessor's release")
        #expect(afterRelease == count - SyncEngine.releasesPerTurn, "the release turn dropped releasesPerTurn claims, got \(count - afterRelease)")
        await engine.waitForJobEnd(kept.transferID)
        await engine.waitUntil { $0.jobsByState.isEmpty && $0.ownedTasks == 0 }
        let counts = await engine.inOneTurn { EngineGroupClaimTests.claimCounts($0) }
        #expect(counts == (0, 0, 0), "every claim was dropped: \(counts)")
        #expect(await EngineGroupClaimTests.controls(of: kept.transferID, harness) == [.cancel], "the kept job retired with its last claim")
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "\(violations)")
        await engine.shutdown()
    }

    /// Shutdown ends every claim, a job a claim alone kept included.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-15: shutdown ends every pending claim", .timeLimit(.minutes(1)))
    func shutdownEndsEveryClaim() async throws {
        let x = EngineHarness.onDemand("x", EngineFixture.bytes(5_161))
        let harness = try await EngineGroupClaimTests.started([x])
        let engine = harness.engine
        let predecessor = try await engine.registerGroup(["x"], lane: .prefetch).get()
        await engine.awaitCondition { EngineGroupClaimTests.inFlight(x.transferID, $0) }
        let before = await engine.inOneTurn { engine -> (claims: Int, held: Int, unlisted: Int) in
            _ = engine.recordGroup(["x", "unlisted"], lane: .userInitiated)
            engine.performReleaseGroup(predecessor)
            return EngineGroupClaimTests.claimCounts(engine)
        }
        #expect(before == (1, 1, 1), "setup: a listed and an unlisted claim, and the job the claim keeps: \(before)")
        await engine.shutdown()
        let after = await engine.inOneTurn { EngineGroupClaimTests.claimCounts($0) }
        #expect(after == (0, 0, 0), "no claim outlives shutdown: \(after)")
        #expect(await engine.introspect().ownedTasks == 0)
    }
}

extension SyncEngine {
    /// Test seam: runs `body` in one engine turn, so what it registers, releases and withdraws all happens before any
    /// owned task it spawned can run.
    func inOneTurn<T: Sendable>(_ body: @Sendable (isolated SyncEngine) -> T) -> T {
        body(self)
    }
}
