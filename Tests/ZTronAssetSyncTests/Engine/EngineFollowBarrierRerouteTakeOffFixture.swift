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
        /// The ids zz-y00… of a content Y (14 bytes), with zz-yk, which v4 maps to W's content (26 bytes) while Y
        /// publishes, held (`takeOffHoldY`): Y's commit then owes their re-routes as one batch (site 1) behind O0's
        /// verdict (`takeOffCommitY`).
        var commit = 0
        /// A present content D (zz-d, 4,000 bytes, made present after v2), onto which v5 maps O0's moved ids
        /// (`TakeOff.v5`), so that its apply binds them to D's blob (`ApplyReport.reused`), with the gate that keeps a job
        /// of D's content, had one been made, from serving them (RR21-PRESENT-PRUNE at site 2).
        var present: PresentGate?
        /// With `.timeout`: O0's retry times out too, at the interactive cap (`maxAttemptsPerRun` 2), so its verdict
        /// answers every id O0 then holds with the timeout.
        var capped = false
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
        /// Y's moved ids and W's transfer (`TakeOffShape.commit`), and D's transfer (`TakeOffShape.present`).
        let yMoved: Set<AssetID>
        let w: TransferID
        let d: TransferID
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
        /// The store units' executor (`setUpHeldPublications`), where Y's publication is held (`takeOffHoldY`).
        let bulk: SteppedBlockingExecutor
        /// zz-yk and zz-y… on Y's content, zz-y… on W's (`commit`), and their waiters, zz-yk's first.
        let yKept: [ManifestEntry]
        let yMoved: [ManifestEntry]
        let yMovedOnW: [ManifestEntry]
        let yCallers: [Task<Result<AssetLocation, AssetError>, Never>]
        /// zz-d and zz-e (`present`), listed in every manifest, and O0's moved ids on D's content.
        let presentEntries: [ManifestEntry]
        let movedOnD: [ManifestEntry]
        /// zz-e's waiter (`present == .breakerOpen`): its job downloads, held, until `takeOffOpenBreaker`.
        let eCaller: Task<Result<AssetLocation, AssetError>, Never>?

        var engine: SyncEngine {
            self.s.engine
        }

        /// v4: every content's ids on their own content, the `after` ids on P; with `commit`, zz-y… on W's.
        var v4: [ManifestEntry] {
            self.manifest(moved: self.moved.flatMap { $0 })
        }

        /// v5 (`present`): v4 with O0's moved ids on D's content. Swept first it lands once the follow's visit of O0 under
        /// v4, which found O0 by its `after` ids and the moved ids back on O0's content, spent the set it re-routes
        /// (`Job.rerouteOnPass`), so its own visit passes O0 and leaves them to the verdict, whose take-off re-routes them
        /// onto D (`takeOffFollowUntilVisited`).
        var v5: [ManifestEntry] {
            self.manifest(moved: self.movedOnD + self.moved.dropFirst().flatMap { $0 })
        }

        /// v4's entries with `moved` as the contents' moved ids.
        private func manifest(moved: [ManifestEntry]) -> [ManifestEntry] {
            [self.s.q] + FollowBarrier.fillers(self.seed + 300) + EngineFollowBarrierTests.takeOffFillers(self.seed + 20_000) + self.kept + moved + self.afterOnP + self.membersOnO + [self.x] + self.yKept + self.yMovedOnW + self.presentEntries + EngineFollowBarrierTests.laterFillers(self.seed + 9_000)
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
        let breaker = shape.present == .breakerOpen ? CircuitBreakerPolicy(authDistinctAssets: 1) : CircuitBreakerPolicy()
        let (s, bulk) = try await Self.setUpHeldPublications(seed: seed, tuning: SyncTuning(interactiveRetry: Self.shortInteractiveRetry, breaker: breaker))
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
        let yBytes = EngineFixture.bytes(seed + 40, count: 14)
        let wBytes = EngineFixture.bytes(seed + 41, count: 26)
        let dBytes = EngineFixture.bytes(seed + 42, count: 4_000)
        let eBytes = EngineFixture.bytes(seed + 43, count: 12)
        let yKept = shape.commit > 0 ? [EngineHarness.onDemand("zz-yk", yBytes)] : []
        let yNames = (0..<shape.commit).map { String(format: "zz-y%02d", $0) }
        let yMoved = yNames.map { EngineHarness.onDemand($0, yBytes) }
        let yMovedOnW = yNames.map { EngineHarness.onDemand($0, wBytes) }
        let zzD = EngineHarness.onDemand("zz-d", dBytes)
        let zzE = EngineHarness.onDemand("zz-e", eBytes)
        let presentEntries = shape.present == nil ? [] : [zzD, zzE]
        let movedOnD = shape.present == nil ? [] : movedNames[0].map { EngineHarness.onDemand($0, dBytes) }
        let y = EngineHarness.onDemand("zz-yk", yBytes).transferID
        let w = EngineHarness.onDemand("zz-w", wBytes).transferID
        let contents = kept.map(\.transferID)
        let n = EngineHarness.onDemand("zz-n", nBytes).transferID
        let p = EngineHarness.onDemand("zz-p", pBytes).transferID
        let others = [n, p, h, x.transferID] + (shape.commit > 0 ? [y, w] : []) + (shape.present == nil ? [] : [zzD.transferID, zzE.transferID])
        try #require(Set(contents + others).count == shape.contents + others.count, "setup: O0…, N, P, H, X (and Y, W, D, E) are distinct contents")
        try #require((0..<shape.contents).allSatisfy { c in moved[c].allSatisfy { $0.transferID == contents[c] } } && after.allSatisfy { $0.transferID == contents[0] }, "setup: each content's ids share it")
        let all = kept + moved.flatMap { $0 } + after + members + [x] + yKept + yMoved + presentEntries
        await s.harness.serveManifest([s.q] + FollowBarrier.fillers(seed + 100) + Self.takeOffFillers(seed + 20_000) + all + Self.laterFillers(seed + 3_000), etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && !$0.state.storeWorkInFlight }
        try await s.harness.store.flush(.ordered)
        await engine.awaitCondition { $0.state.storeDeadline == nil && !$0.state.storeWorkInFlight }
        for c in 0..<shape.contents {
            switch shape.ending {
            case .notFound where shape.present != nil:
                // Visited first, v4's visit makes a fresh job of O0's content for the moved ids, held, which v5's supersedes.
                await s.harness.source.script(contents[c], [.hold, .fail(.permanentMissing(httpStatus: 404)), .hold, .stage(oBytes[c])])
            case .notFound:
                await s.harness.source.script(contents[c], [.hold, .fail(.permanentMissing(httpStatus: 404)), .stage(oBytes[c])])
            case .timeout where shape.capped:
                await s.harness.source.script(contents[c], [.hold, .fail(.transient(.timedOut, retryAfter: nil)), .fail(.transient(.timedOut, retryAfter: nil))])
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
        if shape.commit > 0 {
            await s.harness.source.script(y, [.hold, .stage(yBytes)])
            await s.harness.source.script(w, [.stage(wBytes)])
        }
        if shape.present == .breakerOpen {
            // zz-e downloads, held, until `takeOffOpenBreaker` lets its 403 arrive.
            await s.harness.source.script(zzE.transferID, [.hold, .fail(EngineRegressionCycle20Tests.forbidden)])
        }
        if shape.present != nil {
            // D is present before the waiters register: zz-d's request fetches it, and its job ends.
            let dT = zzD.transferID
            await s.harness.source.script(dT, [.stage(dBytes)])
            let dID = zzD.identifier
            let served = await EngineRegressionCycle6Tests.driving([s.time], fence: engine) { await engine.awaitAsset(dID, lane: .userInitiated) }
            try #require((try? served.get())?.byteSize == 4_000, "setup: zz-d is present: \(served)")
            await engine.awaitCondition { $0.state.jobs[dT] == nil && !$0.state.storeWorkInFlight }
        }
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
        var yCallers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for entry in yKept + yMoved {
            yCallers.append(await register(entry.identifier, lane: .userInitiated))
        }
        let eCaller = shape.present == .breakerOpen ? await register(zzE.identifier, lane: .userInitiated) : nil
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
        let yInterests = yCallers.count
        let eT = eCaller == nil ? nil : zzE.transferID
        await EngineRegressionCycle6Tests.driving([s.time], fence: engine) {
            await engine.awaitCondition { e in
                e.state.conditions != nil && (0..<contents.count).allSatisfy { e.state.jobs[contents[$0]]?.state == .downloading && e.state.jobs[contents[$0]]?.interests.count == interests[$0] }
                    && (yInterests == 0 || (e.state.jobs[y]?.state == .downloading && e.state.jobs[y]?.interests.count == yInterests))
                    && eT.map { e.state.jobs[$0]?.state == .downloading } ?? true
            }
        }
        try await Self.applyHeld([s.q] + FollowBarrier.fillers(seed + 200) + Self.takeOffFillers(seed + 30_000) + kept + movedOnN.flatMap { $0 } + after + members + [x] + yKept + yMoved + presentEntries + Self.laterFillers(seed + 6_000), tag: "v3-take-off-\(seed)", s, visit: visit)
        if visit == .followVisitedFirst, shape.moved > 0 {
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
        let ids = TakeOffIDs(contents: contents, moved: Set(moved.flatMap { $0 }.map(\.identifier)), after: Set(after.map(\.identifier)), p: p, removal: removal, yMoved: Set(yMoved.map(\.identifier)), w: w, d: zzD.transferID)
        return TakeOff(s: s, shape: shape, seed: seed, ids: ids, kept: kept, moved: moved, movedOnN: movedOnN, after: after, afterOnP: afterOnP, members: members, membersOnO: membersOnO, bucketGroup: bucketGroup, x: x, keptCallers: keptCallers, movedCallers: movedCallers, afterCallers: afterCallers, group: group, claim: claim, bulk: bulk, yKept: yKept, yMoved: yMoved, yMovedOnW: yMovedOnW, yCallers: yCallers, presentEntries: presentEntries, movedOnD: movedOnD, eCaller: eCaller)
    }

    /// Applies v4 (`TakeOff.v4`): visited first its follow ends at the apply; swept first it stays owed, its turns held.
    @available(macOS 15.0, iOS 18.0, *)
    func takeOffApplyV4(_ t: TakeOff, _ visit: LaneDropVisit) async throws {
        try await Self.applyHeld(t.v4, tag: "v4-take-off-\(t.seed)", t.s, visit: visit)
    }

    /// Swept first: holds the drain's turns and runs the follow's held turns one at a time until its visit of O0 spent
    /// O0's re-routed set (`Job.rerouteOnPass`), with the follow still owed and O0's verdict waiting, so that an apply
    /// lands after that visit and before the verdict (`TakeOff.v5`). A pass finds O0 only by an id whose content differs
    /// between its copy and the engine's (`continueFollowScans`): its `after` ids, which v4 maps to P; the moved ids are
    /// on O0's content in v2's copy and in v4's, and on N's, which has no job, in v3's. It fails, rather than waiting for
    /// a held turn that never comes, once the follow ended or O0's verdict was given first.
    @available(macOS 15.0, iOS 18.0, *)
    static func takeOffFollowUntilVisited(_ t: TakeOff) async throws {
        let engine = t.engine
        let o0 = try #require(t.ids.contents.first)
        await engine.readForTests { $0.holdDrainFollowUps() }
        var turns = 0
        while true {
            let state = await engine.readForTests { e in (spent: e.state.jobs[o0]?.rerouteOnPass?.isEmpty == true, owed: e.followOwed, waits: e.state.jobs[o0]?.attemptEnd?.deferredAfter != nil) }
            try #require(state.owed && state.waits, "setup: the follow visits O0 with more of it owed, before O0's verdict: \(state) after \(turns) turns")
            if state.spent {
                return
            }
            try #require(turns < 40, "setup: the follow visits O0 within 40 turns")
            _ = await Self.runOneHeldTurn(engine)
            turns += 1
        }
    }

    /// Lets zz-e's held attempt end in its 403, which opens the breaker at its arrival (`authDistinctAssets` 1,
    /// `recordBreaker`), behind the barrier too, where its verdict waits (zz-e's waiter, `TakeOff.eCaller`, gets it).
    @available(macOS 15.0, iOS 18.0, *)
    func takeOffOpenBreaker(_ t: TakeOff) async throws {
        let engine = t.engine
        let e = try #require(t.presentEntries.last, "setup: a present shape").transferID
        let origin = t.s.harness.source.originID
        await t.s.harness.source.release(e, with: .progress(received: 0, expected: nil))
        await engine.awaitCondition { e in
            if case .open? = e.state.breakers[origin]?.state {
                return true
            }
            return false
        }
    }

    /// Holds Y's publication at its first store unit (`holdPublications`), before v4 maps zz-y… to W's content: v4's
    /// visit then passes Y publishing (RR-14), and Y's commit re-routes them (`takeOffCommitY`).
    @available(macOS 15.0, iOS 18.0, *)
    func takeOffHoldY(_ t: TakeOff) async throws -> HeldUnits {
        let y = try #require(t.yKept.first, "setup: a commit shape").transferID
        let (units, releaser) = try await Self.holdPublications(of: [y], t.s, bulk: t.bulk)
        return HeldUnits(bulk: t.bulk, kept: units, releaser: releaser)
    }

    /// Releases Y's held publication with the drain's turns held: Y commits, binds zz-yk, and owes zz-y…'s re-routes as
    /// one batch, since its answer and re-routes pass `inboundIDsNow`.
    @available(macOS 15.0, iOS 18.0, *)
    func takeOffCommitY(_ t: TakeOff, _ held: inout HeldUnits) async throws {
        let engine = t.engine
        let y = try #require(t.yKept.first, "setup: a commit shape").transferID
        let unit = try #require(held.kept.first, "setup: Y's publication is held")
        await engine.readForTests { $0.holdDrainFollowUps() }
        await held.release(unit)
        await engine.awaitCondition { $0.state.jobs[y] == nil }
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
        /// The ids zz-y… W's job holds (`TakeOffShape.commit`).
        let yOnW: Int
        /// The moved ids bound to D's content, and whether a job of D's content exists (`TakeOffShape.present`).
        let boundOnD: Int
        let dJob: Bool
        /// The jobs.
        let jobs: Int
        /// The invariants.
        let violations: [String]

        var description: String {
            "\(self.kind.rawValue) owed=\(self.owed) moving=\(self.moving) verdicts=\(self.verdicts) settled=\(self.settled) batches=\(self.batches)/\(self.owedIDs) queue=\(self.queue.prefix(4))(\(self.queue.count)) onP=\(self.onP) removalOnJob=\(self.removalOnJob) heldLane=\(String(describing: self.heldLane)) o0=\(self.o0Interests) yOnW=\(self.yOnW) boundOnD=\(self.boundOnD) dJob=\(self.dJob) jobs=\(self.jobs) violations=\(self.violations.prefix(2))"
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
            yOnW: e.state.jobs[ids.w]?.assets.intersection(ids.yMoved).count ?? 0,
            boundOnD: ids.moved.filter { e.state.boundContent[$0] == ids.d }.count,
            dJob: e.state.jobs[ids.d] != nil,
            jobs: e.state.jobs.count,
            violations: e.invariantViolations()
        )
    }

    /// Swept first: holds the drain's turns and releases the follow's and the drain's held turns one at a time, reading
    /// each, until no follow is owed and no event waits; then lets later turns run. Returns the readings, v4's apply's
    /// own turn first.
    ///
    /// The attempts' terminals are held meanwhile (`holdAttemptTerminals()`) and released with the follow-ups at the
    /// end. The pump admits nothing behind the barrier (`pump`), and the drain's last batch pumps once it is down: an
    /// attempt it starts (a retry the take-off's user re-routes skip the backoff for, T20, a fresh job's, P's or W's)
    /// would otherwise end between that turn and its reading, in an order the scheduler picks, and the reading would show
    /// that end rather than the turn (the cycle-21 gate run's third Sync run, PROBE-RR21-RESERVE-REJOIN). An attempt a
    /// held turn cancels keeps its terminal until the end too; no reading reads a transfer's drain.
    ///
    /// `settle`, when given, runs after each held turn that leaves the barrier down, before that turn is read: the
    /// attempts the drain's last batch started reach their terminals then, in the worst order the scheduler may give
    /// them (PROBE-C21-RESERVE-SETTLE).
    @available(macOS 15.0, iOS 18.0, *)
    static func takeOffTurns(_ t: TakeOff, settle: (@Sendable (SyncEngine) async -> Void)? = nil) async throws -> [TakeOffTurn] {
        let engine = t.engine
        let ids = t.ids
        await engine.readForTests { e in
            e.holdDrainFollowUps()
            e.holdAttemptTerminals()
        }
        var turns = [await engine.readForTests { e in Self.takeOffTurn(e, .follow, ids) }]
        while await engine.readForTests({ $0.followOwed || !$0.state.eventsAfterFollow.isEmpty }) {
            // The time limit's cancellation ends the wait for a held turn, not this loop.
            try #require(turns.count < 80, "the follow and its drain end within 80 turns: \(turns)")
            let kind = await Self.runOneHeldTurn(engine)
            if let settle, await engine.readForTests({ !$0.followBarrier }) {
                await settle(engine)
            }
            turns.append(await engine.readForTests { e in Self.takeOffTurn(e, kind, ids) })
        }
        await engine.readForTests { e in
            e.releaseDrainFollowUps()
            e.releaseFollowFollowUps()
            e.releaseSpaceSweepFollowUps()
            e.releaseAttemptTerminals()
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
        /// zz-yk's and zz-y…'s bytes (`TakeOffShape.commit`).
        let y: [Int64]
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
        var y: [Int64] = []
        for caller in t.yCallers {
            y.append(bytes(await EngineRegressionCycle6Tests.driving([t.s.time], fence: engine) { await EngineHarness.value(of: caller) }))
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
        return TakeOffOutcome(kept: kept, moved: moved, after: after, groupPending: left.pending, jobs: left.jobs, bucketPending: left.bucket, y: y)
    }
}
