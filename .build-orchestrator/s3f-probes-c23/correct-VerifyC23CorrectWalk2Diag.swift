import Foundation
import Testing
import ZTronAssetModel
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// Scratch hunting probe (s3f close-out verification, cycle 23, correctness lens, HEAD d88bdb1). Never committed.
///
/// PROBE-C23C-WALK2 (a heavier variant: 24 ids over 16 contents, more applies, drain holds, ENOSPC failures, purges of
/// everything, and on odd seeds a liveness ending: every transfer serves, the clock is driven to idle silence, and no
/// uncancelled caller may still wait). PROBE-C23C-WALK: `EngineModelTests.randomOperations`' walk (R-SYN-2), copied, over new seeds, with three operations
/// added that the committed walk lacks: an apply of a manifest that maps 1-3 ids to another content (served too, so a run
/// fetches the same), applied beside the walk (the store's commit window moves with the clock); holding the follow's
/// follow-up turns before such an apply (swept first) and releasing them later. After every operation the invariants
/// are checked as the committed walk checks them (`idleViolations`); at the end the follow-ups are released, every
/// caller withdrawn, every group released, every transfer failing, and the clock driven until the engine is idle-silent
/// (a job that nothing advances fails the drive), then the end-state checks of the committed walk.
/// PROBE-C23C-WALK2-DIAG: the hung even seeds of PROBE-C23C-WALK2 again, with stage lines on stderr and a bounded
/// drive (a wall-clock watchdog, diagnosis only) that dumps the engine, the fake source and the clock when stuck, then
/// scripts 64 more failures per transfer and drives again (does the drive end once the fake has steps?).
@Suite("Verify c23 correct walk2 diag")
struct VerifyC23CorrectWalk2Diag {
    struct Caller {
        let asset: AssetID
        let task: Task<Result<AssetLocation, AssetError>, Never>
        var cancelled = false
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("PROBE-C23C-WALK2-DIAG", .timeLimit(.minutes(12)), arguments: [UInt64(102), 104, 106, 112, 116, 120, 122, 128])
    func walk(_ index: UInt64) async throws {
        func stage(_ text: String) {
            FileHandle.standardError.write(Data("DIAG \(index) \(text)\n".utf8))
        }
        stage("begin")
        let seed: UInt64 = 0x2_5EED &+ index &* 7_919
        var random = SplitMix64(seed: seed)
        func pick(_ count: Int) -> Int {
            Int(random.next() % UInt64(max(1, count)))
        }
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 3), commitInterval: 0.25, installInterval: 0.1)
        let payloads: [Data] = (0..<16).map { EngineFixture.bytes(UInt64(500 + $0), count: 48) }
        let names = (0..<24).map { "m\($0)" }
        var assignment = (0..<24).map { $0 % 16 }
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
        var drainHeld = false
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
            .insufficientSpace(requiredBytes: 48),
            .insufficientSpace(requiredBytes: nil),
        ]
        let conditions: [DeviceConditions] = [
            .unrestricted,
            DeviceConditions(network: NetworkConditions(satisfied: false, expensive: false, constrained: false), power: PowerConditions(lowPowerMode: false, thermal: .nominal)),
            DeviceConditions(network: NetworkConditions(satisfied: true, expensive: true, constrained: true), power: PowerConditions(lowPowerMode: true, thermal: .serious)),
        ]
        var failed = false
        for operation in 0..<6_000 {
            guard !Task.isCancelled else {
                break
            }
            if operation % 64 == 0 {
                await Task.yield()
            }
            let choice = pick(120)
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
                        let roll = pick(8)
                        let request: PurgeRequest = roll == 0 ? .all : (roll < 3 ? .evictable : .scope(.identifiers([entry.identifier])))
                        reports.append(Task { _ = await engine.purge(request) })
                    }
                }
            case 100..<110:
                if applies.count < 400 {
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
            case 110..<115:
                if held {
                    held = false
                    await engine.readForTests { $0.releaseFollowFollowUps() }
                    log.append("op \(operation): release follow-ups")
                }
            default:
                if drainHeld {
                    drainHeld = false
                    await engine.readForTests { $0.releaseDrainFollowUps() }
                    log.append("op \(operation): release drain follow-ups")
                } else {
                    drainHeld = true
                    await engine.readForTests { $0.holdDrainFollowUps() }
                    log.append("op \(operation): hold drain follow-ups")
                }
            }
            let violations = await harness.idleViolations().violations
            if !violations.isEmpty {
                Issue.record("PROBE-C23C-WALK2-DIAG seed \(seed) operation \(operation) choice \(choice): \(violations.prefix(4)); last applies \(log.suffix(4))")
                failed = true
                break
            }
        }
        await engine.readForTests { e in
            e.releaseFollowFollowUps()
            e.releaseDrainFollowUps()
        }
        await harness.conditions.send(.unrestricted)
        let liveness = index % 2 == 1
        if !liveness {
            for index in callers.indices where !callers[index].cancelled {
                callers[index].cancelled = true
                callers[index].task.cancel()
            }
        }
        for token in groups {
            await engine.releaseGroup(token)
        }
        for transfer in transfers {
            if liveness, let bytes = payloadByTransfer[transfer] {
                await source.script(transfer, Array(repeating: .stage(bytes), count: 16))
            } else {
                await source.script(transfer, Array(repeating: .fail(.rejected(.unexpectedStatus(400))), count: 16))
            }
        }
        func boundedDrive(_ label: String) async -> String {
            let engine = harness.engine
            let time = harness.time
            let outcome = await withTaskGroup(of: String.self) { group in
                group.addTask {
                    do {
                        try await harness.drive(advances: 8_192) { $0.isIdleSilent }
                        return "idle"
                    } catch {
                        return "error \(error)"
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(75))
                    return "watchdog"
                }
                let first = await group.next() ?? "none"
                group.cancelAll()
                return first
            }
            if outcome != "idle" {
                let state = await engine.introspect()
                let active = await source.activeTransfers
                let starts = await source.starts
                var perID: [TransferID: Int] = [:]
                for request in starts {
                    perID[request.id, default: 0] += 1
                }
                let detail = await engine.readForTests { e -> String in
                    var kinds: [String: Int] = [:]
                    for job in e.state.jobs.values {
                        kinds[String(describing: job.state.kind), default: 0] += 1
                    }
                    let fence = e.clockFence().map { "\($0)" } ?? "nil"
                    return "barrier \(e.followBarrier) owed \(e.followOwed) held \(e.state.followFollowUpsHeld) jobs \(kinds) waiters \(e.state.waiters.count) unknown \(e.state.unknownWaiters.count) groups \(e.state.groups.count) fence \(fence) sleepers \(time.pendingSleepers) next \(time.nextDeadline.map { "\($0)" } ?? "nil") now \(time.monotonicNow())"
                }
                stage("STUCK \(label): \(outcome); active transfers \(active); starts per id max \(perID.values.max() ?? 0) total \(starts.count); \(detail); \(state)")
            } else {
                stage("drive \(label): idle")
            }
            return outcome
        }
        func snapshot(_ label: String) async {
            let time = harness.time
            let detail = await harness.engine.readForTests { e -> String in
                "applyTurnHeld \(e.state.applyTurnHeld) applyQueue \(e.state.applyQueue.count) running \(e.isRunning) sleepers \(time.pendingSleepers) next \(time.nextDeadline.map { "\($0)" } ?? "nil") now \(time.monotonicNow())"
            }
            stage("SNAP \(label): \(detail)")
        }
        /// Runs `work` against a 30 s wall-clock watchdog (diagnosis only); on the watchdog, advances the manual clock
        /// by 1 s up to 40 times, reporting after each advance, until `work` ends.
        func watched(_ label: String, _ work: @escaping @Sendable () async -> Void) async {
            let time = harness.time
            let finished = ManagedFlag()
            let task = Task {
                await work()
                finished.set()
            }
            for _ in 0..<60 {
                if finished.isSet { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if finished.isSet {
                stage("\(label): done without advancing the clock")
                return
            }
            await snapshot("\(label) stuck before any advance")
            for advance in 1...40 {
                time.advance(by: 1)
                for _ in 0..<10 {
                    if finished.isSet { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if finished.isSet {
                    stage("\(label): done after \(advance) clock advance(s) of 1 s")
                    return
                }
            }
            await snapshot("\(label) STILL STUCK after 40 s of clock")
            _ = task
        }
        stage("ending: drive 1")
        let outcome1 = await boundedDrive("first")
        if outcome1 != "idle" {
            for transfer in transfers {
                await source.script(transfer, Array(repeating: .fail(.rejected(.unexpectedStatus(400))), count: 64))
            }
            stage("ending: drive 2 after 64 more failures per transfer")
            _ = await boundedDrive("second")
        }
        do {
            if outcome1 != "idle" { throw CancellationError() }
        } catch {
            let state = await engine.introspect()
            let follow = await engine.readForTests { e in "barrier \(e.followBarrier) owed \(e.followOwed) held \(e.state.followFollowUpsHeld) jobs \(e.state.jobs.count) waiters \(e.state.waiters.count)" }
            Issue.record("PROBE-C23C-WALK2-DIAG seed \(seed): not idle-silent after the drive: \(error); \(state); \(follow); last \(log.suffix(4))")
            failed = true
        }
        await snapshot("after the drive")
        stage("idle check")
        let idle = await harness.idleViolations()
        if !idle.violations.isEmpty {
            Issue.record("PROBE-C23C-WALK2-DIAG seed \(seed) at idle: \(idle.violations.prefix(4))")
            failed = true
        }
        let stuck = await engine.readForTests { e in (waiters: e.state.waiters.count, unknown: e.state.unknownWaiters.count, jobs: e.state.jobs.count, groups: e.state.groups.count) }
        if liveness, stuck.waiters + stuck.unknown > 0 {
            Issue.record("PROBE-C23C-WALK2-DIAG seed \(seed): idle-silent with callers still waiting: \(stuck); last \(log.suffix(4))")
        }
        stage("shutdown begin")
        await watched("shutdown") { await engine.shutdown() }
        await snapshot("after the shutdown")
        for caller in callers where liveness && !caller.cancelled {
            if await caller.task.value == .failure(.shutDown) {
                Issue.record("PROBE-C23C-WALK2-DIAG seed \(seed): an uncancelled caller for \(caller.asset) was answered only by the shutdown")
            }
        }
        stage("awaiting \(callers.count) callers")
        for (number, caller) in callers.enumerated() {
            if number % 200 == 0 { stage("caller \(number)") }
            let result = await caller.task.value
            switch result {
            case .success(let location):
                if location.id != caller.asset {
                    Issue.record("PROBE-C23C-WALK2-DIAG seed \(seed): a caller got another asset")
                }
            case .failure(.cancelled):
                if !caller.cancelled {
                    Issue.record("PROBE-C23C-WALK2-DIAG seed \(seed): an uncancelled caller got cancelled")
                }
            case .failure:
                break
            }
        }
        stage("awaiting \(runs.count) runs")
        for run in runs {
            _ = await run.value
        }
        stage("awaiting \(reports.count) reports")
        for report in reports {
            await report.value
        }
        stage("awaiting \(applies.count) applies")
        let appliesCopy = applies
        await watched("applies") {
            for apply in appliesCopy {
                await apply.value
            }
        }
        for apply in applies {
            await apply.value
        }
        stage("all awaited")
        let state = await engine.introspect()
        if !(state.ownedTasks == 0 && state.waiters == 0 && state.interests == 0) {
            Issue.record("PROBE-C23C-WALK2-DIAG seed \(seed): after shutdown \(state)")
        }
        let end = await engine.invariantViolations()
        if !end.isEmpty {
            Issue.record("PROBE-C23C-WALK2-DIAG seed \(seed) after shutdown: \(end.prefix(4))")
        }
        print("PROBE-C23C-WALK2-DIAG seed \(seed) liveness \(liveness): applies \(appliesMade), callers \(callers.count), groups left \(groups.count), failed \(failed)")
    }
}


/// A one-way flag shared with a watched task (diagnosis only).
final class ManagedFlag: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var value = false
    func set() {
        self.lock.lock()
        self.value = true
        self.lock.unlock()
    }
    var isSet: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }
}
