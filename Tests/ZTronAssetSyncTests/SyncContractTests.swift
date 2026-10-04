import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetSync
import ZTronAssetTestSupport

@Suite("Sync contracts")
struct SyncContractTests {
    @Test("R-SYN-2: the transition table admits exactly the listed transitions")
    func transitionTable() {
        let legal: Set<String> = [
            "queued>downloading", "queued>blocked",
            "downloading>verifying", "downloading>failed", "downloading>blocked", "downloading>queued",
            "verifying>committing", "verifying>failed", "verifying>queued",
            "committing>failed", "committing>queued",
            "failed>queued", "failed>failed",
            "blocked>queued", "blocked>blocked",
        ]
        var admitted: Set<String> = []
        for from in JobStateKind.allCases {
            for to in JobStateKind.allCases where JobStateKind.allows(from: from, to: to) {
                admitted.insert("\(from.rawValue)>\(to.rawValue)")
            }
        }
        #expect(admitted == legal)
        #expect(JobState.failed(.nextRun).allows(.queued))
        #expect(!JobState.queued.allows(.verifying))
        #expect(!JobState.blocked(.offline).allows(.downloading))
        #expect(!JobState.committing.allows(.downloading))
    }

    @Test("R-SYN-9: refresh policies decide due-ness exhaustively including app-version change and clock skew")
    func refreshDecision() {
        let completed = Date(timeIntervalSince1970: 1_000_000)
        let stamp = SyncStamp(appVersion: "2.0+5", completedAt: completed, manifestETag: nil, manifestDigest: ContentHash(w0: 1, w1: 2, w2: 3, w3: 4))
        func due(_ policy: RefreshPolicy, stamp: SyncStamp? = stamp, flag: Bool = false, version: String = "2.0+5", after seconds: TimeInterval = 10, synced: Bool = false) -> Bool {
            RefreshDecision.isSyncDue(
                policy: policy,
                stamp: stamp,
                syncDueFlag: flag,
                appVersion: version,
                now: completed.addingTimeInterval(seconds),
                syncedThisLaunch: synced
            )
        }
        for policy in [RefreshPolicy.oncePerAppVersion, .everyLaunch, .atMostEvery(3_600)] {
            #expect(due(policy, stamp: nil))
            #expect(due(policy, flag: true, synced: true))
            #expect(due(policy, version: "2.0+6", synced: true))
        }
        #expect(!due(.oncePerAppVersion))
        #expect(due(.everyLaunch))
        #expect(!due(.everyLaunch, synced: true))
        #expect(!due(.atMostEvery(3_600), after: 3_599))
        #expect(due(.atMostEvery(3_600), after: 3_600))
        #expect(!due(.atMostEvery(3_600), after: -299))
        #expect(due(.atMostEvery(3_600), after: -301))
        #expect(due(.atMostEvery(0)))
        #expect(due(.atMostEvery(.nan)))
        #expect(!due(.atMostEvery(.infinity), after: 1e12))
    }

    @Test("R-SYN-5: backoff delays are full jitter keyed by asset and attempt and reproducible from the seed")
    func backoffIsKeyedFullJitter() throws {
        let policy = RetryPolicy.background
        let seed: UInt64 = 0x5EED
        for attempt in 1...10 {
            let ceiling = min(policy.maxDelay, policy.baseDelay * pow(2, Double(attempt - 1)))
            let delay = try #require(Backoff.delay(attempt: attempt, retryAfter: nil, policy: policy, seed: seed, key: 42))
            #expect(delay >= 0 && delay <= ceiling, "seed \(seed) attempt \(attempt)")
            #expect(Backoff.delay(attempt: attempt, retryAfter: nil, policy: policy, seed: seed, key: 42) == delay)
        }
        let a = (1...8).map { Backoff.delay(attempt: $0, retryAfter: nil, policy: policy, seed: seed, key: 1) }
        let b = (1...8).map { Backoff.delay(attempt: $0, retryAfter: nil, policy: policy, seed: seed, key: 2) }
        #expect(a != b)
        #expect(try #require(Backoff.delay(attempt: 1, retryAfter: 120, policy: policy, seed: seed, key: 1)) >= 120)
        #expect(Backoff.delay(attempt: 1, retryAfter: policy.maxRetryAfter + 1, policy: policy, seed: seed, key: 1) == nil)
    }

