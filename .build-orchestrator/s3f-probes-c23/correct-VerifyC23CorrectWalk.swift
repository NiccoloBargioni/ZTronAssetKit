import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch hunting probe (s3f close-out verification, cycle 23, correctness lens, HEAD d88bdb1). Never committed.
///
/// PROBE-C23C-WALK: `EngineModelTests.randomOperations`' walk (R-SYN-2), copied, over new seeds, with three operations
/// added that the committed walk lacks: an apply of a manifest that maps 1-3 ids to another content (served too, so a run
/// fetches the same), applied beside the walk (the store's commit window moves with the clock); holding the follow's
/// follow-up turns before such an apply (swept first) and releasing them later. After every operation the invariants
/// are checked as the committed walk checks them (`idleViolations`); at the end the follow-ups are released, every
/// caller withdrawn, every group released, every transfer failing, and the clock driven until the engine is idle-silent
/// (a job that nothing advances fails the drive), then the end-state checks of the committed walk.
@Suite("Verify c23 correct walk")
struct VerifyC23CorrectWalk {
    struct Caller {
        let asset: AssetID
        let task: Task<Result<AssetLocation, AssetError>, Never>
        var cancelled = false
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C23C-WALK", .timeLimit(.minutes(10)), arguments: Array(UInt64(1)...UInt64(32)))
    func walk(_ index: UInt64) async throws {
        let seed: UInt64 = 0x2_5EED &+ index &* 7_919
        var random = SplitMix64(seed: seed)
        func pick(_ count: Int) -> Int {
            Int(random.next() % UInt64(max(1, count)))
        }
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 3), commitInterval: 0.25, installInterval: 0.1)
        var payloads: [Data] = (0..<10).map { EngineFixture.bytes(UInt64(500 + $0), count: 48) }
        payloads.append(payloads[0])
        payloads.append(payloads[1])
        let names = (0..<payloads.count).map { "m\($0)" }
        var assignment = Array(0..<payloads.count)
        func entriesFor(_ assignment: [Int]) -> [ManifestEntry] {
            assignment.enumerated().map { id, payload in
                EngineFixture.entry(names[id], payloads[payload], policy: id % 3 == 0 ? .standard : .onDemand)
            }
        }
        var entries = entriesFor(assignment)
        var payloadByTransfer: [TransferID: Data] = [:]
        for bytes in payloads {
            payloadByTransfer[EngineFixture.entry("t", bytes).transferID] = bytes
        }
        let transfers = payloadByTransfer.keys.sorted()
        await harness.serveManifest(entries)
        try await harness.start()
        let engine = harness.engine
        let source = harness.source
        var callers: [Caller] = []
        var groups: [InterestToken] = []
        var runs: [Task<SyncOutcome, Never>] = []
        var reports: [Task<Void, Never>] = []
        var applies: [Task<Void, Never>] = []
        var held = false
        var appliesMade = 0
        var log: [String] = []
        let lanes: [AssetPriority] = [.bulk, .prefetch, .userInitiated]
        let failures: [TransferError] = [
            .offline(.noConnection),
            .transient(.timedOut, retryAfter: nil),
            .transient(.serverError(httpStatus: 503), retryAfter: nil),
            .transient(.throttled, retryAfter: .seconds(1)),
            .transient(.resumeRejected, retryAfter: nil),
            .integrity(.truncated(expected: 48, received: 10)),
            .rejected(.unexpectedStatus(400)),
            .cancelled(.bySystem(.insufficientSystemResources)),
            .permanentMissing(httpStatus: 404),
        ]
        let conditions: [DeviceConditions] = [
            .unrestricted,
            DeviceConditions(network: NetworkConditions(satisfied: false, expensive: false, constrained: false), power: PowerConditions(lowPowerMode: false, thermal: .nominal)),
            DeviceConditions(network: NetworkConditions(satisfied: true, expensive: true, constrained: true), power: PowerConditions(lowPowerMode: true, thermal: .serious)),
        ]
        var failed = false
        for operation in 0..<3_000 {
            guard !Task.isCancelled else {
                break
            }
            if operation % 64 == 0 {
                await Task.yield()
            }
            let choice = pick(112)
            switch choice {
            case 0..<30:
                let entry = entries[pick(entries.count)]
                let lane = lanes[pick(lanes.count)]
                callers.append(Caller(asset: entry.identifier, task: Task { await engine.awaitAsset(entry.identifier, lane: lane) }))
            case 30..<45:
                let live = callers.indices.filter { !callers[$0].cancelled }
                if !live.isEmpty {
                    let index = live[pick(live.count)]
                    callers[index].cancelled = true
                    callers[index].task.cancel()
                }
            case 45..<52:
                let ids = (0..<3).map { _ in entries[pick(entries.count)].identifier }
                if let token = try? await engine.registerGroup(ids, lane: .prefetch).get() {
                    groups.append(token)
                }
            case 52..<57:
                if !groups.isEmpty {
                    await engine.releaseGroup(groups.remove(at: pick(groups.count)))
                }
            case 57..<72:
                let transfer = transfers[pick(transfers.count)]
                if let bytes = payloadByTransfer[transfer] {
                    await source.script(transfer, [.stage(bytes)])
                }
            case 72..<82:
                await source.release(transfers[pick(transfers.count)], with: .failed(failures[pick(failures.count)]))
            case 82..<87:
                await harness.conditions.send(conditions[pick(conditions.count)])
            case 87..<95:
                harness.time.advance(by: Double(pick(2_000)) / 1_000)
            case 95..<98:
                if runs.count < 40 {
                    runs.append(Task { await engine.sync(.force) })
                }
            case 98..<100:
                let entry = entries[pick(entries.count)]
                if reports.count < 40 {
                    if pick(2) == 0 {
                        reports.append(Task { _ = await engine.reportUnreadable(entry.identifier) })
                    } else {
                        let request: PurgeRequest = pick(4) == 0 ? .evictable : .scope(.identifiers([entry.identifier]))
                        reports.append(Task { _ = await engine.purge(request) })
                    }
                }
            case 100..<106:
                if applies.count < 60 {
                    for _ in 0...pick(3) {
                        assignment[pick(assignment.count)] = pick(payloads.count)
                    }
                    entries = entriesFor(assignment)
                    appliesMade += 1
                    let manifest = try ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data("c23-walk-\(seed)-\(operation)".utf8)))
                    await harness.serveManifest(entries, etag: "w\(operation)")
                    if !held, pick(2) == 0 {
                        held = true
                        await engine.readForTests { $0.holdFollowFollowUps() }
                    }
                    log.append("op \(operation): apply \(assignment) held=\(held)")
                    applies.append(Task { _ = await engine.applyAndFollow(manifest, etag: nil, eviction: nil) })
                }
            default:
                if held {
                    held = false
                    await engine.readForTests { $0.releaseFollowFollowUps() }
                    log.append("op \(operation): release follow-ups")
                }
            }
            let violations = await harness.idleViolations().violations
            if !violations.isEmpty {
                Issue.record("PROBE-C23C-WALK seed \(seed) operation \(operation) choice \(choice): \(violations.prefix(4)); last applies \(log.suffix(4))")
                failed = true
                break
            }
        }
        if held {
            await engine.readForTests { $0.releaseFollowFollowUps() }
        }
        await harness.conditions.send(.unrestricted)
        for index in callers.indices where !callers[index].cancelled {
            callers[index].cancelled = true
            callers[index].task.cancel()
        }
        for token in groups {
            await engine.releaseGroup(token)
        }
        for transfer in transfers {
            await source.script(transfer, Array(repeating: .fail(.rejected(.unexpectedStatus(400))), count: 16))
        }
        do {
            try await harness.drive(advances: 8_192) { $0.isIdleSilent }
        } catch {
            let state = await engine.introspect()
            let follow = await engine.readForTests { e in "barrier \(e.followBarrier) owed \(e.followOwed) held \(e.state.followFollowUpsHeld) jobs \(e.state.jobs.count) waiters \(e.state.waiters.count)" }
            Issue.record("PROBE-C23C-WALK seed \(seed): not idle-silent after the drive: \(error); \(state); \(follow); last \(log.suffix(4))")
            failed = true
        }
        let idle = await harness.idleViolations()
        if !idle.violations.isEmpty {
            Issue.record("PROBE-C23C-WALK seed \(seed) at idle: \(idle.violations.prefix(4))")
            failed = true
        }
        await engine.shutdown()
        for caller in callers {
            let result = await caller.task.value
            switch result {
            case .success(let location):
                if location.id != caller.asset {
                    Issue.record("PROBE-C23C-WALK seed \(seed): a caller got another asset")
                }
            case .failure(.cancelled):
                if !caller.cancelled {
                    Issue.record("PROBE-C23C-WALK seed \(seed): an uncancelled caller got cancelled")
                }
            case .failure:
                break
            }
        }
        for run in runs {
            _ = await run.value
        }
        for report in reports {
            await report.value
        }
        for apply in applies {
            await apply.value
        }
        let state = await engine.introspect()
        if !(state.ownedTasks == 0 && state.waiters == 0 && state.interests == 0) {
            Issue.record("PROBE-C23C-WALK seed \(seed): after shutdown \(state)")
        }
        let end = await engine.invariantViolations()
        if !end.isEmpty {
            Issue.record("PROBE-C23C-WALK seed \(seed) after shutdown: \(end.prefix(4))")
        }
        print("PROBE-C23C-WALK seed \(seed): applies \(appliesMade), callers \(callers.count), groups left \(groups.count), failed \(failed)")
    }
}
