import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

/// The C2 pins of Stage 3 close-out cycle 21 (ruling S3-R26 items 2 to 4 and 12; the cycle-20 verifiers' correct #5
/// and reqs #10): the commit's own turn in four groupings (`commitTurns`). Each figure is printed with the host's load
/// averages, which S3-R23 asks for beside every timing figure.
extension ZTronAssetKitBenchmarks.SyncBenchmarks {
    /// C2 of a commit that binds and answers 10,000 ids (`SyncBench.commitTurn`; ruling S3-R26 item 4, the cycle-20
    /// verifiers' correct #5 and reqs #10), in four groupings: a user waiter per id, the same with a stalled subscriber,
    /// one prefetch group with a stalled subscriber, and 10,000 one-member prefetch groups. The heartbeat over the commit
    /// is the gate, best of three against C2; the commit's own turn is also timed inside the actor
    /// (`EngineState.commitTurnMarksForTests`), which decides item 4's Phase 2 trigger (7.0 ms).
    @Test("R-SYN-11: a commit that binds and answers 10,000 ids holds the engine's actor at most C2's 10 ms", .timeLimit(.minutes(10)), arguments: CommitShape.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func commitTurns(_ shape: CommitShape) async throws {
        _ = try await SyncBench.commitTurn(count: 1_000, shape: shape)
        var runs: [CommitRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.commitTurn(count: 10_000, shape: shape))
        }
        for run in runs {
            #expect(run.ids == 10_000 && run.interests == shape.interests(10_000) && run.served && run.committed, "setup: the commit bound and answered every id: \(run)")
            #expect(shape.subscribers == 0 || run.buffered >= 10_000, "setup: the stalled subscriber held a slot per id: \(run)")
        }
        let waits = runs.map(\.wait)
        let turns = runs.map(\.turn)
        print("R-SYN-11 commitTurns \(shape.rawValue) at 10,000: heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms (budget \(Self.c2Budget) ms best); the commit's own turn \(turns) ms, best \(turns.min() ?? .infinity) ms (Phase 2 trigger 7.0 ms); runs \(runs)")
        #expect((waits.min() ?? .infinity) <= Self.c2Budget, "\(waits)")
    }

    /// The cost of a second stalled subscriber at a commit of 10,000 user waiters, measured once (ruling S3-R26 item
    /// 12, answer 4): the reference set has one subscriber, so this figure is recorded, not gated; a miss of C2 at a load
    /// of 10 or less is reported "open, for the owner". The setup is checked as in `commitTurns`.
    @Test("R-SYN-11: a commit that answers 10,000 user waiters with two stalled subscribers, measured once (S3-R26 answer 4)", .timeLimit(.minutes(10)))
    @available(macOS 15.0, iOS 18.0, *)
    func commitTwoStalledSubscribersTurns() async throws {
        _ = try await SyncBench.commitTurn(count: 1_000, shape: .waitersStalledSubscriber, subscribers: 2)
        var runs: [CommitRun] = []
        for _ in 0..<3 {
            runs.append(try await SyncBench.commitTurn(count: 10_000, shape: .waitersStalledSubscriber, subscribers: 2))
        }
        for run in runs {
            #expect(run.ids == 10_000 && run.interests == 10_000 && run.served && run.committed && run.buffered >= 20_000, "setup: the commit answered every waiter and each subscriber held a slot per id: \(run)")
        }
        let waits = runs.map(\.wait)
        let turns = runs.map(\.turn)
        print("R-SYN-11 commitTurns waiters with two stalled subscribers at 10,000 (recorded, not gated): heartbeat \(waits) ms, best \(waits.min() ?? .infinity) ms; the commit's own turn \(turns) ms, best \(turns.min() ?? .infinity) ms; runs \(runs)")
    }
}

/// The groupings of `SyncBench.commitTurn` (ruling S3-R26 item 4; `integrate-c21.md` item C's pins).
enum CommitShape: String, Sendable, CaseIterable {
    /// A user waiter per id.
    case waiters
    /// A user waiter per id, and a subscriber that reads nothing.
    case waitersStalledSubscriber
    /// One prefetch group of every id, and a subscriber that reads nothing.
    case groupStalledSubscriber
    /// One one-member prefetch group per id.
    case manyGroups