    @available(macOS 15.0, *)
    @Test("R-ENV-1: ManualTimeSource wakes sleepers in deadline then registration order", .timeLimit(.minutes(1)))
    func manualTimeWakeOrder() async {
        let time = ManualTimeSource()
        let start = time.monotonicNow()
        var sleepers: [Task<Bool, Never>] = []
        for (index, seconds) in [3.0, 1.0, 2.0, 1.0].enumerated() {
            let deadline = start.adding(seconds: seconds)
            sleepers.append(Task {
                do {
                    try await time.sleep(until: deadline)
                    return true
                } catch {
                    return false
                }
            })
            await time.waitForSleepers(atLeast: index + 1)
        }
        #expect(time.nextDeadline == start.adding(seconds: 1))
        time.advance(by: 1.5)
        #expect(time.pendingSleepers == 2)
        time.advance(by: 5)
        var woke: [Bool] = []
        for sleeper in sleepers {
            woke.append(await sleeper.value)
        }
        #expect(woke == [true, true, true, true])
        #expect(time.wakeLog == [2, 4, 3, 1])
        #expect(time.pendingSleepers == 0)
        #expect(time.nextDeadline == nil)
    }

    @available(macOS 15.0, *)
    @Test("R-ENV-1: a cancelled ManualTimeSource sleeper throws promptly and leaves no sleeper behind", .timeLimit(.minutes(1)))
    func manualTimeCancellation() async {
        let time = ManualTimeSource()
        let deadline = time.monotonicNow().adding(seconds: 3_600)
        let sleeper = Task { () -> Bool in
            do {
                try await time.sleep(until: deadline)
                return false
            } catch {
                return true
            }
        }
        await time.waitForSleepers(atLeast: 1)
        sleeper.cancel()
        #expect(await sleeper.value)
        #expect(time.pendingSleepers == 0)
        #expect(time.wakeLog.isEmpty)
        let past = Task { () -> Bool in
            do {
                try await time.sleep(until: .zero)
                return true
            } catch {
                return false
            }
        }
        #expect(await past.value)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-1: FakeRemoteSourceFactory hands the store's staging sink to an attachable source before returning it", .timeLimit(.minutes(1)))
    func factoryAttachesStaging() async throws {
        let source = FakeRemoteSource()
        let sink = FakeStagingSink()
        #expect(await source.attachedStaging == nil)
        let made = try await FakeRemoteSourceFactory(source: source).makeRemoteSource(configuration: RemoteConfiguration(), staging: sink)
        #expect((made as? FakeRemoteSource) === source)
        #expect((await source.attachedStaging as? FakeStagingSink) === sink)
        #expect(await made.sourceCopyBytes() == 0)
        await source.setSourceCopyBytes(4_096)
        #expect(await made.sourceCopyBytes() == 4_096)
        let plain = FakeAppleLikeSource()
        let passedThrough = try await FakeRemoteSourceFactory(source: plain).makeRemoteSource(configuration: RemoteConfiguration(), staging: sink)
        #expect(passedThrough.originID == plain.originID)
    }

    @Test("Test support: observer censuses of the fake conditions and memory-pressure sources are awaited without polling", .timeLimit(.minutes(1)))
    func observerCensusWaits() async {
        let conditions = FakeDeviceConditionsSource(initial: .unrestricted)
        await conditions.waitForObservers(equalTo: 0)
        let first = Task { () -> DeviceConditions? in
            for await state in await conditions.conditions() {
                return state
            }
            return nil
        }
        #expect(await first.value == .unrestricted)
        await conditions.waitForObservers(equalTo: 0)
        let parked = Task {
            for await _ in await conditions.conditions() {}
        }
        await conditions.waitForObservers(equalTo: 1)
        #expect(await conditions.activeObservers == 1)
        parked.cancel()
        await conditions.waitForObservers(equalTo: 0)
        #expect(await conditions.activeObservers == 0)

        let pressure = FakeMemoryPressureSource()
        let received = Task { () -> MemoryPressureLevel? in
            for await level in await pressure.pressureEvents() {
                return level
            }
            return nil
        }
        await pressure.waitForObservers(equalTo: 1)
        await pressure.send(.critical)
        #expect(await received.value == .critical)
        await pressure.waitForObservers(equalTo: 0)
        #expect(await pressure.activeObservers == 0)
    }
}

/// A source that does not adopt `StagingAttachable`: the factory must return it untouched.
private struct FakeAppleLikeSource: RemoteSource {
    let originID = "apple-hosted"
    let capabilities = RemoteSourceCapabilities(tier: .appleHosted, supportsPriority: false, supportsResume: false, supportsBackground: false, keepsSourceCopies: true)

    func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        throw .offline(.noConnection)
    }

    func transfer(_ request: TransferRequest) async -> any TransferHandle {
        fatalError("not used by this test")
    }

    func reattachedTransfers() async -> [ReattachedTransfer] {
        []
    }

    func cancelTransfer(_ name: StagingFileName) async {}

    func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport {
        ReclaimReport()
    }

    func sourceCopyBytes() async -> Int64 {
        0
    }

    func handleBackgroundEvents(identifier: String) async {}

    func invalidate() async {}
}

