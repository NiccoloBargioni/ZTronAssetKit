import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The shared setup of the take-off tests (Stage 3 close-out cycle 21, ruling S3-R26 item 1; `integrate-rr21.md` R6 and
/// R7, site 2): content O<c> (16 bytes) holds zz-c<c>k, which it keeps, and zz-c<c>m00…, which v3 maps to N (24 bytes)
/// and v4 maps back, each with a user waiter. O<c>'s attempt ends while v3's follow is owed, so its verdict waits with
/// those ids among the ones a visit-first engine's visits had moved off it before the verdict arrived
/// (`AttemptEnd.movedBefore`), and v4 maps them back before the follow visits it: the drain takes them off before the
/// verdict and re-routes them after it, at once when they fit the drain turn's ids left (`EngineState.drainIDsLeft`),
/// else owed as one batch. Visited first, v3's visit moved them onto N, the verdict was given at its arrival, and v4's
/// visit moved them from N to O<c>'s content: the job the verdict left, or a fresh one. The moved-before state arises
/// swept first only: visited first, `applyHeld` ends every follow at its apply (`EngineFollowBarrierReachTests.swift`),
/// so no verdict waits, which `takeOffSetUp` pins (ruling S3-R26 item 12's answer 1).
extension EngineFollowBarrierTests {
    /// The ids a turn moves in the take-off tests (`EngineState.followIDsPerTurn`): a drain turn's ids are 4.
    static let takeOffIDsPerTurn = 4

    /// How each content's attempt ends.
    enum TakeOffEnding: String, Sendable, CaseIterable {
        /// A 404, replayed as `.attemptFailed`: the verdict ends the job, and the moved-back ids join a fresh job of its
        /// content.
        case notFound
        /// A timeout below the interactive cap, replayed as `.attemptFailed`: the verdict backs the job off, and the
        /// moved-back ids join it again.
        case timeout
        /// An ENOSPC for 200 kB the volume has room for, replayed as `.spaceFailure`: the verdict backs the job off
        /// (`decideSpaceFailure`), and the moved-back ids join it again.
        case spaceRetry
    }

    /// The shape of a take-off scenario (`takeOffSetUp`).
    struct TakeOffShape: Sendable {
        /// How each content's attempt ends.
        var ending: TakeOffEnding
        /// The contents O0…, each with a waiting verdict, in the order their attempts end.
        var contents = 1
        /// The ids of each content that v3 maps to N and v4 maps back.
        var moved = 10
        /// The ids of O0's content (zz-c0p00…) that v4 maps to P (20 bytes) once the verdicts wait: the drain's visit after
        /// O0's verdict moves them (`followAfterVerdict`).
        var after = 0
        /// A prefetch group of zz-c0k and zz-c0m00: an interest the take-off leaves holding its other id.
        var partial = false
        /// The moved id of O0 whose waiter is cancelled once the verdicts wait: its removal waits behind them.
        var removal: Int?
        /// Whether the kept ids have user waiters: without them O0 holds moved-before interests only, and a pending claim
        /// on its content (a recorded prefetch group of zz-c0k, `recordGroup`) keeps it once they are taken off.
        var keptWaiters = true
        /// The lane of each moved id's waiter of O0, by index (`.userInitiated` for every one without).
        var lanes: [AssetPriority]?
        /// The members zz-h000… of one prefetch group on H (18 bytes), which v4 maps to O0's content: H's visit's joins onto
        /// O0 wait behind O0's verdict, in its bucket (`joinsBehindVerdicts`).
        var bucket = 0
        /// The ids a turn moves (`EngineState.followIDsPerTurn`).
        var idsPerTurn = EngineFollowBarrierTests.takeOffIDsPerTurn
    }

    /// The ids and transfers a take-off scenario's readings need (`takeOffTurn`).
    struct TakeOffIDs: Sendable {
        /// O0…'s transfers.
        let contents: [TransferID]
        /// Every content's moved ids.
        let moved: Set<AssetID>
        /// O0's ids that v4 maps to P, and P's transfer.
        let after: Set<AssetID>
        let p: TransferID
        /// The cancelled waiter's id (`TakeOffShape.removal`).
        let removal: AssetID?
    }

    /// A take-off scenario's engine, entries and callers (`takeOffSetUp`).
    @available(macOS 15.0, iOS 18.0, *)
    struct TakeOff {
        let s: FollowBarrier.Setup
        let shape: TakeOffShape
        let seed: UInt64
        let ids: TakeOffIDs
        /// zz-c<c>k, per content.
        let kept: [ManifestEntry]
        /// zz-c<c>m…, per content, on O<c>'s content, and on N.
        let moved: [[ManifestEntry]]
        let movedOnN: [[ManifestEntry]]
        /// zz-c0p…, on O0's content, and on P.
        let after: [ManifestEntry]
        let afterOnP: [ManifestEntry]
        /// The bucket's members on H, and on O0's content (`bucket`), and their group.
        let members: [ManifestEntry]
        let membersOnO: [ManifestEntry]
        let bucketGroup: InterestToken?
        /// zz-x (22 bytes), listed in every manifest: a test that requests it once v4 is applied makes a join that waits at
        /// the queue's tail.
        let x: ManifestEntry
        /// The kept ids' waiters, per content (`keptWaiters`).
        let keptCallers: [Task<Result<AssetLocation, AssetError>, Never>]
        /// The moved ids' waiters, per content, in index order.
        let movedCallers: [[Task<Result<AssetLocation, AssetError>, Never>]]
        /// The `after` ids' waiters.
        let afterCallers: [Task<Result<AssetLocation, AssetError>, Never>]
        /// The prefetch group of zz-c0k and zz-c0m00 (`partial`).
        let group: InterestToken?
        /// The recorded group whose pending claim keeps O0 (`keptWaiters == false`).
        let claim: InterestToken?

        var engine: SyncEngine {
            self.s.engine
        }

        /// v4: every content's ids on their own content, the `after` ids on P.
        var v4: [ManifestEntry] {
            [self.s.q] + FollowBarrier.fillers(self.seed + 300) + EngineFollowBarrierTests.takeOffFillers(self.seed + 20_000) + self.kept + self.moved.flatMap { $0 } + self.afterOnP + self.membersOnO + [self.x] + EngineFollowBarrierTests.laterFillers(self.seed + 9_000)
        }
    }

    /// Changed on-demand entries without jobs that sort between `FollowBarrier.fillers` and the scenario's `zz-` ids: an
    /// ENOSPC's free-space read runs one follow turn (`advanceFollowForSpaceSweep`), which, with these, still stops before
    /// the scenario's jobs, so their visits stay owed.
    @available(macOS 15.0, iOS 18.0, *)
    static func takeOffFillers(_ seed: UInt64) -> [ManifestEntry] {
        (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "g%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
    }

    /// The scenario up to v4: O<c> downloads (held) for its waiters, v3 maps the moved ids to N, each O<c>'s attempt ends
    /// (its verdict waits swept first, and is given visited first), and the cancelled waiter (`removal`) withdraws. Swept
    /// first, it requires each verdict to wait with exactly its content's moved ids moved before it.
    @available(macOS 15.0, iOS 18.0, *)
    func takeOffSetUp(_ visit: LaneDropVisit, seed: UInt64, shape: TakeOffShape) async throws -> TakeOff {
        let (s, _) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry))
        let engine = s.engine
        let idsPerTurn = shape.idsPerTurn
        await engine.readForTests { $0.state.followIDsPerTurn = idsPerTurn }
        let oBytes = (0..<shape.contents).map { EngineFixture.bytes(seed + 10 + UInt64($0), count: 16) }
        let nBytes = EngineFixture.bytes(seed + 5, count: 24)
        let pBytes = EngineFixture.bytes(seed + 7, count: 20)
        let kept = (0..<shape.contents).map { EngineHarness.onDemand("zz-c\($0)k", oBytes[$0]) }
        let movedNames = (0..<shape.contents).map { c in (0..<shape.moved).map { String(format: "zz-c%dm%02d", c, $0) } }
        let moved = (0..<shape.contents).map { c in movedNames[c].map { EngineHarness.onDemand($0, oBytes[c]) } }
        let movedOnN = movedNames.map { names in names.map { EngineHarness.onDemand($0, nBytes) } }
        let afterNames = (0..<shape.after).map { String(format: "zz-c0p%02d", $0) }
        let after = afterNames.map { EngineHarness.onDemand($0, oBytes[0]) }
        let afterOnP = afterNames.map { EngineHarness.onDemand($0, pBytes) }
        let hBytes = EngineFixture.bytes(seed + 8, count: 18)
        let xBytes = EngineFixture.bytes(seed + 9, count: 22)
        let memberNames = (0..<shape.bucket).map { String(format: "zz-h%03d", $0) }
        let members = memberNames.map { EngineHarness.onDemand($0, hBytes) }
        let membersOnO = memberNames.map { EngineHarness.onDemand($0, oBytes[0]) }
        let x = EngineHarness.onDemand("zz-x", xBytes)
        let h = EngineHarness.onDemand("zz-h", hBytes).transferID
        let contents = kept.map(\.transferID)
        let n = try #require(movedOnN.first?.first).transferID
        let p = EngineHarness.onDemand("zz-p", pBytes).transferID
        try #require(Set(contents + [n, p, h, x.transferID]).count == shape.contents + 4, "setup: O0…, N, P, H and X are distinct contents")
        try #require((0..<shape.contents).allSatisfy { c in moved[c].allSatisfy { $0.transferID == contents[c] } } && after.allSatisfy { $0.transferID == contents[0] }, "setup: each content's ids share it")
        let all = kept + moved.flatMap { $0 } + after + members + [x]
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + Self.takeOffFillers(seed + 20_000) + all + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        for c in 0..<shape.contents {
            switch shape.ending {
            case .notFound:
                await s.harness.source.script(contents[c], [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(oBytes[c])])
            case .timeout:
                await s.harness.source.script(contents[c], [.hold, .fail(.transient(.timedOut, retryAfter: nil)), .stage(oBytes[c])])
            case .spaceRetry:
                await s.harness.source.script(contents[c], [.hold, .stage(oBytes[c])])
            }
        }
        await s.harness.source.script(n, [.hold, .stage(nBytes)])
        await s.harness.source.script(p, [.stage(pBytes)])
        await s.harness.source.script(h, [.hold, .stage(hBytes)])
        await s.harness.source.script(x.transferID, [.stage(xBytes)])
        // The waiters register one at a time, in order, so that their tokens ascend with the ids (`lanes`).
        func register(_ id: AssetID, lane: AssetPriority) async -> Task<Result<AssetLocation, AssetError>, Never> {
            let task = Task { await engine.awaitAsset(id, lane: lane) }
            await engine.awaitCondition { e in e.state.waiters.values.contains { $0.asset == id } }
            return task
        }
        var keptCallers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        if shape.keptWaiters {
            for entry in kept {
                keptCallers.append(await register(entry.identifier, lane: .userInitiated))
            }
        }
        var movedCallers: [[Task<Result<AssetLocation, AssetError>, Never>]] = []
        for c in 0..<shape.contents {
            var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
            for (index, entry) in moved[c].enumerated() {
                let lane = c == 0 ? shape.lanes?[index] ?? .userInitiated : .userInitiated
                callers.append(await register(entry.identifier, lane: lane))
            }
            movedCallers.append(callers)
        }
        var afterCallers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for entry in after {
            afterCallers.append(await register(entry.identifier, lane: .userInitiated))
        }
        var group: InterestToken?
        if shape.partial, let first = moved.first?.first {
            group = try await engine.registerGroup([kept[0].identifier, first.identifier], lane: .prefetch).get()
        }
        var bucketGroup: InterestToken?
        if !members.isEmpty {
            bucketGroup = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
            let count = members.count
            await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
                await engine.awaitCondition { $0.state.jobs[h]?.state == .downloading && $0.state.jobs[h]?.assets.count == count }
            }
        }
        var claim: InterestToken?
        if !shape.keptWaiters {
            let id = kept[0].identifier
            claim = await engine.readForTests { $0.recordGroup([id], lane: .prefetch).token }
        }
        let interests = (0..<shape.contents).map { c in shape.moved + (shape.keptWaiters ? 1 : 0) + (c == 0 ? shape.after + (shape.partial ? 1 : 0) : 0) }
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                e.state.conditions != nil && (0..<contents.count).allSatisfy { e.state.jobs[contents[$0]]?.state == .downloading && e.state.jobs[contents[$0]]?.interests.count == interests[$0] }
            }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + Self.takeOffFillers(seed + 30_000) + kept + movedOnN.flatMap { $0 } + after + members + [x] + Self.laterFillers(seed + 6_000), tag: "v3-take-off-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst {
            // Visited first, v3's visit moved the moved ids onto N, held, at the apply.
            await engine.awaitCondition { $0.state.jobs[n]?.state == .downloading }
        }
        if shape.ending == .spaceRetry, visit == .sweepFollowsFirst {
            // The ENOSPC's free-space read runs one follow turn (`advanceFollowForSpaceSweep`); the space sweep's own
            // follow-up turns, which would run the rest of the follow and its drain, are held.
            await engine.readForTests { $0.holdSpaceSweepFollowUps() }
        }
        for c in 0..<shape.contents {
            if shape.ending == .spaceRetry {
                await s.harness.source.release(contents[c], with: .failed(.insufficientSpace(requiredBytes: 200_000)))
            } else {
                await s.harness.source.release(contents[c], with: .progress(received: 0, expected: nil))
            }
            let transfer = contents[c]
            // No clock is driven: a verdict given at its arrival backs a job off without one, and its retry waits.
            if visit == .sweepFollowsFirst {
                await engine.awaitCondition { e in e.state.jobs[transfer]?.attemptEnd?.deferredAfter != nil }
            } else {
                await engine.awaitCondition { $0.state.jobs[transfer]?.state != .downloading }
            }
        }
        if visit == .sweepFollowsFirst {
            let waiting = await engine.readForTests { e in contents.map { e.state.jobs[$0]?.attemptEnd?.movedBefore ?? [] } }
            let expected = moved.map { Set($0.map(\.identifier)) }
            try #require(waiting == expected, "setup: each verdict waits with its content's moved ids moved off it before it: \(waiting)")
        } else {
            let none = await engine.readForTests { e in e.state.verdictsAfterFollow.isEmpty && e.state.eventsAfterFollow.isEmpty && !e.followBarrier }
            try #require(none, "visited first, every verdict was given at its arrival: no verdict waits")
        }
        var removal: AssetID?
        if let index = shape.removal {
            let entry = moved[0][index]
            removal = entry.identifier
            movedCallers[0][index].cancel()
            let id = entry.identifier
            if visit == .sweepFollowsFirst {
                await engine.awaitCondition { e in
                    e.state.eventsAfterFollow.contains { event in
                        if case .removal(let token, _) = event {
                            return e.state.waiters[token]?.asset == id
                        }
                        return false
                    }
                }
            } else {
                await engine.awaitCondition { e in !e.state.waiters.values.contains { $0.asset == id } }
            }
        }
        let ids = TakeOffIDs(contents: contents, moved: Set(moved.flatMap { $0 }.map(\.identifier)), after: Set(after.map(\.identifier)), p: p, removal: removal)
        return TakeOff(s: s, shape: shape, seed: seed, ids: ids, kept: kept, moved: moved, movedOnN: movedOnN, after: after, afterOnP: afterOnP, members: members, membersOnO: membersOnO, bucketGroup: bucketGroup, x: x, keptCallers: keptCallers, movedCallers: movedCallers, afterCallers: afterCallers, group: group, claim: claim)
    }

    /// Applies v4 (`TakeOff.v4`): visited first its follow ends at the apply; swept first it stays owed, its turns held.
    @available(macOS 15.0, iOS 18.0, *)
    func takeOffApplyV4(_ t: TakeOff, _ visit: LaneDropVisit) async throws {
        try await Self.applyHeld(t.v4, tag: "v4-take-off-\(t.seed)", t.s, visit: visit)
    }

    /// What one sweep-first held turn of a take-off scenario left.
    struct TakeOffTurn: Sendable, CustomStringConvertible {
        /// Which held turn ran.
        let kind: HeldTurn
        /// Whether the follow is still owed.
        let owed: Bool
        /// Whether a visit's rest waits (`followMoving`).
        let moving: Bool
        /// The verdicts that still wait.
        let verdicts: Int
        /// The moved ids a job past its verdict holds (no deferral recorded on it): the ones re-routed.
        let settled: Int
        /// The waiting batches of owed re-routes, and the distinct ids they owe.
        let batches: Int
        let owedIDs: Int
        /// The waiting events: `verdict`, `reroutes`, `removal`, `join`, `other`.
        let queue: [String]
        /// The `after` ids P's job holds.
        let onP: Int
        /// Whether a job holds the cancelled waiter's interest (`TakeOffShape.removal`).
        let removalOnJob: Bool
        /// O0's job's held lane (`Job.heldLane`) and its interests.
        let heldLane: AssetPriority?
        let o0Interests: Int
        /// The invariants.
        let violations: [String]

        var description: String {
            "\(self.kind.rawValue) owed=\(self.owed) moving=\(self.moving) verdicts=\(self.verdicts) settled=\(self.settled) batches=\(self.batches)/\(self.owedIDs) queue=\(self.queue.prefix(4))(\(self.queue.count)) onP=\(self.onP) removalOnJob=\(self.removalOnJob) heldLane=\(String(describing: self.heldLane)) o0=\(self.o0Interests) violations=\(self.violations.prefix(2))"
        }
    }

    /// Reads what `TakeOffTurn` holds.
    static func takeOffTurn(_ e: isolated SyncEngine, _ kind: HeldTurn, _ ids: TakeOffIDs) -> TakeOffTurn {
        var settled = 0
        for id in ids.moved where e.state.jobs.values.contains(where: { $0.assets.contains(id) && $0.attemptEnd?.deferredAfter == nil }) {
            settled += 1
        }
        var batches = 0
        var owed: Set<AssetID> = []
        let queue = e.state.eventsAfterFollow.map { event -> String in
            switch event {
            case .attemptFailed, .spaceFailure:
                return "verdict"
            case .reroutes(let batch):
                batches += 1
                owed.formUnion(batch.items.elements.map(\.asset))
                return "reroutes"
            case .removal:
                return "removal"
            case .join(let join):
                return "join \(join.asset)"
            default:
                return "other"
            }
        }
        let verdicts = ids.contents.filter { e.state.jobs[$0]?.attemptEnd?.deferredAfter != nil }.count
        let removalOnJob = ids.removal.map { id in
            e.state.waiters.contains { $0.value.asset == id && e.state.jobs[$0.value.transfer]?.interests[$0.key] != nil }
        } ?? false
        let o0 = ids.contents.first.flatMap { e.state.jobs[$0] }
        return TakeOffTurn(
            kind: kind,
            owed: e.followOwed,
            moving: e.state.followMoving != nil,
            verdicts: verdicts,
            settled: settled,
            batches: batches,
            owedIDs: owed.count,
            queue: queue,
            onP: e.state.jobs[ids.p]?.assets.intersection(ids.after).count ?? 0,
            removalOnJob: removalOnJob,
            heldLane: o0?.heldLane,
            o0Interests: o0?.interests.count ?? 0,
            violations: e.invariantViolations()
        )
    }

    /// Swept first: holds the drain's turns and releases the follow's and the drain's held turns one at a time, reading
    /// each, until no follow is owed and no event waits; then lets later turns run. Returns the readings, v4's apply's
    /// own turn first.
    @available(macOS 15.0, iOS 18.0, *)
    static func takeOffTurns(_ t: TakeOff) async throws -> [TakeOffTurn] {
        let engine = t.engine
        let ids = t.ids
        await engine.readForTests { $0.holdDrainFollowUps() }
        var turns = [await engine.readForTests { e in Self.takeOffTurn(e, .follow, ids) }]
        while await engine.readForTests({ $0.followOwed || !$0.state.eventsAfterFollow.isEmpty }) {
            // The time limit's cancellation ends the wait for a held turn, not this loop.
            try #require(turns.count < 80, "the follow and its drain end within 80 turns: \(turns)")
            let kind = await Self.runOneHeldTurn(engine)
            turns.append(await engine.readForTests { e in Self.takeOffTurn(e, kind, ids) })
        }
        await engine.readForTests { e in
            e.releaseDrainFollowUps()
            e.releaseFollowFollowUps()
            e.releaseSpaceSweepFollowUps()
        }
        return turns
    }

    /// The ids each reading's turn re-routed (`TakeOffTurn.settled`'s growth), from the second reading on.
    static func takeOffMade(_ turns: [TakeOffTurn]) -> [Int] {
        zip(turns.dropFirst(), turns).map { $0.settled - $1.settled }
    }

    /// What a take-off scenario's callers got (`takeOffFinish`): the bytes served, `-1` for an error.
    struct TakeOffOutcome {
        /// The kept ids' answers, per content.
        let kept: [Result<AssetLocation, AssetError>]
        /// The moved ids' bytes, per content, in index order (the cancelled waiter's is `-2`).
        let moved: [[Int64]]
        /// The `after` ids' bytes.
        let after: [Int64]
        /// The partial group's members still pending once every caller is answered.
        let groupPending: [AssetID]
        /// The jobs left once every caller is answered.
        let jobs: Int
        /// The bucket's group's members still pending then.
        let bucketPending: Int
    }

    /// Lets the follow and its drain end, reads every answer, driving the clock, then checks the invariants and shuts the
    /// engine down.
    @available(macOS 15.0, iOS 18.0, *)
    func takeOffFinish(_ t: TakeOff) async throws -> TakeOffOutcome {
        let engine = t.engine
        await engine.readForTests { e in
            e.releaseDrainFollowUps()
            e.releaseFollowFollowUps()
            e.releaseSpaceSweepFollowUps()
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled }
        func bytes(_ result: Result<AssetLocation, AssetError>) -> Int64 {
            (try? result.get())?.byteSize ?? -1
        }
        var kept: [Result<AssetLocation, AssetError>] = []
        for caller in t.keptCallers {
            kept.append(await EngineRegressionCycle6Tests.driving([t.s.time], fence: engine) { await EngineHarness.value(of: caller) })
        }
        var moved: [[Int64]] = []
        for (c, callers) in t.movedCallers.enumerated() {
            var served: [Int64] = []
            for (index, caller) in callers.enumerated() {
                let result = await EngineRegressionCycle6Tests.driving([t.s.time], fence: engine) { await EngineHarness.value(of: caller) }
                served.append(c == 0 && index == t.shape.removal ? (result == .failure(.cancelled) ? -2 : bytes(result)) : bytes(result))
            }
            moved.append(served)
        }
        var after: [Int64] = []
        for caller in t.afterCallers {
            after.append(bytes(await EngineRegressionCycle6Tests.driving([t.s.time], fence: engine) { await EngineHarness.value(of: caller) }))
        }
        await engine.awaitCondition { !$0.followBarrier && !$0.state.drainFollowUpScheduled && !$0.state.storeWorkInFlight }
        if let bucketGroup = t.bucketGroup {
            await EngineRegressionCycle6Tests.driving([t.s.time], fence: engine) {
                await engine.awaitCondition { $0.state.groups[bucketGroup]?.pending.isEmpty == true && $0.state.jobs.isEmpty }
            }
        }
        let group = t.group
        let bucketGroup = t.bucketGroup
        let left = await engine.readForTests { e in
            (pending: group.map { e.state.groups[$0]?.pending.keys.sorted() ?? [] } ?? [], jobs: e.state.jobs.count, bucket: bucketGroup.map { e.state.groups[$0]?.pending.count ?? 0 } ?? 0)
        }
        for token in [t.group, t.claim, t.bucketGroup].compactMap({ $0 }) {
            await engine.releaseGroup(token)
        }
        await Self.finishHeld(t.s)
        return TakeOffOutcome(kept: kept, moved: moved, after: after, groupPending: left.pending, jobs: left.jobs, bucketPending: left.bucket)
    }
}
