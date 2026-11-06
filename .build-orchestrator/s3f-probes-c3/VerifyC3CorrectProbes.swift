import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch probes (s3f close-out verification, cycle 3, correctness lens). Never committed.
enum C3Failure: String, CaseIterable, Sendable {
    case notFound
    case integrity
    case rejected
    case transientAtCap

    var update: TransferUpdate {
        switch self {
        case .notFound:
            return .failed(.permanentMissing(httpStatus: 404))
        case .integrity:
            return .failed(.integrity(.sizeMismatch(expected: 16, actual: 9)))
        case .rejected:
            return .failed(.rejected(.unexpectedStatus(400)))
        case .transientAtCap:
            return .failed(.transient(.timedOut, retryAfter: nil))
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    func harness() -> EngineHarness {
        switch self {
        case .transientAtCap:
            var interactive = RetryPolicy.interactive
            interactive.maxAttemptsPerRun = 1
            return EngineHarness.make(tuning: SyncTuning(interactiveRetry: interactive))
        default:
            return EngineHarness.make()
        }
    }
}

@Suite("VerifyC3Correct probes")
struct VerifyC3CorrectProbes {
    /// The fillers: on-demand entries without jobs, all changed by the apply, sorting before the targets, so the follow's
    /// first pass formats `followFormatsPerTurn` of them and stops before the targets (the pass has not reached them).
    @available(macOS 15.0, iOS 18.0, *)
    static func fillers(_ seed: UInt64) -> [ManifestEntry] {
        (0..<(SyncEngine.followFormatsPerTurn + 52)).map { EngineHarness.onDemand(String(format: "f%05d", $0), EngineFixture.bytes(seed + UInt64($0), count: 16)) }
    }

    /// PROBE-C3-W4: own reproduction of the cycle-2 W4 defect, the pass-bound form (the target's job not even owed a
    /// visit yet), for failure kinds the committed test does not use: a 404, an integrity failure, a 400 rejection and a
    /// transient failure at the user cap.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C3-W4: a failure of a listed id's replaced content before the pass reached it answers from new content", .timeLimit(.minutes(3)), arguments: C3Failure.allCases)
    func w4(_ failure: C3Failure) async throws {
        let harness = failure.harness()
        let target = EngineHarness.onDemand("zz-target", EngineFixture.bytes(777_001, count: 16))
        let v1 = Self.fillers(700_000) + [target]
        try await EngineSingleFlightTests.applied(v1, harness: harness)
        let engine = harness.engine
        await harness.source.script(target.transferID, [.hold])
        let waiter = Task { await engine.awaitAsset(target.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[target.transferID]?.state == .downloading }
        await engine.waitForHandle(target.transferID)
        let replacement = EngineHarness.onDemand("zz-target", EngineFixture.bytes(777_002, count: 16))
        await harness.source.script(replacement.transferID, [.stage(EngineFixture.bytes(777_002, count: 16))])
        let v2 = Self.fillers(800_000) + [replacement]
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest(v2, etag: "v2")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        let before = await engine.readForTests { engine in
            (listed: engine.state.applied.entry(for: target.identifier)?.transferID == replacement.transferID,
             unfollowed: engine.state.unfollowed.contains(target.transferID),
             scans: engine.state.followScans.count)
        }
        print("PROBE-C3-W4[\(failure)] before: \(before)")
        await harness.source.release(target.transferID, with: failure.update)
        await engine.awaitCondition { $0.state.jobs[target.transferID]?.state != .downloading }
        let violations = await engine.invariantViolations()
        await engine.readForTests { $0.releaseFollowFollowUps() }
        _ = await EngineHarness.value(of: sync)
        let answer = await EngineHarness.value(of: waiter)
        print("PROBE-C3-W4[\(failure)] answer: \(answer)")
        #expect(before.listed && !before.unfollowed && before.scans > 0)
        #expect((try? answer.get()) != nil, "PROBE-C3-W4 FAIL[\(failure)]: \(answer)")
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await engine.shutdown()
    }

    /// PROBE-C3-PARTIAL: a job shared by two ids (same bytes), only one of which the apply moves; the old content 404s
    /// before the pass reached them. The moved id's waiter is answered from its new content, the other one `notFound`.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C3-PARTIAL: a 404 for a shared job answers only the id still mapped to it", .timeLimit(.minutes(3)))
    func partial() async throws {
        let harness = EngineHarness.make()
        let bytes = EngineFixture.bytes(778_001, count: 16)
        let a = EngineHarness.onDemand("zz-a", bytes)
        let b = EngineHarness.onDemand("zz-b", bytes)
        #expect(a.transferID == b.transferID, "setup: one transfer for both ids")
        let v1 = Self.fillers(710_000) + [a, b]
        try await EngineSingleFlightTests.applied(v1, harness: harness)
        let engine = harness.engine
        await harness.source.script(a.transferID, [.hold])
        let waiterA = Task { await engine.awaitAsset(a.identifier, lane: .userInitiated) }
        let waiterB = Task { await engine.awaitAsset(b.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state == .downloading && $0.state.jobs[a.transferID]?.interests.count == 2 }
        await engine.waitForHandle(a.transferID)
        let a2 = EngineHarness.onDemand("zz-a", EngineFixture.bytes(778_002, count: 16))
        await harness.source.script(a2.transferID, [.stage(EngineFixture.bytes(778_002, count: 16))])
        let v2 = Self.fillers(810_000) + [a2, b]
        await engine.readForTests { $0.holdFollowFollowUps() }
        await harness.serveManifest(v2, etag: "v2")
        let sync = Task { await engine.sync(.force) }
        await engine.awaitCondition { $0.state.followFollowUpWaiting }
        await harness.source.release(a.transferID, with: .failed(.permanentMissing(httpStatus: 404)))
        await engine.awaitCondition { $0.state.jobs[a.transferID]?.state != .downloading }
        let violations = await engine.invariantViolations()
        await engine.readForTests { $0.releaseFollowFollowUps() }
        _ = await EngineHarness.value(of: sync)
        let answerA = await EngineHarness.value(of: waiterA)
        let answerB = await EngineHarness.value(of: waiterB)
        print("PROBE-C3-PARTIAL: a \(answerA), b \(answerB)")
        #expect((try? answerA.get()) != nil, "PROBE-C3-PARTIAL FAIL: moved id answered \(answerA)")
        let bNotFound: Bool
        if case .failure(.notFound) = answerB { bNotFound = true } else { bNotFound = false }
        #expect(bNotFound, "the unmoved id gets its content's 404: \(answerB)")
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await engine.shutdown()
    }

    /// PROBE-C3-W4b: own seam-free reproduction (3,000 ids; the 404 released as soon as the copy changes).
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C3-W4b: without seams a 404 of a listed id's replaced content during the follow answers from new content", .timeLimit(.minutes(3)), arguments: [0, 1, 2])
    func w4b(_ round: Int) async throws {
        let count = 3_000
        let base = UInt64(1_000_000 + round * 100_000)
        let harness = EngineHarness.make()
        let v1 = (0..<count).map { EngineHarness.onDemand(String(format: "m%04d", $0), EngineFixture.bytes(base + UInt64($0), count: 16)) }
        try await EngineSingleFlightTests.applied(v1, harness: harness)
        let engine = harness.engine
        let target = v1[count - 1]
        let group = try await engine.registerGroup(v1.dropLast().map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count - 1 }
        await harness.source.script(target.transferID, [.hold])
        let waiter = Task { await engine.awaitAsset(target.identifier, lane: .userInitiated) }
        await engine.awaitCondition { $0.state.jobs[target.transferID]?.state == .downloading }
        await engine.waitForHandle(target.transferID)
        let v2 = v1.enumerated().map { index, entry in
            EngineHarness.onDemand(entry.identifier.rawValue, EngineFixture.bytes(base + 50_000 + UInt64(index), count: 16))
        }
        let newID = v2[count - 1].transferID
        await harness.source.script(newID, [.stage(EngineFixture.bytes(base + 50_000 + UInt64(count - 1), count: 16))])
        await harness.serveManifest(v2, etag: "v2")
        let source = harness.source
        let racer = Task {
            await engine.awaitCondition { $0.state.applied.entry(for: target.identifier)?.transferID == newID }
            let owed = await engine.readForTests { ($0.state.followOrder.count - $0.state.followNext, $0.state.followScans.count) }
            await source.release(target.transferID, with: .failed(.permanentMissing(httpStatus: 404)))
            return owed
        }
        let outcome = await engine.sync(.force)
        let owed = await EngineHarness.value(of: racer)
        let answer = await EngineHarness.value(of: waiter)
        print("PROBE-C3-W4b[\(round)]: owed at release \(owed), complete \(outcome.completeReport != nil), answer \(answer)")
        #expect((try? answer.get()) != nil, "PROBE-C3-W4b FAIL: \(answer)")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    /// PROBE-C3-W1b: own seam-free reproduction (3,000 members, 4 slots): no start of replaced content after the apply,
    /// counted over the whole follow, with a slot freed by a success between follow turns.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C3-W1b: over a whole bounded follow no transfer of replaced content starts after the apply", .timeLimit(.minutes(3)), arguments: [0, 1])
    func w1b(_ round: Int) async throws {
        let count = 3_000
        let base = UInt64(2_000_000 + round * 100_000)
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 0))
        let v1 = (0..<count).map { EngineHarness.onDemand(String(format: "n%04d", $0), EngineFixture.bytes(base + UInt64($0), count: 16)) }
        try await EngineSingleFlightTests.applied(v1, harness: harness)
        let engine = harness.engine
        let group = try await engine.registerGroup(v1.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.jobs.count == count && $0.state.inFlight.count == 4 }
        let before = await harness.source.starts.count
        let old = Set(v1.map(\.transferID))
        let running = await engine.readForTests { Array($0.state.inFlight) }
        let v2 = v1.enumerated().map { index, entry in
            EngineHarness.onDemand(entry.identifier.rawValue, EngineFixture.bytes(base + 50_000 + UInt64(index), count: 16))
        }
        await harness.serveManifest(v2, etag: "v2")
        let source = harness.source
        let newFirst = v2[0].transferID
        let racer = Task {
            await engine.awaitCondition { $0.state.applied.entry(for: v1[0].identifier)?.transferID == newFirst }
            // Free slots between follow turns: two old transfers end with a 503 (a retry) and one is cancelled by the client.
            await source.release(running[0], with: .failed(.transient(.serverError(httpStatus: 503), retryAfter: nil)))
            await source.release(running[1], with: .failed(.cancelled(.byClient)))
        }
        let outcome = await engine.sync(.force)
        _ = await EngineHarness.value(of: racer)
        await engine.awaitCondition { !$0.followOwed && $0.state.draining.isEmpty }
        let starts = await harness.source.starts.dropFirst(before).map(\.id)
        let stale = starts.filter { old.contains($0) }
        let violations = await engine.readForTests { $0.invariantViolations() }
        print("PROBE-C3-W1b[\(round)]: complete \(outcome.completeReport != nil), starts since the apply \(starts.count), stale \(stale.count)")
        #expect(stale.isEmpty, "PROBE-C3-W1b FAIL: \(stale.count) stale starts")
        #expect(violations.isEmpty, "\(violations.prefix(3))")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }

    /// PROBE-C3-SPACE: a listed id's replaced content parked `awaitingSpace` (pending reclaim) when the apply lands; before
    /// the bounded follow's pass reaches it, the store's reaper runs and the `.reclaimed` sweep parks the old job
    /// `insufficientSpace` (its 5 MB do not fit the room left), answering the waiter with the OLD content's figures,
    /// although the copy lists the id at a 16-byte content that fits the hundreds of KB left. The fix's rule: only the ids the copy still maps to a
    /// content receive its failure.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C3-SPACE: a space sweep during the follow does not answer a moved id with its replaced content's figures", .timeLimit(.minutes(3)))
    func spaceSweep() async throws {
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
        let old = EngineHarness.onDemand("zz-target", EngineFixture.bytes(779_003, count: 5_000_000))
        // v2 prunes x (doomed for the 60 s grace) and lists q, the fillers and the target's 4,000-byte content.
        await harness.serveManifest([q] + Self.fillers(720_000) + [old], etag: "v2")
        _ = try #require(await engine.sync(.force).completeReport)
        await engine.awaitCondition { $0.state.manifestCatchUps == 0 && $0.state.storeDeadline != nil && !$0.state.storeWorkInFlight }
        try await harness.store.flush(.ordered)
        // The store's own files are on the volume now: leave 1 MB above the reserve (O's 5 MB never fits, N's 16 bytes do).
        _ = try await EngineRegressionCycle6Tests.leaveRoom(1_000_000, harness: harness, fileSystem: fileSystem)
        let pending = try await harness.store.freeSpace().pendingReclaim
        #expect(pending == Int64(xBytes.count), "setup: x's bytes wait for reclaim")
        // A fresh read, so the ledger knows the pending reclaim before the user job's gate.
        await engine.refreshFreeSpace()
        await harness.source.script(old.transferID, [.hold])
        let waiter = Task { await engine.awaitAsset(old.identifier, lane: .userInitiated) }
        await engine.awaitCondition { engine in
            switch engine.state.jobs[old.transferID]?.state {
            case .blocked?, .downloading?:
                return true
            default:
                return false
            }
        }
        let parked = await engine.readForTests { $0.state.jobs[old.transferID]?.state }
        print("PROBE-C3-SPACE setup: the old job is \(String(describing: parked))")
        try #require(parked == .blocked(.awaitingSpace), "setup: the old content waits for the reclaim")
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
        let roomBefore = try await harness.store.freeSpace()
        print("PROBE-C3-SPACE before the reap: \(before); room above reserve \(roomBefore.volumeImportant - roomBefore.reserveBytes), pending \(roomBefore.pendingReclaim)")
        // The grace ends: the alarm runs the store's due work, which reaps x's 300 bytes; the `.reclaimed` sweep follows.
        await EngineRegressionCycle6Tests.driving([time], fence: engine) {
            await engine.awaitCondition { engine in
                engine.state.jobs[old.transferID]?.state != .blocked(.awaitingSpace)
            }
        }
        let mid = await engine.readForTests { engine in
            (oldState: engine.state.jobs[old.transferID]?.state, owed: engine.followOwed, waiting: engine.state.followFollowUpWaiting)
        }
        print("PROBE-C3-SPACE after the reap: \(mid)")
        await engine.readForTests { $0.releaseFollowFollowUps() }
        let answer = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: waiter) }
        _ = await EngineRegressionCycle6Tests.driving([time], fence: engine) { await EngineHarness.value(of: sync) }
        let free = try await harness.store.freeSpace()
        print("PROBE-C3-SPACE answer: \(answer); room above reserve now \(free.volumeImportant - free.reserveBytes)")
        #expect(before.listed && before.owed && !before.unfollowed, "setup: \(before)")
        #expect((try? answer.get()) != nil, "PROBE-C3-SPACE FAIL: the waiter of a listed id was answered \(answer)")
        await engine.shutdown()
    }
}