    /// The interests H's job holds at the commit, for `count` ids.
    func interests(_ count: Int) -> Int {
        self == .groupStalledSubscriber ? 1 : count
    }

    /// The stalled subscribers the shape registers.
    var subscribers: Int {
        self == .waitersStalledSubscriber || self == .groupStalledSubscriber ? 1 : 0
    }
}

/// What `SyncBench.commitTurn` measured and read.
struct CommitRun: CustomStringConvertible {
    /// The heartbeat's longest wait over the commit.
    var wait = 0.0
    /// The commit's own turn, timed inside the actor.
    var turn = 0.0
    /// H's ids and interests before the commit.
    var ids = 0
    var interests = 0
    /// Whether every caller was answered with a location, or every group's members were, and H's job is gone.
    var served = false
    var committed = false
    /// The events the stalled subscribers buffered.
    var buffered = 0
    /// The host's load averages before and after the run.
    var load = ""

    var description: String {
        "heartbeat \(String(format: "%.2f", self.wait)) ms, turn \(String(format: "%.2f", self.turn)) ms; ids \(self.ids), interests \(self.interests); served \(self.served), committed \(self.committed), buffered \(self.buffered); load \(self.load)"
    }
}

/// An engine as `SyncBench.followBench` builds it, with a stepped bulk executor so a publication can be held at its
/// first store unit.
@available(macOS 15.0, iOS 18.0, *)
struct HeldPublicationBench {
    let bench: FollowBench
    let bulk: SteppedBlockingExecutor
}

/// A thread-safe record of the commit turn's marks (`EngineState.commitTurnMarksForTests`).
@available(macOS 15.0, iOS 18.0, *)
final class CommitTurnClock: Sendable {
    private let marks = Mutex<(began: ContinuousClock.Instant?, longest: Duration)>((nil, .zero))

    /// Records a mark: a begin starts a span, an end closes it and keeps the longest.
    func mark(_ ended: Bool) {
        let now = ContinuousClock.now
        self.marks.withLock { marks in
            if ended {
                if let began = marks.began {
                    marks.longest = max(marks.longest, now - began)
                }
                marks.began = nil
            } else {
                marks.began = now
            }
        }
    }

