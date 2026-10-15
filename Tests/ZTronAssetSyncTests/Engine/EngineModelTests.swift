import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

/// The model-based test of the state machine (R-SYN-2, H-5; sync.md §15.2): seeded random operations against the real
/// engine, store and fakes, with the engine invariants checked after every operation and every caller's answer
/// checked against a trivial oracle.
@Suite("Engine model")
struct EngineModelTests {
    /// One caller the oracle tracks.
    struct Caller {
        let asset: AssetID
        let task: Task<Result<AssetLocation, AssetError>, Never>
        var cancelled = false
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-2: 10,000 seeded random operations never leave the transition table and keep every engine invariant", .timeLimit(.minutes(1)))
    func randomOperations() async throws {
        let seed: UInt64 = 0x2_5EED
        var random = SplitMix64(seed: seed)
        func pick(_ count: Int) -> Int {
            Int(random.next() % UInt64(max(1, count)))
        }
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 3), commitInterval: 0.25, installInterval: 0.1)
        var payloads: [Data] = (0..<10).map { EngineFixture.bytes(UInt64(500 + $0), count: 48) }
        payloads.append(payloads[0])
        payloads.append(payloads[1])
        let entries = payloads.enumerated().map { index, bytes in
            EngineFixture.entry("m\(index)", bytes, policy: index % 3 == 0 ? .standard : .onDemand)
        }
        let transfers = entries.map(\.transferID)
        let byTransfer = Dictionary(entries.map { ($0.transferID, $0) }, uniquingKeysWith: { first, _ in first })
        await harness.serveManifest(entries)
        try await harness.start()
        let engine = harness.engine
        let source = harness.source
        var callers: [Caller] = []
        var groups: [InterestToken] = []
        var runs: [Task<SyncOutcome, Never>] = []
        var reports: [Task<Void, Never>] = []
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
        ]
        let conditions: [DeviceConditions] = [
            .unrestricted,
            DeviceConditions(network: NetworkConditions(satisfied: false, expensive: false, constrained: false), power: PowerConditions(lowPowerMode: false, thermal: .nominal)),
            DeviceConditions(network: NetworkConditions(satisfied: true, expensive: true, constrained: true), power: PowerConditions(lowPowerMode: true, thermal: .serious)),
        ]
        for operation in 0..<10_000 {
            if operation % 64 == 0 {
                await Task.yield()
            }
            switch pick(100) {
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
                if let entry = byTransfer[transfer], let index = entries.firstIndex(of: entry) {
                    await source.script(transfer, [.stage(payloads[index])])
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
            default:
                // Commands that wait for the store's commit window run beside the operations (the clock moves in them).
                let entry = entries[pick(entries.count)]
                if reports.count < 40 {
                    if pick(2) == 0 {
                        reports.append(Task { _ = await engine.reportUnreadable(entry.identifier) })
                    } else {
                        // A purge withdraws the prefetch interests in what it purges, groups included (member ⇒ interest).
                        let request: PurgeRequest = pick(4) == 0 ? .evictable : .scope(.identifiers([entry.identifier]))
                        reports.append(Task { _ = await engine.purge(request) })
                    }
                }
            }
            let violations = await engine.invariantViolations()
            #expect(violations.isEmpty, "seed \(seed) operation \(operation): \(violations)")
            if !violations.isEmpty {
                break
            }
        }
        await engine.shutdown()
        for caller in callers {
            let result = await caller.task.value
            switch result {
            case .success(let location):
                #expect(location.id == caller.asset, "seed \(seed): a caller got another asset")
            case .failure(.cancelled):
                #expect(caller.cancelled, "seed \(seed): an uncancelled caller got cancelled")
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
        let metrics = try? await engine.metrics().get()
        #expect(metrics == nil, "every API fails after shutdown")
        let state = await engine.introspect()
        #expect(state.ownedTasks == 0 && state.waiters == 0 && state.interests == 0, "seed \(seed)")
        #expect(await engine.invariantViolations().isEmpty, "seed \(seed)")
    }
}
