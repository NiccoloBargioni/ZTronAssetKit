import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Pins from the verifiers of close-out cycle 11 (cycle 12 of the level-4 close-out; `docs/adr-drafts/f.md`, F-32).
@Suite("Engine regressions, close-out cycle 12")
struct EngineRegressionCycle12Tests {
    // MARK: restoreAside merges by place (R-SYN-3; review of close-out cycle 11, mutant RESTOREPREPEND)

    /// `LaneQueues.restoreAside` puts the valid set-aside entries back at their places, merged with what entered the
    /// queue after the scan, instead of prepending them. The two differ only when an entry with a lower place entered
    /// the queue meanwhile: a preempted job pushed to the front (`push(front:)`, which precedes every place) must stay
    /// ahead of the entries the scan set aside, and a later append must stay behind them. Prepending the set-aside
    /// entries (mutant RESTOREPREPEND, the code before close-out cycle 11) dispatches them before the preempted job.
    @Test("R-SYN-3: restoring set-aside lane-queue entries merges them by place, behind a front push made after the scan")
    func restoreAsideMergesByPlace() {
        var queues = LaneQueues()
        let now = MonotonicInstant(nanoseconds: 1)
        func entry(_ ticket: UInt64) -> LaneQueues.Entry {
            LaneQueues.Entry(ticket: ticket, transfer: EngineUnitTests.transfer(Int(ticket)), queuedAt: now)
        }
        for ticket in UInt64(1)...3 {
            queues.push(entry(ticket), to: .prefetch)
        }
        var live = Set<UInt64>(1...3)
        let isValid: (LaneQueues.Entry) -> Bool = { live.contains($0.ticket) }
        // A scan that finds 3 sets 1 and 2 aside on the way (their jobs only released groups want) and leaves 3 queued.
        let found = queues.peek(.prefetch, isValid: isValid, setAside: { $0.ticket <= 2 }, accept: { $0.ticket == 3 })
        #expect(found?.ticket == 3)
        #expect(queues.asideEntries.map(\.ticket) == [1, 2], "setup: the scan set 1 and 2 aside in queue order")
        // After the scan, a preempted job resumes at the front and new work is appended.
        queues.push(entry(9), to: .prefetch, front: true)
        queues.push(entry(4), to: .prefetch)
        live.formUnion([9, 4])
        queues.restoreAside(isValid: isValid)
        #expect(queues.asideEntries.isEmpty)
        let order = (0..<5).compactMap { _ in queues.pop(.prefetch, isValid: isValid)?.ticket }
        #expect(order == [9, 1, 2, 3, 4], "the front push first, then the restored entries at their places: \(order)")
        #expect(queues.pop(.prefetch, isValid: isValid) == nil)
    }

    // MARK: The model over releases that span several turns (R-SYN-2, R-SYN-3; review of close-out cycle 11)

    /// A handle the oracle tracks: its members, a window of the catalogue.
    struct Handle {
        let token: InterestToken
        let members: Range<Int>
        let lane: AssetPriority
    }

