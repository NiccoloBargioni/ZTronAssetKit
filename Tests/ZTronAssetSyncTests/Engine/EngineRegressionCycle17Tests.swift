import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Pins from close-out cycle 17 of the level-4 close-out (`docs/adr-drafts/f.md`, F-37): a run that settled blocked for
/// lack of space while a follow-up free-space sweep still owed its parked claim a re-check. No test here moves the
/// clock; every wait is a condition, a held seam or a join that ends on cancellation (L4-R17).
@Suite("Engine regressions, close-out cycle 17")
struct EngineRegressionCycle17Tests {
    // MARK: A run waits for the claim a follow-up space sweep still owes a re-check (R-SYN-6, R-SYN-11; cycle-16 verifier)

    /// A free-space read that finds room re-queues at most `readmissionsPerTurn` of the jobs parked `insufficientSpace`,
    /// in the pump's order (prefetch before bulk), and owes the rest to a follow-up sweep, an owned task of its own. When
    /// the run's last working claim finished before that sweep, the run settled `.blocked(.insufficientSpace)` although
    /// the latest read admits its bulk claim: the claim's job was retired, no pending run was set, and the sync caller
    /// was told the volume lacks space (the cycle-16 correctness verifier's PROBE-SPACEOWED). The follow-up is held here
    /// (`holdSpaceSweepFollowUps()`), so the order is fixed.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-6: a run whose claim parked for space a follow-up free-space sweep still owes a re-check waits for it instead of settling blocked for lack of space", .timeLimit(.minutes(1)))
    func runWaitsForSpaceSweepFollowUp() async throws {
        let count = SyncEngine.readmissionsPerTurn + 8
        let reserve = StoragePolicy().reserveFreeBytes
        let time = ManualTimeSource()
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: reserve + 4_000_000, opportunisticCapacity: reserve + 4_000_000)
        )
        let harness = EngineHarness.make(
            time: time,
            tuning: SyncTuning(maxConcurrentTransfers: 4, reservedInteractiveSlots: 0),
            storage: StoragePolicy(minimumResidency: 0, deletionGrace: 60),
            fileSystem: fileSystem
        )
        let holders = (0..<2).map { EngineHarness.onDemand("h\($0)", EngineFixture.bytes(40_000 + UInt64($0), count: 300)) }
        var members: [ManifestEntry] = []
        var memberBytes: [Data] = []
        for index in 0..<count {
            let bytes = EngineFixture.bytes(41_000 + UInt64(index), count: 300)
            memberBytes.append(bytes)
            members.append(EngineHarness.onDemand("m\(index)", bytes))
        }
        await harness.serveManifest(holders + members)
        let engine = harness.engine
        try await harness.start()
        await engine.awaitCondition { $0.state.run == nil && $0.state.manifestFetch == nil && $0.state.appliedETag != nil }
        // Two prefetch holders stay in flight: with the ballast below they leave 100 bytes of headroom.
        for holder in holders {
            await harness.source.script(holder.transferID, [.hold])
        }
        let holderToken = try await engine.registerGroup(holders.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.inFlight.count == 2 }
        let ballast = try await EngineRegressionCycle6Tests.leaveRoom(700, harness: harness, fileSystem: fileSystem)
        await engine.refreshFreeSpace()
        for (member, bytes) in zip(members, memberBytes) {
            await harness.source.script(member.transferID, [.stage(bytes)])
        }
        // A prefetch group whose members (300 bytes each) do not fit the headroom: every member parks `insufficientSpace`.
        let token = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.spaceParked.count == count && !$0.state.pumpFollowUpScheduled && $0.state.laneParksOwed.isEmpty }
        let parkedStates = await engine.readForTests { engine in Set(engine.state.spaceParked.compactMap { engine.state.jobs[$0]?.state }) }
        try #require(parkedStates == [.blocked(.insufficientSpace)], "setup: every member parks insufficientSpace: \(parkedStates)")
        // A run plans two bundled entries: the small one fits the headroom the holders leave, the large one does not.
        let bytes1 = EngineFixture.bytes(42_001, count: 60)
        let bytes2 = EngineFixture.bytes(42_002, count: 300)
        let first = EngineFixture.entry("r1", bytes1)
        let second = EngineFixture.entry("r2", bytes2)
        await harness.serveManifest(holders + members + [first, second], etag: "v2")
        await harness.source.script(first.transferID, [.hold, .stage(bytes1)])
        await harness.source.script(second.transferID, [.stage(bytes2)])
        let run = Task { await engine.sync(.force) }
        await untilFinishedOrCondition(run, engine) { engine in
            engine.state.jobs[first.transferID]?.active != nil && engine.state.jobs[second.transferID]?.state == .blocked(.insufficientSpace)
        }
        let setup = await engine.readForTests { engine in
            (engine.state.jobs[first.transferID]?.active != nil, engine.state.jobs[second.transferID]?.state, engine.state.run?.id, engine.state.lastRunID)
        }
        try #require(setup.0 && setup.1 == .blocked(.insufficientSpace), "setup: r1 runs and r2 is parked for space: \(setup)")
        let runID = try #require(setup.2, "setup: the run is in progress")
        await engine.holdSpaceSweepFollowUps()
        // The volume gains room for every parked job: the read's sweep re-queues `readmissionsPerTurn` of them, prefetch
        // members first, and owes the rest, the run's bulk claim among them, to a follow-up sweep, which the hold keeps
        // waiting.
        try fileSystem.removeItem(at: ballast)
        await engine.refreshFreeSpace()
        await engine.awaitCondition { $0.state.spaceSweepFollowUpWaiting }
        let owed = await engine.readForTests { ($0.state.jobs[second.transferID]?.state, $0.state.spaceSweepFollowUp != nil) }
        try #require(owed.0 == .blocked(.insufficientSpace) && owed.1, "setup: the run's claim waits for the follow-up sweep: \(owed)")
        // The run's working claim finishes; only the claim the follow-up sweep owes a re-check is left.
        await harness.source.release(first.transferID, with: .progress(received: 1, expected: nil))
        await engine.awaitCondition { $0.state.jobs[first.transferID] == nil && $0.state.storeWorkRuns == 0 }
        let waiting = await engine.readForTests { engine in
            (engine.state.run?.id, engine.state.run?.settlement, engine.state.lastRunID, engine.state.jobs[second.transferID]?.state)
        }
        #expect(waiting.0 == runID, "the run is still in progress: \(String(describing: waiting.0))")
        #expect(waiting.1 == nil, "the run waits for the claim a follow-up sweep owes a re-check instead of settling: \(String(describing: waiting.1))")
        #expect(waiting.2 == setup.3, "no run started: \(waiting.2) after \(setup.3)")
        #expect(waiting.3 == .blocked(.insufficientSpace), "the claim's job survives, waiting for the follow-up sweep: \(String(describing: waiting.3))")
        // The follow-up sweep admits the claim; its transfer runs and the run completes.
        await engine.releaseSpaceSweepFollowUps()
        let outcome = await joinCancelling(run)
        if case .complete(let report) = outcome {
            #expect(report.fetched == 2, "the run fetched both of its assets: \(report.fetched)")
        } else {
            Issue.record("the run completes once the volume has room for its claim: \(outcome)")
        }
        await engine.releaseGroup(token)
        await engine.releaseGroup(holderToken)
        await engine.shutdown()
    }
}