    /// The longest closed span, in milliseconds.
    var longest: Double {
        SyncBench.milliseconds(self.marks.withLock { $0.longest })
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    /// An engine as `followBench` builds it, with a stepped bulk executor (not holding) and `tuning`.
    static func heldPublicationBench(tuning: SyncTuning = SyncTuning()) async throws -> HeldPublicationBench {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let conditions = FakeDeviceConditionsSource()
        let capacity = StoragePolicy().reserveFreeBytes + (64 << 20)
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: capacity, opportunisticCapacity: capacity)
        )
        let bulk = SteppedBlockingExecutor(holding: false)
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: bulk,
            time: time,
            random: SeededRandom(seed: 0x12),
            conditions: conditions,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        let configuration = StoreConfiguration(
            location: .applicationSupport,
            policy: StoragePolicy(minimumResidency: 0, deletionGrace: 60),
            legacy: LegacyMigrationPolicy(enabled: false),
            limits: ManifestLimits(),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
        let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: tuning))
        let xBytes = Data(repeating: 0x78, count: 2_000)
        let x = SyncBench.entry("x", xBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData([x]), etag: ETag(rawValue: "\"v1\""))])
        await source.script(x.transferID, [.stage(xBytes)])
        _ = try await engine.start().get()
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the setup sync did not complete")
        }
        return HeldPublicationBench(bench: FollowBench(engine: engine, source: source, store: store, fileSystem: fileSystem), bulk: bulk)
    }

    /// A commit that binds and answers `count` ids (Stage 3 close-out cycle 21, ruling S3-R26 item 4;
    /// `integrate-c21.md` item C's pins): the ids share H's 16 bytes, one job, downloading (held), wanted as `shape`
    /// says, with `subscribers` subscribers that read nothing. H's download is released with the bulk executor holding,
    /// so its publication waits at its first store unit; then the unit is released, and the heartbeat times the turns
    /// until H's job is gone, while the engine's seam times the commit's own turn inside the actor.
    static func commitTurn(count: Int, shape: CommitShape, subscribers: Int? = nil) async throws -> CommitRun {
        var run = CommitRun()
        let loadBefore = SyncBench.loadAverages()
        let held = try await SyncBench.heldPublicationBench()
        let engine = held.bench.engine
        let source = held.bench.source
        let bulk = held.bulk
        let hBytes = Data(repeating: 0x68, count: 16)
        let members = SyncBench.sharing(count, hBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData(members), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the second sync did not complete")
        }
        try await held.bench.store.flush(.ordered)
        let holder = members[0].transferID
        await source.script(holder, [.hold, .stage(hBytes)])
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        var groups: [InterestToken] = []
        switch shape {
        case .waiters, .waitersStalledSubscriber:
            for entry in members {
                let id = entry.identifier
                callers.append(Task { await engine.awaitAsset(id, lane: .userInitiated) })
            }
        case .groupStalledSubscriber:
            guard case .success(let token) = await engine.registerGroup(members.map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("the prefetch group was refused")
            }
            groups.append(token)
        case .manyGroups:
            for entry in members {
                guard case .success(let token) = await engine.registerGroup([entry.identifier], lane: .prefetch) else {
                    throw SyncBenchError.incomplete("a one-member prefetch group was refused")
                }
                groups.append(token)
            }
        }
        var spins = 0
        while !Task.isCancelled {
            let now = await SyncBench.userHolding(engine, holder)
            if now.ids == count, now.interests == shape.interests(count), await SyncBench.isRunning(engine, holder) {
                break
            }
            spins += 1
            if spins > 5_000_000 {
                throw SyncBenchError.incomplete("setup: H never held every id: \(now)")
            }
            await Task.yield()
        }
        let before = await SyncBench.userHolding(engine, holder)
        run.ids = before.ids
        run.interests = before.interests
        var subscriptions: [AsyncStream<AssetEvent>] = []
        for _ in 0..<(subscribers ?? shape.subscribers) {
            subscriptions.append(try await engine.subscribe().get())
        }
        await bulk.setHolding(true)
        await source.release(holder, with: .progress(received: 0, expected: nil))
        await bulk.waitForHeldUnits(atLeast: 1)
        await SyncBench.raiseOwnedTaskPriority(engine)
        let clock = CommitTurnClock()
        await SyncBench.markCommitTurns(engine) { ended in clock.mark(ended) }
        run.wait = try await SyncBench.longestWait(on: engine) {
            await bulk.setHolding(false)
            await bulk.releaseAll()
            while !Task.isCancelled, await SyncBench.jobExists(engine, holder) {
                await bulk.releaseAll()
                await Task.yield()
            }
        }
        run.turn = clock.longest
        await SyncBench.markCommitTurns(engine, nil)
        run.committed = !(await SyncBench.jobExists(engine, holder))
        run.buffered = await engine.introspect().bufferedEvents
        withExtendedLifetime(subscriptions) {}
        var served = true
        for caller in callers {
            if case .success = await caller.value {
                continue
            }
            served = false
        }
        let answered = await SyncBench.groupsAnswered(engine, groups)
        run.served = served && answered
        await engine.shutdown()
        run.load = "\(loadBefore) -> \(SyncBench.loadAverages())"
        return run
    }

    /// Sets or clears the commit turn's marks (`EngineState.commitTurnMarksForTests`).
    static func markCommitTurns(_ engine: isolated SyncEngine, _ marks: (@Sendable (Bool) -> Void)?) {
        engine.state.commitTurnMarksForTests = marks
    }

    /// Whether every one of `groups` has no member left to answer.
    static func groupsAnswered(_ engine: isolated SyncEngine, _ groups: [InterestToken]) -> Bool {
        groups.allSatisfy { engine.state.groups[$0]?.pending.isEmpty ?? true }
    }
}