    /// PROBE-C11C-2 as a test. `EngineModelTests.randomOperations` registers handles of three members, never more than
    /// `releasesPerTurn`, so its operations never reach a release that spans several turns, the scan's set-aside, its
    /// restoration or a re-joined member's `reinstate`. Here seeded random operations register and release overlapping
    /// handles of up to the whole catalogue (`2 × releasesPerTurn + 100` on-demand entries, three slots, every transfer
    /// held until the end): a release awaited alone, a release with interests re-joining its members in the same actor
    /// turn (system interests, the synchronous stand-in for a second handle's join), a release racing a registration over
    /// the same members, and callers at every lane. A release cancels its running members, so slots free and scans meet
    /// the members only released handles want while the release continues. Each registration's join (batched over
    /// several turns) is awaited, so the handles released later are the size the seed chose; nothing is present before
    /// the end, so a join is complete when every member joined. Every engine invariant is checked after every operation
    /// (a re-joined member that waits in no queue among them, which a `reinstate` that queues no entry produces); every
    /// interleaving keeps them. The end is liveness: every handle released, then every job left and every caller's
    /// asset scripted to stage, the engine ends with no job and nothing left to release, and every caller gets its
    /// asset.
    @available(macOS 15.0, iOS 18.0, *)
    @Test(
        "R-SYN-3: seeded random releases and re-joins of overlapping handles larger than one release turn keep every engine invariant and leave no job",
        .timeLimit(.minutes(1)),
        arguments: [UInt64(0x12_01), 0x12_02, 0x12_03, 0x12_04]
    )
    func randomReleasesAndRejoins(seed: UInt64) async throws {
        var random = SplitMix64(seed: seed)
        func pick(_ count: Int) -> Int {
            Int(random.next() % UInt64(max(1, count)))
        }
        let count = 2 * SyncEngine.releasesPerTurn + 100
        let payloads = (0..<count).map { EngineFixture.bytes(12_000 + UInt64($0), count: 48) }
        // Zero-padded, so a handle's join order (its sorted identifiers) is the catalogue's order.
        let entries = payloads.enumerated().map { index, bytes in EngineHarness.onDemand(String(format: "r%04d", index), bytes) }
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 3), seed: seed)
        let engine = harness.engine
        let source = harness.source
        await harness.serveManifest(entries)
        try await harness.start()
        _ = try #require(await engine.sync(.force).completeReport)
        let lanes: [AssetPriority] = [.prefetch, .bulk]
        var handles: [Handle] = []
        var callers: [(asset: AssetID, task: Task<Result<AssetLocation, AssetError>, Never>)] = []
        func window() -> Range<Int> {
            // Half the windows exceed one release turn.
            let length = pick(2) == 0 ? 1 + pick(SyncEngine.releasesPerTurn) : SyncEngine.releasesPerTurn + 1 + pick(count - SyncEngine.releasesPerTurn)
            let start = pick(count - length + 1)
            return start..<(start + length)
        }
        func register(_ members: Range<Int>, lane: AssetPriority) async throws -> Handle {
            let token = try await engine.registerGroup(members.map { entries[$0].identifier }, lane: lane).get()
            return Handle(token: token, members: members, lane: lane)
        }
        /// Until the handle's join ended: every member joined (nothing is present yet), or the handle was released.
        func joined(_ handle: Handle) async {
            let count = handle.members.count
            await engine.awaitCondition { engine in
                engine.state.groups[handle.token].map { $0.joined.count == count } ?? true
            }
        }
        for operation in 0..<100 {
            switch pick(100) {
            case 0..<30:
                let handle = try await register(window(), lane: lanes[pick(lanes.count)])
                await joined(handle)
                handles.append(handle)
            case 30..<45:
                if !handles.isEmpty {
                    await engine.releaseGroup(handles.remove(at: pick(handles.count)).token)
                }
            case 45..<70:
                // A release and, in the same actor turn, interests at its lane for some of its members: the largest
                // handle, and members its first release turn does not reach when it spans several turns and no live
                // handle holds (so only released handles want them when the interests arrive, `reinstate`).
                if let largest = handles.indices.max(by: { handles[$0].members.count < handles[$1].members.count }) {
                    let handle = handles.remove(at: largest)
                    let skipped = handle.members.count > SyncEngine.releasesPerTurn ? SyncEngine.releasesPerTurn : 0
                    let unreached = (handle.members.lowerBound + skipped)..<handle.members.upperBound
                    let alone = unreached.filter { member in !handles.contains { $0.members.contains(member) } }
                    let candidates = alone.isEmpty ? Array(unreached) : alone
                    let rejoined = (0..<(1 + pick(8))).map { _ in entries[candidates[pick(candidates.count)]] }
                    await engine.readForTests { engine in
                        engine.performReleaseGroup(handle.token)
                        for entry in rejoined {
                            engine.addSystemInterest(entry: entry, lane: handle.lane)
                        }
                    }
                }
            case 70..<88:
                // A release racing a registration over overlapping members at the same lane.
                if !handles.isEmpty {
                    let handle = handles.remove(at: pick(handles.count))
                    let overlap = handle.members.clamped(to: window())
                    let members = overlap.isEmpty ? handle.members : overlap
                    let release = Task {
                        await engine.releaseGroup(handle.token)
                    }
                    let join = Task {
                        try await engine.registerGroup(members.map { entries[$0].identifier }, lane: handle.lane).get()
                    }
                    await release.value
                    let rejoined = Handle(token: try await join.value, members: members, lane: handle.lane)
                    await joined(rejoined)
                    handles.append(rejoined)
                }
            default:
                let entry = entries[pick(count)]
                let lane: AssetPriority = [.bulk, .prefetch, .userInitiated][pick(3)]
                callers.append((entry.identifier, Task { await engine.awaitAsset(entry.identifier, lane: lane) }))
            }
            let violations = await engine.invariantViolations()
            #expect(violations.isEmpty, "seed \(seed) operation \(operation): \(violations)")
            if !violations.isEmpty {
                // A broken engine may never become idle: the liveness half below would only wait out the time limit.
                await engine.shutdown()
                return
            }
        }
        for handle in handles {
            await engine.releaseGroup(handle.token)
        }
        // Once every release ended, only the jobs other interests want are left (system interests, callers); those and
        // every caller's asset (a caller's task may reach the engine only now) are scripted to stage. Spare steps: an
        // attempt cancelled after its stage, or a caller's job created after the first commit, stages too.
        await engine.awaitCondition { $0.state.releasing.isEmpty && !$0.state.releaseFollowUpScheduled }
        let left = await engine.readForTests { Set($0.state.jobs.keys) }
        let callerTransfers = Set(callers.compactMap { caller in entries.first { $0.identifier == caller.asset }?.transferID })
        for (index, entry) in entries.enumerated() where left.contains(entry.transferID) || callerTransfers.contains(entry.transferID) {
            await source.script(entry.transferID, Array(repeating: .stage(payloads[index]), count: 3))
        }
        // Liveness: the wait ends only when the engine holds no job and owes no release (or at the time limit). A caller
        // whose task reaches the engine only now finds its asset present, or its new job stages at once.
        await engine.awaitCondition { $0.state.jobs.isEmpty && $0.state.releasing.isEmpty && !$0.state.releaseFollowUpScheduled }
        guard !Task.isCancelled else {
            // The time limit ended the wait: the shutdown answers every caller, so no join below outlives the test.
            await engine.shutdown()
            return
        }
        for caller in callers {
            let result = await caller.task.value
            #expect(try result.get().id == caller.asset, "seed \(seed): \(result)")
        }
        let violations = await engine.invariantViolations()
        #expect(violations.isEmpty, "seed \(seed): \(violations)")
        await engine.shutdown()
    }
}
