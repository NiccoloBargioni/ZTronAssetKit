import Foundation
import Synchronization
import Testing
import ZTronAssetModel
import ZTronAssetStorage
import ZTronAssetTestSupport
import ZTronAssetTransport

@testable import ZTronAssetSync

extension ZTronAssetKitBenchmarks {
    /// P-4, P-7, P-11 and P-14 (WP-F), release configuration. Every threshold comes from `QualityBudgets`.
    ///
    /// P-4 is the median of 21 plans after 3 warm-ups at 10,000 and 20,000 entries. P-7 syncs a synthetic catalog
    /// streamed by `FakeTransferStep.stageGenerated` into real files in a directory inside this repository and samples
    /// the resident size (`MemoryProbe`) at every transfer start and after the run; it runs a quarter catalog first, so
    /// "does not grow with catalog size" compares the two deltas. P-11 times a sync of the real HTTP source against the
    /// loopback server with real latency at concurrency 1 and at the configured concurrency (benchmarks are exempt from
    /// the no-sleep rule, sync-2 S2-14). P-14 drives a sync to quiescence on `ManualTimeSource` and reads the engine's
    /// census plus the environment's.
    @Suite("SyncBenchmarks")
    struct SyncBenchmarks {
        @Test("P-4: planning 10,000 vs 10,000 entries with 10% churn stays within plan_ms and scales by at most doubling_ratio_max", .timeLimit(.minutes(1)))
        func planning() async throws {
            let budgets = try QualityBudgets()
            let planMs = try #require(budgets.value("P-4", "plan_ms"))
            let ratioMax = try #require(budgets.value("P-4", "doubling_ratio_max"))
            let small = SyncBench.medianPlanMilliseconds(entries: 10_000)
            let large = SyncBench.medianPlanMilliseconds(entries: 20_000)
            let ratio = large / max(small, 0.000_001)
            print("P-4 plan 10,000: \(small) ms (budget \(planMs)); 20,000: \(large) ms; ratio \(ratio) (max \(ratioMax))")
            #expect(small <= planMs)
            #expect(ratio <= ratioMax)
        }

        @Test("P-14: after quiescence the engine owns at most idle_timers_max timers and idle_tasks_max tasks", .timeLimit(.minutes(1)))
        @available(macOS 15.0, iOS 18.0, *)
        func idleCensus() async throws {
            let budgets = try QualityBudgets()
            let timersMax = Int(try #require(budgets.value("P-14", "idle_timers_max")))
            let tasksMax = Int(try #require(budgets.value("P-14", "idle_tasks_max")))
            let time = ManualTimeSource()
            let source = FakeRemoteSource()
            let conditions = FakeDeviceConditionsSource()
            let engine = SyncBench.fakeEngine(time: time, source: source, conditions: conditions)
            let entries = (0..<50).map { index -> (ManifestEntry, Data) in
                let bytes = GeneratedPayload.bytes(seed: 0x14_000 + UInt64(index), offset: 0, length: 512)
                return (SyncBench.entry("idle-\(index)", bytes), bytes)
            }
            await source.scriptManifest([.fetched(SyncBench.manifestData(entries.map(\.0)), etag: ETag(rawValue: "\"p14\""))])
            for (entry, bytes) in entries {
                await source.script(entry.transferID, [.stage(bytes)])
            }
            _ = try await engine.start().get()
            try await SyncBench.drive(engine: engine, time: time) { $0.groups == 0 }
            // Prune half of the catalog: doomed blobs keep the store's grace deadline in the engine's heap.
            await source.scriptManifest([.fetched(SyncBench.manifestData(entries.prefix(25).map(\.0)), etag: ETag(rawValue: "\"p14b\""))])
            let run = Task { await engine.sync(.force) }
            // The run cannot finish before the clock opens its commit window, so it is seen running first.
            await engine.waitUntil { $0.groups >= 1 }
            try await SyncBench.drive(engine: engine, time: time) { $0.groups == 0 }
            #expect(await run.value.isComplete)
            try await SyncBench.drive(engine: engine, time: time) { $0.isIdleSilent }
            try await conditions.requireObservers(equalTo: 0)
            let state = await engine.introspect()
            print("P-14 armed timers \(state.armedTimers) (max \(timersMax)), owned tasks \(state.ownedTasks) (max \(tasksMax)), sleepers \(time.pendingSleepers)")
            #expect(state.armedTimers <= timersMax)
            #expect(state.ownedTasks <= tasksMax)
            #expect(!state.watcherActive && state.scheduledDeadlines == 0)
            #expect(time.pendingSleepers == 0)
            #expect(await source.activeTransfers == 0)
            #expect(await conditions.activeObservers == 0)
            await engine.shutdown()
        }

        @Test("P-7: a 1 GiB synthetic bulk sync adds at most sync_memory_delta_mib_max MiB and does not grow with catalog size", .timeLimit(.minutes(1)))
        @available(macOS 15.0, iOS 18.0, *)
        func syncMemory() async throws {
            let budgets = try QualityBudgets()
            let deltaMax = try #require(budgets.value("P-7", "sync_memory_delta_mib_max"))
            let catalogGiB = try #require(budgets.value("P-7", "catalog_gib"))
            let full = Int64(catalogGiB * Double(1 << 30))
            let quarter = try await SyncBench.syncMemoryDelta(catalogBytes: full / 4)
            let whole = try await SyncBench.syncMemoryDelta(catalogBytes: full)
            print("P-7 resident delta: \(MemoryProbe.mebibytes(quarter)) MiB for \((full / 4) >> 20) MiB, \(MemoryProbe.mebibytes(whole)) MiB for \(full >> 20) MiB (max \(deltaMax))")
            #expect(MemoryProbe.mebibytes(whole) <= deltaMax)
            #expect(MemoryProbe.mebibytes(quarter) <= deltaMax)
            #expect(MemoryProbe.mebibytes(whole) <= MemoryProbe.mebibytes(quarter) + deltaMax / 4, "the delta does not grow with the catalog")
        }

        @Test("P-11: assets with server latency sync at least speedup_min times faster at the configured concurrency than at 1", .timeLimit(.minutes(1)))
        @available(macOS 15.0, iOS 18.0, *)
        func latencySpeedup() async throws {
            let budgets = try QualityBudgets()
            let assets = Int(try #require(budgets.value("P-11", "assets")))
            let latency = try #require(budgets.value("P-11", "server_latency_ms"))
            let concurrency = Int(try #require(budgets.value("P-11", "concurrency")))
            let speedupMin = try #require(budgets.value("P-11", "speedup_min"))
            let serial = try await SyncBench.timedLoopbackSync(assets: assets, latencyMs: latency, concurrency: 1)
            let parallel = try await SyncBench.timedLoopbackSync(assets: assets, latencyMs: latency, concurrency: concurrency)
            let speedup = serial / max(parallel, 0.000_001)
            print("P-11 \(assets) assets at \(latency) ms: concurrency 1 \(serial) s, \(concurrency) \(parallel) s, speedup \(speedup) (min \(speedupMin))")
            #expect(speedup >= speedupMin)
        }

        /// The announcement of a mass prune runs in one actor turn of the engine (`applied`): with a subscriber that
        /// never pulls, each `assetRemoved` takes a slot of its queue, so a queue copied per publication made that turn
        /// quadratic (about 0.16 s at 4,000 ids, C2). Medians of three, after a warm-up.
        @Test("R-SYN-12: announcing a 10,000-id prune to a stalled subscriber costs at most twice the same sync with nobody subscribed", .timeLimit(.minutes(1)))
        @available(macOS 15.0, iOS 18.0, *)
        func stalledPruneAnnouncement() async throws {
            _ = try await SyncBench.pruneSyncSeconds(count: 1_000, stalled: true)
            var quiet: [Double] = []
            var stalled: [Double] = []
            for _ in 0..<3 {
                quiet.append(try await SyncBench.pruneSyncSeconds(count: 10_000, stalled: false))
                stalled.append(try await SyncBench.pruneSyncSeconds(count: 10_000, stalled: true))
            }
            let unobserved = quiet.sorted()[1]
            let observed = stalled.sorted()[1]
            print("R-SYN-12 prune of 10,000 ids: nobody subscribed \(unobserved) s, one stalled subscriber \(observed) s, ratio \(observed / max(unobserved, 0.000_001)) (max 2, plus 5 ms)")
            #expect(observed <= 2 * unobserved + 0.005)
        }

        /// The C2 rule's figure (CLAUDE.md C2: nothing holds a cooperative-pool thread longer than about 10 ms at a
        /// stretch). `Scripts/quality-gates.json` has no C2 key and is frozen, so the rule's own figure is the budget, as
        /// in `BenchCleanup` under the level-3 ruling R4 (ADR-052). It is asserted on the best of the runs: the heartbeat's
        /// longest wait is the engine's longest turn plus scheduling noise, and noise only adds.
        static let c2Budget = 10.0

        /// C2 at SPEC §6's reference scale (review of close-out cycle 7, PROBE-C7C-2): a 10,000-member prefetch group on
        /// a volume with room for two members parks the others for lack of space, and every later free-space read
        /// re-checks them. The headroom ledger summed the bytes in flight over every job for each job it gated, so the
        /// parking turn and an ENOSPC's re-check turn were quadratic (the verifier measured 9.8 s and 4.7 s at 10,000,
        /// during which the engine answered no call). A high-priority heartbeat calls into the engine's actor back to
        /// back: its longest wait bounds the longest actor turn. Medians of three against P-9, the best of the three
        /// against C2 (`c2Budget`), after a warm-up.
        @Test("R-SYN-11: parking a 10,000-member prefetch group for lack of space, and an ENOSPC's free-space read over it, hold the engine's actor at most C2's 10 ms per turn and never longer than P-9's heartbeat_gap_ms_p99_max", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func spaceParkingTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.spaceParkingWaits(members: 1_000)
            var parking: [Double] = []
            var reading: [Double] = []
            for _ in 0..<3 {
                let waits = try await SyncBench.spaceParkingWaits(members: 10_000)
                parking.append(waits.parking)
                reading.append(waits.read)
            }
            let parked = parking.sorted()[1]
            let read = reading.sorted()[1]
            print("R-SYN-11 space parking of 10,000 prefetch members: longest actor wait while parking \(parked) ms, during an ENOSPC's free-space read \(read) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(parking) and \(reading)")
            #expect(parked <= gapMax)
            #expect(read <= gapMax)
            #expect((parking.min() ?? .infinity) <= Self.c2Budget, "parking: \(parking)")
            #expect((reading.min() ?? .infinity) <= Self.c2Budget, "ENOSPC read: \(reading)")
        }

        /// C2 at SPEC §6's reference scale (review of close-out cycle 8, PROBE-C8C-2): 10,000 prefetch members are parked
        /// for lack of space (two start and hold), then the volume gains room and one free-space read re-checks them.
        /// The sweep re-admitted every member the room held in that one read's turn (15 to 26 ms at 10,000). Medians of
        /// three against P-9, the best of the three against C2, after a warm-up.
        @Test("R-SYN-11: re-admitting 10,000 prefetch members parked for lack of space when the volume gains room holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func spaceReadmissionTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.spaceReadmissionWait(members: 1_000)
            var runs: [Double] = []
            for _ in 0..<3 {
                runs.append(try await SyncBench.spaceReadmissionWait(members: 10_000))
            }
            let median = runs.sorted()[1]
            print("R-SYN-11 re-admission of 10,000 prefetch members parked for space: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(runs)")
            #expect(median <= gapMax)
            #expect((runs.min() ?? .infinity) <= Self.c2Budget, "\(runs)")
        }

        /// C2 at SPEC §6's reference scale (close-out cycle 8): with a 10,000-member prefetch group waiting in the queue
        /// behind its running members, the network drops (every queued member parks `offline`) and returns (every one
        /// is re-queued). The heartbeat's longest wait bounds the longest actor turn of each edge; medians of three
        /// against P-9, the best of the three against C2 (one turn parked every queued member, about 15 ms, and one
        /// re-queued every member, about 22 ms: review of close-out cycle 8), after a warm-up.
        @Test("R-SYN-13: losing and regaining the network under a 10,000-member prefetch group holds the engine's actor at most C2's 10 ms per turn and never longer than P-9's heartbeat_gap_ms_p99_max", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func networkEdgeTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.networkEdgeWaits(members: 1_000)
            var offline: [Double] = []
            var online: [Double] = []
            for _ in 0..<3 {
                let waits = try await SyncBench.networkEdgeWaits(members: 10_000)
                offline.append(waits.offline)
                online.append(waits.online)
            }
            let lost = offline.sorted()[1]
            let regained = online.sorted()[1]
            print("R-SYN-13 network edges under 10,000 prefetch members: longest actor wait going offline \(lost) ms, coming back \(regained) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(offline) and \(online)")
            #expect(lost <= gapMax)
            #expect(regained <= gapMax)
            #expect((offline.min() ?? .infinity) <= Self.c2Budget, "going offline: \(offline)")
            #expect((online.min() ?? .infinity) <= Self.c2Budget, "coming back: \(online)")
        }

        /// C2 at SPEC §6's reference scale (review of close-out cycle 8, PROBE-C8R-1 and PROBE-C8C-3): releasing a
        /// prefetch handle of 10,000 members (three run, the others wait in the queue) removed every member's interest in
        /// one actor turn (about 15 ms). Medians of three against P-9, the best of the three against C2, after a warm-up.
        @Test("R-SYN-4: releasing a 10,000-member prefetch handle holds the engine's actor at most C2's 10 ms per turn and leaves no job", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func handleReleaseTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.handleReleaseWait(members: 1_000)
            var runs: [Double] = []
            for _ in 0..<3 {
                runs.append(try await SyncBench.handleReleaseWait(members: 10_000))
            }
            let median = runs.sorted()[1]
            print("R-SYN-4 release of a 10,000-member prefetch handle: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(runs)")
            #expect(median <= gapMax)
            #expect((runs.min() ?? .infinity) <= Self.c2Budget, "\(runs)")
        }

        /// C2 at SPEC §6's reference scale when the engine shuts down (Stage 3, S3-PERF-01): under a 10,000-member
        /// prefetch group (three run, the others wait in the queue) and 10,000 user-initiated `resolve` callers waiting on
        /// its members, the shutdown's first turn sorted the job table twice to cancel handles, answered every waiter and
        /// group and freed the job table in one actor turn (17 to 22 ms). The same path retires the engine of a store
        /// whose root vanished while the app runs. Production's dispatch executors (the store's units off the actors).
        /// Medians of three against P-9, the best of the three against C2, after a warm-up; the 1,000 figure gives the
        /// ratio, and the group alone (no waiters) is measured too.
        @Test("R-SYN-15: shutting down under a 10,000-member prefetch group and 10,000 waiting resolves holds the engine's actor at most C2's 10 ms per turn and answers every waiter shutDown", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func shutdownTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            let small = try await SyncBench.shutdownWait(members: 1_000)
            var runs: [Double] = []
            for _ in 0..<3 {
                runs.append(try await SyncBench.shutdownWait(members: 10_000))
            }
            let median = runs.sorted()[1]
            var groupOnly: [Double] = []
            for _ in 0..<3 {
                groupOnly.append(try await SyncBench.shutdownWait(members: 10_000, waiters: false))
            }
            print("R-SYN-15 shutdown under 10,000 prefetch members and 10,000 waiting resolves: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(runs); at 1,000: \(small) ms; the group without waiters: \(groupOnly)")
            #expect(median <= gapMax)
            #expect((runs.min() ?? .infinity) <= Self.c2Budget, "\(runs)")
            #expect((groupOnly.min() ?? .infinity) <= Self.c2Budget, "group only: \(groupOnly)")
        }

        /// C2 at SPEC §6's reference scale when a sync applies a manifest (one entry added) while a 10,000-member
        /// prefetch group waits in the queue (Stage 3, S3-PERF-02): `followApplied` sorted and walked the whole job table
        /// after every apply, and the run's release of launch re-attachments and its end each walked it again, sorted
        /// (17 to 19 ms). Production's dispatch executors. Medians of three against P-9, the best of the three against
        /// C2, after a warm-up.
        @Test("R-SYN-6: a sync that applies a new manifest under a 10,000-member prefetch group holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func refreshUnderGroupTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.refreshWait(members: 1_000)
            var runs: [Double] = []
            for _ in 0..<3 {
                runs.append(try await SyncBench.refreshWait(members: 10_000))
            }
            let median = runs.sorted()[1]
            print("R-SYN-6 refresh under a 10,000-member prefetch group: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(runs)")
            #expect(median <= gapMax)
            #expect((runs.min() ?? .infinity) <= Self.c2Budget, "\(runs)")
        }

        /// C2 at SPEC §6's reference scale when a sync's manifest changes the content of every member of a waiting
        /// 10,000-member prefetch group (a catalog re-encode under `AssetClient.prefetch` of the catalog; the close-out
        /// cycle-1 verifier's PROBE-V9): the follow after the apply supersedes every member's job, re-routes its interest
        /// and creates a job for its new content. In one turn that held the actor 125 to 145 ms (S3F-5's residual,
        /// S3-R5). Production's dispatch executors. Medians of three against P-9, the best of the three against C2, after
        /// a warm-up.
        @Test("R-SYN-6: a sync whose manifest changes the content of every member of a waiting 10,000-member prefetch group holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func changedRefreshTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.changedRefreshWait(members: 1_000)
            var runs: [Double] = []
            for _ in 0..<3 {
                runs.append(try await SyncBench.changedRefreshWait(members: 10_000))
            }
            let median = runs.sorted()[1]
            print("R-SYN-6 refresh changing every member of a 10,000-member prefetch group: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(runs)")
            #expect(median <= gapMax)
            #expect((runs.min() ?? .infinity) <= Self.c2Budget, "\(runs)")
        }

        /// C2 at SPEC §6's reference scale for a sync whose manifest drops 10,000 ids while a subscriber reads nothing
        /// (Stage 3, S3-B-078): `applied()` announces every prune in the apply's turn, one queue slot per id. The turn was
        /// estimated, not measured (about 3.5 ms at 10,000). Medians of three against P-9, the best against C2, after a
        /// warm-up.
        @Test("R-SYN-12: announcing a 10,000-id prune to a stalled subscriber holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func pruneAnnouncementTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.pruneAnnouncementWait(count: 1_000)
            var runs: [Double] = []
            for _ in 0..<3 {
                runs.append(try await SyncBench.pruneAnnouncementWait(count: 10_000))
            }
            let median = runs.sorted()[1]
            print("R-SYN-12 prune announcement of 10,000 ids to a stalled subscriber: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(runs)")
            #expect(median <= gapMax)
            #expect((runs.min() ?? .infinity) <= Self.c2Budget, "\(runs)")
        }

        /// C2 at SPEC §6's reference scale when the retries of 10,000 prefetch members that failed transiently fall due
        /// together, so one alarm turn (`fireDue`) finds every deadline due (Stage 3, S3-B-077). Medians of three against
        /// P-9, the best against C2, after a warm-up.
        @Test("R-SYN-5: retries of 10,000 prefetch members falling due together hold the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func dueRetriesTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.dueRetriesWait(members: 1_000)
            var runs: [Double] = []
            for _ in 0..<3 {
                runs.append(try await SyncBench.dueRetriesWait(members: 10_000))
            }
            let median = runs.sorted()[1]
            print("R-SYN-5 retries of 10,000 prefetch members falling due together: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(runs)")
            #expect(median <= gapMax)
            #expect((runs.min() ?? .infinity) <= Self.c2Budget, "\(runs)")
        }

        /// C2 at SPEC §6's reference scale for a handle registered at user-initiated priority (`AssetClient.prefetch`
        /// accepts it; review of close-out cycle 9, PROBE-C9C-2): its four members run (every slot) and the others wait in
        /// the user queue. The release leaves the members it has not reached yet queued and only the released group
        /// wants them, so the gate answers `.wait` for each; every pump of the release (its own turn and one per cancelled
        /// attempt's drain, back to back ahead of other callers) scanned all of them twice, in the user queue's pop and in
        /// the check for waiting user work: 23 to 29 ms of heartbeat wait. Medians of three against P-9, the best of the
        /// three against C2, after a warm-up.
        @Test("R-SYN-4: releasing a 10,000-member prefetch handle of user-initiated priority holds the engine's actor at most C2's 10 ms per turn and leaves no job", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func userHandleReleaseTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.handleReleaseWait(members: 1_000, lane: .userInitiated)
            var runs: [Double] = []
            for _ in 0..<3 {
                runs.append(try await SyncBench.handleReleaseWait(members: 10_000, lane: .userInitiated))
            }
            let median = runs.sorted()[1]
            print("R-SYN-4 release of a 10,000-member user-initiated prefetch handle: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(runs)")
            #expect(median <= gapMax)
            #expect((runs.min() ?? .infinity) <= Self.c2Budget, "\(runs)")
        }

        /// C2 at SPEC §6's reference scale when a released handle's members regain an interest at once (review of
        /// close-out cycle 11, PROBE-C11C-3): a 10,000-member handle is released and its members are joined again while
        /// the release is still pending, so a member the release has not reached yet keeps its job, gets a fresh ticket
        /// and is merged back at its place (`reinstate`, `LaneQueues.absorb`), then the same identifiers are registered
        /// again. A handle's join task reads the store before its first batch, by which time the release's turns, 512
        /// members each, have passed every member it would join (close-out cycle 12's verifier counted no reinstated
        /// member), so the release's own turn and each of its later turns are met by one join batch from the end of the
        /// release order (`SyncBench.handleRejoinWait`). Prefetch and bulk handles; medians of three against P-9, the
        /// best of the three against C2, after a warm-up.
        @Test("R-SYN-3: re-registering the members of a released 10,000-member handle holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func handleRejoinTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            for lane in [AssetPriority.prefetch, .bulk] {
                _ = try await SyncBench.handleRejoinWait(members: 1_000, lane: lane)
                var runs: [(wait: Double, reinstated: Int)] = []
                for _ in 0..<3 {
                    runs.append(try await SyncBench.handleRejoinWait(members: 10_000, lane: lane))
                }
                let median = runs.map(\.wait).sorted()[1]
                let reinstated = runs.map(\.reinstated)
                print("R-SYN-3 re-join of a released 10,000-member \(lane) handle: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(runs.map(\.wait)); members re-joined while the release was pending \(reinstated)")
                #expect(median <= gapMax, "\(lane)")
                #expect((runs.map(\.wait).min() ?? .infinity) <= Self.c2Budget, "\(lane): \(runs.map(\.wait))")
                #expect(reinstated.allSatisfy { $0 > 0 }, "\(lane): every run re-joined members the release had not reached: \(reinstated)")
            }
        }

        /// C2 at SPEC §6's reference scale when a resolve's caller cancels while 10,000 prefetch members wait (review of
        /// close-out cycle 9, PROBE-C9R-1): the withdrawal sorted every job's transfer to find the caller's interest (5.8
        /// to 6.4 ms at a load about 7.5, the least margin of the measured turns). Medians of three against P-9, the best
        /// of the three against C2, after a warm-up.
        @Test("R-SYN-4: cancelling a resolve while 10,000 prefetch members wait holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func resolveCancelTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.resolveCancelWait(members: 1_000)
            var runs: [Double] = []
            for _ in 0..<3 {
                runs.append(try await SyncBench.resolveCancelWait(members: 10_000))
            }
            let median = runs.sorted()[1]
            print("R-SYN-4 cancelled resolve beside 10,000 prefetch members: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(runs)")
            #expect(median <= gapMax)
            #expect((runs.min() ?? .infinity) <= Self.c2Budget, "\(runs)")
        }

        /// C2 at SPEC §6's reference scale when a breaker's cooldown ends over the members it parked (review of close-out
        /// cycle 9, PROBE-C9C-4, whose window was unreliable): 5xx answers open the breaker under a 10,000-member prefetch
        /// group, the open breaker parks every queued member `circuitOpen`, and the clock then reaches the cooldown's end,
        /// so the alarm owes every parked member a re-queue (`unblockOrigin`, at most `readmissionsPerTurn` per turn) and
        /// the gate parks all but the half-open probe again. Medians of three against P-9, the best of the three against
        /// C2, after a warm-up.
        @Test("R-SYN-5: a breaker cooldown's end over 10,000 prefetch members parked by it holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func cooldownEndTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.cooldownEndWait(members: 1_000)
            var runs: [Double] = []
            for _ in 0..<3 {
                runs.append(try await SyncBench.cooldownEndWait(members: 10_000))
            }
            let median = runs.sorted()[1]
            print("R-SYN-5 cooldown end over 10,000 prefetch members parked by the breaker: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(runs)")
            #expect(median <= gapMax)
            #expect((runs.min() ?? .infinity) <= Self.c2Budget, "\(runs)")
        }

        /// The total cost of a chain of half-open probes that each end without a verdict (close-out cycle 21, F-41; the
        /// cycle-20 requirements verifier's ProbeC20RChain): 5xx answers open the breaker under a prefetch group, the open
        /// breaker parks every queued member, every member then answers 400, and the clock reaches the cooldown's end. Each
        /// member probes in turn. Until Stage 3 each exit re-admitted every member the breaker still parked while the pump
        /// parked all but the next probe again (F-40), so the chain's total actor work grew with the square of the parked
        /// members (1,000: 2.6 to 7.5 s; 10,000: about 161 s); since S3-B-063 (L4-R22) an exit re-admits only the first
        /// parked member in the pump's order (`readmitForProbe`), so the chain runs at SPEC §6's 10,000. The best of three
        /// runs' longest actor wait against C2, the median against P-9, after a warm-up of 1,000. The totals are reported,
        /// not checked against a budget: none exists. The exits are 400s, not 404s (Stage 3 close-out cycle 4): a 404 has
        /// the store record the failure and commit its whole index before the engine goes on (ADR-032), about 5 ms at
        /// 10,000 records on the store's actor, so the 10,000 exits of a chain took 60 to 95 s, over this test's limit on
        /// a quiet host, measuring that commit rather than the re-admission; a 400 also ends a probe without a verdict
        /// (`breakerOutcome`: neutral) and re-admits exactly as a 404 does.
        @Test("R-SYN-5: a chain of half-open probes ending without a verdict over 10,000 prefetch members parked by the breaker holds the engine's actor at most C2's 10 ms per turn, and reports the chain's total time", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func probeChainTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.probeChainWait(members: 1_000)
            var runs: [(wait: Double, total: Double)] = []
            for _ in 0..<3 {
                runs.append(try await SyncBench.probeChainWait(members: 10_000))
            }
            let waits = runs.map(\.wait)
            let median = waits.sorted()[1]
            print("R-SYN-5 chain of probes without a verdict over 10,000 prefetch members parked by the breaker: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); totals \(runs.map(\.total)) s; runs \(waits)")
            #expect(median <= gapMax)
            #expect((waits.min() ?? .infinity) <= Self.c2Budget, "\(waits)")
        }

        /// C2 at SPEC §6's reference scale when a 429 extends an origin's throttle under user-initiated waiters (close-out
        /// cycle 16, F-36): a 1 s 429 throttles the origin, 10,000 user-initiated `resolve` callers park within
        /// `interactiveMaxWait` and wait, and a running member's 60 s 429 then extends the throttle; later turns answer
        /// every waiter fail-fast, at most `parksPerPump` jobs a turn. Medians of three against P-9, the best of the three
        /// against C2, after a warm-up.
        @Test("R-SYN-5: a 429 that extends the throttle under 10,000 user-initiated waiters holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func throttleExtensionTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.throttleExtensionWait(waiters: 1_000)
            var runs: [Double] = []
            for _ in 0..<3 {
                runs.append(try await SyncBench.throttleExtensionWait(waiters: 10_000))
            }
            let median = runs.sorted()[1]
            print("R-SYN-5 throttle extension over 10,000 user-initiated waiters: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(runs)")
            #expect(median <= gapMax)
            #expect((runs.min() ?? .infinity) <= Self.c2Budget, "\(runs)")
        }

        /// C2 at SPEC §6's reference scale when the store's reaper frees space during an owed follow (Stage 3 close-out
        /// cycle 5; the cycle-4 correctness lens, PROBE-C4-SWEEP2-C2): 10,000 prefetch members alternating 400 and 3,000
        /// bytes wait `awaitingSpace` for a pruned 2,000-byte blob with 100 bytes of room; a forced sync changes every
        /// member's content and its follow's follow-ups are held (the follow owes its visits, as between two of its turns);
        /// then the deletion grace ends, and the alarm's `.reclaimed` sweep and its follow-up sweeps follow the members
        /// (at most `followsPerTurn` per turn, judging none while any is left to follow) and then re-queue the 400-byte
        /// members and park the 3,000-byte ones. While a follow counted as the re-queue or park it preceded, one sweep turn
        /// followed 1,024 jobs: 10.2 to 10.8 ms with one handle and 13.6 to 14.1 ms with two over the same ids (two
        /// interests per job). Since the close-out cycle 9 a sweep that meets the follow barrier (F-28) runs one follow turn
        /// and judges nothing; its follow-up sweep judges once nothing is owed (`sweepSpaceParked`). With one handle and
        /// with two; medians of three against P-9, the best of the three against C2, after a warm-up.
        @Test("R-SYN-11: a reclaim of space during an owed follow under a 10,000-member prefetch group, re-queueing and parking its members, holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func reclaimDuringFollowTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.reclaimDuringFollowWait(members: 1_000, handles: 1)
            for handles in [1, 2] {
                var runs: [Double] = []
                for _ in 0..<3 {
                    runs.append(try await SyncBench.reclaimDuringFollowWait(members: 10_000, handles: handles))
                }
                let median = runs.sorted()[1]
                print("R-SYN-11 reclaim during an owed follow under 10,000 prefetch members, \(handles) handle(s): longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(runs)")
                #expect(median <= gapMax, "\(handles) handle(s): \(runs)")
                #expect((runs.min() ?? .infinity) <= Self.c2Budget, "\(handles) handle(s): \(runs)")
            }
        }

        /// C2 when the reclaim's sweep meets an owed follow that moved few members (VERIFY-C8-C2-MIXED, the close-out
        /// cycle-8 verifier): as `reclaimDuringFollowTurns`, but the forced sync changes one member in 20, so after the
        /// apply's turn the follow still owes about 244 visits and the sweep has every one of the 10,000 members left to
        /// judge once they are made. Cycle 8's sweep followed the owed holders and then collected, sorted and judged all
        /// 10,000 in one turn: 10.0 to 12.0 ms best with one handle, against 6.7 ms at `7426fee`. Behind the follow barrier
        /// (S3-R11) a sweep turn either follows or judges: the design panel measured 5.7 to 6.0 ms. With one handle and
        /// with two; medians of three against P-9, the best of the three against C2, after a warm-up.
        @Test("R-SYN-11: a reclaim of space during an owed follow that changed one member in 20 of a 10,000-member prefetch group, its sweeps following the owed visits and then judging every member, holds the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func reclaimDuringMixedFollowTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.reclaimDuringFollowWait(members: 1_000, handles: 1, changeEvery: 2)
            for handles in [1, 2] {
                var runs: [Double] = []
                for _ in 0..<3 {
                    runs.append(try await SyncBench.reclaimDuringFollowWait(members: 10_000, handles: handles, changeEvery: 20))
                }
                let median = runs.sorted()[1]
                print("R-SYN-11 reclaim during an owed follow that changed 1 member in 20 of 10,000 prefetch members, \(handles) handle(s): longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(runs)")
                #expect(median <= gapMax, "\(handles) handle(s): \(runs)")
                #expect((runs.min() ?? .infinity) <= Self.c2Budget, "\(handles) handle(s): \(runs)")
            }
        }

        /// C2 of the follow barrier's drain (F-28; S3-R11 design D3's probe VERIFY-D3-DRAIN-C2): while a follow over a
        /// 10,000-member prefetch group whose every member changed content is owed (its follow-ups held), a second prefetch
        /// window registers 10,000 other members, and each member's join waits for the follow's end
        /// (`EventAfterFollow.join`; Stage 3 close-out cycles 11 and 12, the cycle-9 `.enqueue` place is gone). The
        /// release runs the follow's remaining turns, then the drain makes the 10,000 joins and their places at most
        /// `eventsAfterFollowPerTurn` per turn. The heartbeat's longest wait over every follow and drain
        /// turn: medians of three against P-9, the best of the three against C2, after a warm-up. The time from the
        /// release to the follow's end and to the drain's end is printed: no admission is made meanwhile (S3-R11 R2, a
        /// Stage 5 residual risk).
        @Test("R-SYN-11: the end of an owed follow that changed every member of a 10,000-member prefetch group, and the drain of 10,000 places in a queue that waited for it, hold the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func followDrainTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.followDrainWait(members: 1_000, changed: 1_000)
            var runs: [FollowDrainRun] = []
            for _ in 0..<3 {
                runs.append(try await SyncBench.followDrainWait(members: 10_000, changed: 10_000))
            }
            let waits = runs.map(\.wait)
            let median = waits.sorted()[1]
            print("R-SYN-11 follow end and drain of 10,000 places under 10,000 changed prefetch members: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(waits); follow ended \(runs.map(\.followEnded)) ms and drain ended \(runs.map(\.drainEnded)) ms after the release")
            #expect(median <= gapMax, "\(waits)")
            #expect((waits.min() ?? .infinity) <= Self.c2Budget, "\(waits)")
        }

        /// C2 of the follow's last turn plus the drain's first batch (S3-R11 amendment (f)): the follow's last turn visits
        /// up to `followsPerTurn` jobs, checks the run and pumps, and then applies the first `eventsAfterFollowPerTurn`
        /// events that waited for it in the same turn (`continueFollow`). Here a 10,000-member prefetch group waits for space
        /// and a forced sync changes `2 × followsPerTurn` of its members, so with the follow-ups held the follow owes exactly
        /// one full turn of visits; a second window of 10,000 members registers meanwhile, leaving 10,000 places waiting.
        /// The replaced copy lists both groups (20,000 entries, more than `followScansPerTurn`), so the same turn also ends
        /// the follow's pass over it. The release runs that combined turn, timed inside the actor (`releaseHeldFollow`),
        /// and the test checks it was the combined one: a full turn of visits owed, nothing owed after it, and one full
        /// batch drained. The heartbeat's longest wait over every turn up to the drain's end is asserted too. Medians of
        /// three against P-9, the best of the three against C2, after a warm-up.
        @Test("R-SYN-11: an owed follow's last turn, a full turn of visits under a 10,000-member prefetch group plus the first batch of 10,000 places that waited for it, holds the engine's actor at most C2's 10 ms", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func followEndTurn() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            let changed = 2 * SyncEngine.followsPerTurn
            _ = try await SyncBench.followDrainWait(members: 1_000, changed: changed)
            var runs: [FollowDrainRun] = []
            for _ in 0..<3 {
                runs.append(try await SyncBench.followDrainWait(members: 10_000, changed: changed))
            }
            for run in runs {
                #expect(run.release.owedVisits == SyncEngine.followsPerTurn, "\(run.release)")
                #expect(!run.release.followOwedAfter, "\(run.release)")
                #expect(run.release.drained == SyncEngine.eventsAfterFollowPerTurn, "\(run.release)")
            }
            let turns = runs.map(\.release.milliseconds)
            let waits = runs.map(\.wait)
            let median = waits.sorted()[1]
            print("R-SYN-11 follow's last turn plus the drain's first batch under 10,000 prefetch members and 10,000 waiting places: the turn \(turns) ms; longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(waits)")
            #expect(median <= gapMax, "\(waits)")
            #expect((turns.min() ?? .infinity) <= Self.c2Budget, "\(turns)")
            #expect((waits.min() ?? .infinity) <= Self.c2Budget, "\(waits)")
        }

        /// C2 of the two walks over every job that an attempt's end and a 429 make while an owed follow covers 10,000
        /// jobs (Stage 3 close-out cycle 17; the cycle-16 verifiers' note that `followedLane`'s margin at 10,000 was
        /// unmeasured): a 10,000-member prefetch group waits for space while O, a user request's 16-byte download, runs; v3
        /// changes every member's content with the follow's follow-ups held after its first turn, so the follow is owed
        /// when O gets a 404, whose verdict then waits. The 404's turn walks every job for the ids an owed visit would move
        /// onto O's content (`bringInbound`; none here), timed by the heartbeat; a 429 behind the barrier walks them for its
        /// lane (`followedLane`, timed inside the actor on the job of a member the follow has not visited, O's verdict
        /// waiting: the median of 21 calls). Medians of three against P-9, the best of the three against C2, after a
        /// warm-up.
        @Test("R-SYN-5: an attempt's end and a 429 while an owed follow covers 10,000 jobs hold the engine's actor at most C2's 10 ms per turn", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func inboundWalkTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.inboundWalk(members: 1_000)
            var runs: [InboundWalkRun] = []
            for _ in 0..<3 {
                runs.append(try await SyncBench.inboundWalk(members: 10_000))
            }
            for run in runs {
                #expect(run.jobs == 10_001 && run.followOwed && run.verdictWaits && run.moved == 0 && run.lane != nil, "\(run)")
            }
            let waits = runs.map(\.wait)
            let lanes = runs.compactMap(\.lane)
            let median = waits.sorted()[1]
            print("R-SYN-5 attempt end and 429 while an owed follow covers 10,000 jobs: longest actor wait at the 404 \(median) ms; followedLane \(lanes) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); runs \(waits)")
            #expect(median <= gapMax, "\(waits)")
            #expect((waits.min() ?? .infinity) <= Self.c2Budget, "the 404's turn: \(waits)")
            #expect((lanes.min() ?? .infinity) <= Self.c2Budget, "followedLane: \(lanes)")
        }
    }
}

/// An engine at SPEC §6's scale and its fakes (`SyncBench.scaleBench`).
@available(macOS 15.0, iOS 18.0, *)
struct ScaleBench {
    /// The engine, started and synced.
    let engine: SyncEngine
    /// Its remote source; unscripted transfers wait.
    let source: FakeRemoteSource
    /// Its device conditions.
    let conditions: FakeDeviceConditionsSource
    /// The on-demand entries of its manifest.
    let entries: [ManifestEntry]
    /// Each entry's size.
    let size: Int
    /// Its volume.
    let fileSystem: FakeFileSystem
    /// The file that takes the volume's room but `room` bytes (`nil` on a roomy volume).
    let ballast: URL?
    /// The engine's clock (and the store's).
    let time: ManualTimeSource

    /// Gives the volume its room back (the store learns it at its next free-space read).
    func removeBallast() throws {
        if let ballast = self.ballast {
            try self.fileSystem.removeItem(at: ballast)
        }
    }
}

/// Helpers of `SyncBenchmarks` (namespaced so no other package's helpers can collide).
enum SyncBench {
    /// An entry for `bytes`.
    static func entry(_ id: String, _ bytes: Data, policy: AssetPolicy = .standard) -> ManifestEntry {
        ManifestEntry(
            identifier: AssetID(id),
            fileExtension: "bin",
            remotePath: "media/\(id).bin",
            localPathComponents: ["dir"],
            byteSize: Int64(bytes.count),
            checksum: ContentHash.sha256(of: bytes),
            policy: policy
        )
    }

    /// The bare-array wire bytes of `entries`.
    static func manifestData(_ entries: [ManifestEntry]) -> Data {
        (try? JSONEncoder().encode(entries)) ?? Data("[]".utf8)
    }

    /// A manifest of `entries` with a digest derived from them.
    static func manifest(_ entries: [ManifestEntry], tag: String) -> ValidatedManifest {
        (try? ValidatedManifest(entries: entries, digest: ContentHash.sha256(of: Data(tag.utf8)))) ?? .empty()
    }

    // MARK: P-4

    /// The median of 21 plans (after 3 warm-ups) of `entries` entries against as many applied ones with 10 % churn:
    /// 2.5 % each added, removed, content-changed and metadata-changed (sync.md §4.5).
    static func medianPlanMilliseconds(entries count: Int) -> Double {
        var random = SplitMix64(seed: 0x4_0000 + UInt64(count))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var applied: [ManifestEntry] = []
        var records: [AssetID: AssetRecord] = [:]
        var live = Set<ContentHash>()
        records.reserveCapacity(count)
        for index in 0..<count {
            let hash = ContentHash.sha256(of: Data("p4-\(count)-\(index)".utf8))
            let entry = ManifestEntry(identifier: AssetID("asset.\(index)"), fileExtension: "png", remotePath: "media/\(index).png", localPathComponents: ["dir"], byteSize: 4_096, checksum: hash)
            applied.append(entry)
            let key = BlobKey(hash: hash, ext: AssetFileExtension("png")!)
            records[entry.identifier] = AssetRecord(entry: entry, residency: .present(blob: key, byteSize: 4_096, integrity: .verified), expectedBlob: hash, lastAccess: now)
            live.insert(hash)
        }
        var next: [ManifestEntry] = []
        next.reserveCapacity(count)
        for entry in applied {
            switch random.next() % 40 {
            case 0:
                continue
            case 1:
                var changed = entry
                changed.checksum = ContentHash.sha256(of: Data("p4-changed-\(entry.identifier.rawValue)".utf8))
                next.append(changed)
            case 2:
                var moved = entry
                moved.localPathComponents = ["moved"]
                next.append(moved)
            case 3:
                next.append(entry)
                let hash = ContentHash.sha256(of: Data("p4-added-\(entry.identifier.rawValue)".utf8))
                next.append(ManifestEntry(identifier: AssetID("added.\(entry.identifier.rawValue)"), fileExtension: "png", remotePath: "media/a-\(entry.identifier.rawValue).png", localPathComponents: ["dir"], byteSize: 4_096, checksum: hash))
            default:
                next.append(entry)
            }
        }
        let view = StorePlanningView(
            generation: 1,
            appliedManifest: SyncBench.manifest(applied, tag: "applied-\(count)"),
            records: records,
            liveBlobs: live,
            purgeEpoch: 0,
            stamp: nil,
            syncDue: false
        )
        let manifest = SyncBench.manifest(next, tag: "next-\(count)")
        let policy = PlanningPolicy(storage: StoragePolicy(), includeOnDemand: false, now: now)
        let space = FreeSpace(volumeImportant: 1 << 40, volumeOpportunistic: 1 << 40, usedBytes: 0, pendingReclaim: 0, budgetBytes: Int64.max, reserveBytes: 0)
        var samples: [Double] = []
        let clock = ContinuousClock()
        for round in 0..<24 {
            let started = clock.now
            let plan = SyncPlanner.plan(manifest: manifest, snapshot: view, scope: .all, policy: policy, freeSpace: space)
            let elapsed = clock.now - started
            precondition(!plan.fetches.isEmpty)
            if round >= 3 {
                samples.append(Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
            }
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    // MARK: Engines

    /// An engine over a `FakeFileSystem` store and `FakeRemoteSource` on `time` (P-14).
    @available(macOS 15.0, iOS 18.0, *)
    static func fakeEngine(time: ManualTimeSource, source: FakeRemoteSource, conditions: FakeDeviceConditionsSource) -> SyncEngine {
        let environment = AssetEnvironment(
            fileSystem: FakeFileSystem(time: time),
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 0x14),
            conditions: conditions,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        let store = AssetStore(
            configuration: StoreConfiguration(legacy: LegacyMigrationPolicy(enabled: false)),
            environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink())
        )
        return SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: SyncTuning()))
    }

    /// The wall time of a sync that prunes `count` on-demand entries (nothing is downloaded), with one subscriber that
    /// never pulls when `stalled`.
    @available(macOS 15.0, iOS 18.0, *)
    static func pruneSyncSeconds(count: Int, stalled: Bool) async throws -> Double {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let environment = AssetEnvironment(
            fileSystem: FakeFileSystem(time: time),
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 0x12),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        // No commit window: the timed sync needs no clock.
        let configuration = StoreConfiguration(
            location: .applicationSupport,
            policy: StoragePolicy(),
            legacy: LegacyMigrationPolicy(enabled: false),
            limits: ManifestLimits(),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
        let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: SyncTuning()))
        let keep = SyncBench.entry("keep", GeneratedPayload.bytes(seed: 0x12_000, offset: 0, length: 16), policy: .onDemand)
        let doomed = (0..<count).map { index in
            SyncBench.entry("p\(index)", GeneratedPayload.bytes(seed: 0x12_001 + UInt64(index), offset: 0, length: 16), policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData([keep] + doomed), etag: ETag(rawValue: "\"v1\""))])
        _ = try await engine.start().get()
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the first sync did not complete")
        }
        let subscription = stalled ? try await engine.subscribe().get() : nil
        await source.scriptManifest([.fetched(SyncBench.manifestData([keep]), etag: ETag(rawValue: "\"v2\""))])
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await engine.sync(.force)
        let elapsed = clock.now - started
        guard case .complete(let report) = outcome, report.pruned == count else {
            throw SyncBenchError.incomplete("the timed sync: \(outcome)")
        }
        if subscription != nil, await engine.introspect().bufferedEvents < count {
            throw SyncBenchError.incomplete("the stalled subscriber did not hold one slot per pruned id")
        }
        await engine.shutdown()
        _ = subscription
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    // MARK: Space parking at scale (C2, R-SYN-11)

    /// One call into the engine's actor: a caller waits at least for the turn it queued behind.
    static func pulse(_ engine: isolated SyncEngine) -> Int {
        engine.state.jobs.count
    }

    /// Whether the engine holds `count` jobs and none waits in a queue (each runs or is parked).
    static func noneQueued(_ engine: isolated SyncEngine, count: Int) -> Bool {
        engine.state.jobs.count == count && !engine.state.jobs.values.contains { $0.state == .queued }
    }

    /// Whether `transfer` was parked for lack of space after its ENOSPC and no job waits in a queue.
    static func parkedAfterENOSPC(_ engine: isolated SyncEngine, _ transfer: TransferID) -> Bool {
        engine.state.jobs[transfer]?.state == .blocked(.insufficientSpace) && !engine.state.jobs.values.contains { $0.state == .queued }
    }

    /// Runs `work` while a high-priority heartbeat calls into `engine` back to back; returns the heartbeat's longest
    /// wait in milliseconds (the longest actor turn it queued behind, plus scheduling noise).
    @available(macOS 15.0, iOS 18.0, *)
    static func longestWait(on engine: SyncEngine, during work: () async throws -> Void) async throws -> Double {
        let heartbeat = Task(priority: .high) {
            let clock = ContinuousClock()
            var longest = Duration.zero
            while !Task.isCancelled {
                let before = clock.now
                _ = await SyncBench.pulse(engine)
                longest = max(longest, clock.now - before)
            }
            return longest
        }
        let outcome: Result<Void, any Error>
        do {
            try await work()
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        heartbeat.cancel()
        let longest = await heartbeat.value
        try outcome.get()
        return Double(longest.components.seconds) * 1_000 + Double(longest.components.attoseconds) / 1e15
    }

    /// The heartbeat's longest waits while a prefetch group of `count` on-demand 400-byte members parks on a volume with
    /// 1,000 bytes above the reserve (two members start and hold, the others park `insufficientSpace`), then while the
    /// first started member's ENOSPC reads the free space and re-checks every parked member.
    @available(macOS 15.0, iOS 18.0, *)
    static func spaceParkingWaits(members count: Int) async throws -> (parking: Double, read: Double) {
        let bench = try await SyncBench.scaleBench(members: count, room: 1_000)
        let engine = bench.engine
        let source = bench.source
        let parking = try await SyncBench.longestWait(on: engine) {
            guard case .success = await engine.registerGroup(bench.entries.map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("the prefetch group was refused")
            }
            while !Task.isCancelled, !(await SyncBench.noneQueued(engine, count: count)) {
                await Task.yield()
            }
        }
        // The two started attempts reach the source in their drivers' own tasks.
        await engine.waitForAllHandles()
        let starts = await source.starts.map(\.id)
        guard starts.count == 2, let first = starts.first else {
            throw SyncBenchError.incomplete("expected two members to start, got \(starts.count)")
        }
        let read = try await SyncBench.longestWait(on: engine) {
            await source.script(first, [.fail(.insufficientSpace(requiredBytes: Int64(bench.size)))])
            while !Task.isCancelled, !(await SyncBench.parkedAfterENOSPC(engine, first)) {
                await Task.yield()
            }
        }
        await engine.shutdown()
        return (parking, read)
    }

    /// The heartbeat's longest waits while the network drops under a prefetch group of `count` on-demand members on a
    /// roomy volume (three start and hold, the others wait in the queue; the three then fail offline, which frees their
    /// slots, and the queued members park `offline`), then while it returns (every member is re-queued and three start).
    @available(macOS 15.0, iOS 18.0, *)
    static func networkEdgeWaits(members count: Int) async throws -> (offline: Double, online: Double) {
        let bench = try await SyncBench.scaleBench(members: count, room: nil)
        let engine = bench.engine
        let source = bench.source
        guard case .success = await engine.registerGroup(bench.entries.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
            await Task.yield()
        }
        await engine.waitForAllHandles()
        let running = await source.starts.map(\.id)
        guard running.count == 3 else {
            throw SyncBenchError.incomplete("expected three members to start, got \(running.count)")
        }
        let offline = try await SyncBench.longestWait(on: engine) {
            await bench.conditions.send(DeviceConditions(network: NetworkConditions(satisfied: false, expensive: false, constrained: false), power: PowerConditions(lowPowerMode: false, thermal: .nominal)))
            while !Task.isCancelled, !(await SyncBench.seesOffline(engine)) {
                await Task.yield()
            }
            for transfer in running {
                await source.script(transfer, [.fail(.offline(.noConnection))])
            }
            while !Task.isCancelled, !(await SyncBench.noneQueued(engine, count: count)) {
                await Task.yield()
            }
        }
        let online = try await SyncBench.longestWait(on: engine) {
            await bench.conditions.send(.unrestricted)
            while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
                await Task.yield()
            }
        }
        await engine.shutdown()
        return (offline, online)
    }

    /// The heartbeat's longest wait while the volume gains room under a prefetch group of `count` on-demand 400-byte
    /// members parked for lack of space (two start and hold on a volume with 1,000 bytes above the reserve, the others
    /// park `insufficientSpace`): the ballast is removed and one free-space read re-admits every parked member, until
    /// none is parked (a third member starts in the free slot, the others wait in the queue).
    @available(macOS 15.0, iOS 18.0, *)
    static func spaceReadmissionWait(members count: Int) async throws -> Double {
        let bench = try await SyncBench.scaleBench(members: count, room: 1_000)
        let engine = bench.engine
        guard case .success = await engine.registerGroup(bench.entries.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.noneQueued(engine, count: count)) {
            await Task.yield()
        }
        await engine.waitForAllHandles()
        try bench.removeBallast()
        let wait = try await SyncBench.longestWait(on: engine) {
            await engine.refreshFreeSpace()
            while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
                await Task.yield()
            }
        }
        await engine.shutdown()
        return wait
    }

    /// The heartbeat's longest wait while a prefetch handle of `count` on-demand members at `lane` on a roomy volume
    /// (three start and hold at prefetch priority, four at user-initiated priority; the others wait in the queue) is
    /// released, until the engine holds no job.
    @available(macOS 15.0, iOS 18.0, *)
    static func handleReleaseWait(members count: Int, lane: AssetPriority = .prefetch) async throws -> Double {
        let bench = try await SyncBench.scaleBench(members: count, room: nil)
        let engine = bench.engine
        guard case .success(let token) = await engine.registerGroup(bench.entries.map(\.identifier), lane: lane) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
            await Task.yield()
        }
        await engine.waitForAllHandles()
        let wait = try await SyncBench.longestWait(on: engine) {
            await engine.releaseGroup(token)
            while !Task.isCancelled, !(await SyncBench.noJobs(engine)) {
                await Task.yield()
            }
        }
        await engine.shutdown()
        return wait
    }

    /// The heartbeat's longest wait, and how many members were joined again while only the released handle wanted them,
    /// while a handle of `count` on-demand members at `lane` on a roomy volume (three start and hold, the others wait in
    /// the queue) is released and its members are joined again, until the release ended (nothing left to release, no
    /// follow-up turn owed) and every member is again a job that runs or waits in its queue. The release's own turn and
    /// each of its later turns are met by one join batch (`materializationLimit` members, what a handle's join task adds
    /// per turn) from the end of the release order, which the release reaches last: those members are reinstated, not
    /// joined afresh. A handle over the same identifiers is then registered and joins the rest.
    @available(macOS 15.0, iOS 18.0, *)
    static func handleRejoinWait(members count: Int, lane: AssetPriority) async throws -> (wait: Double, reinstated: Int) {
        let bench = try await SyncBench.scaleBench(members: count, room: nil)
        let engine = bench.engine
        let ids = bench.entries.map(\.identifier)
        guard case .success(let token) = await engine.registerGroup(ids, lane: lane) else {
            throw SyncBenchError.incomplete("the handle was refused")
        }
        while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
            await Task.yield()
        }
        await engine.waitForAllHandles()
        // The release visits the members in the order the handle joined them (sorted identifiers).
        let byID = Dictionary(uniqueKeysWithValues: bench.entries.map { ($0.identifier, $0) })
        let order = Set(ids).sorted().compactMap { byID[$0] }
        let batch = await engine.materializationLimit
        var reinstated = 0
        let wait = try await SyncBench.longestWait(on: engine) {
            var tail = order[...]
            reinstated += await SyncBench.releaseAndRejoin(engine, token: token, batch: Array(tail.suffix(batch)), lane: lane)
            tail = tail.dropLast(batch)
            while !Task.isCancelled, !tail.isEmpty {
                guard let joined = await SyncBench.rejoinWhileReleasing(engine, batch: Array(tail.suffix(batch)), lane: lane) else {
                    break
                }
                reinstated += joined
                tail = tail.dropLast(batch)
            }
            guard case .success = await engine.registerGroup(ids, lane: lane) else {
                throw SyncBenchError.incomplete("the second handle was refused")
            }
            while !Task.isCancelled, !(await SyncBench.rejoined(engine, count: count)) {
                await Task.yield()
            }
        }
        await engine.shutdown()
        return (wait, reinstated)
    }

    /// Releases the handle `token` and, in the same turn, joins `batch` again at `lane` as a handle's join batch would
    /// (its interests, then a pump); the members only the released handle wanted, which are reinstated.
    static func releaseAndRejoin(_ engine: isolated SyncEngine, token: InterestToken, batch: [ManifestEntry], lane: AssetPriority) -> Int {
        engine.performReleaseGroup(token)
        return SyncBench.rejoin(engine, batch: batch, lane: lane)
    }

    /// Joins `batch` again at `lane` while a release is pending, as one join batch; `nil` once no release is pending.
    static func rejoinWhileReleasing(_ engine: isolated SyncEngine, batch: [ManifestEntry], lane: AssetPriority) -> Int? {
        guard !engine.state.releasing.isEmpty else {
            return nil
        }
        return SyncBench.rejoin(engine, batch: batch, lane: lane)
    }

    /// Adds an interest at `lane` in each of `batch`, then pumps; returns how many of them were queued jobs only released
    /// handles wanted (each then reinstated at its place).
    static func rejoin(_ engine: isolated SyncEngine, batch: [ManifestEntry], lane: AssetPriority) -> Int {
        var reinstated = 0
        for entry in batch {
            if let job = engine.state.jobs[entry.transferID], job.state == .queued, engine.isReleasedOnly(job) {
                reinstated += 1
            }
            engine.addSystemInterest(entry: entry, lane: lane)
        }
        engine.pump()
        return reinstated
    }

    /// Whether a release ended (nothing left to release, no follow-up turn owed) with `count` jobs, none parked.
    static func rejoined(_ engine: isolated SyncEngine, count: Int) -> Bool {
        engine.state.releasing.isEmpty && !engine.state.releaseFollowUpScheduled && SyncBench.noneParked(engine, count: count)
    }

    /// The heartbeat's longest wait while a user-initiated resolve's caller cancels beside a prefetch handle of `count`
    /// on-demand members on a roomy volume (three members start and hold, the others wait in the queue; the resolve's
    /// asset, outside the handle, starts in the fourth slot), until its job is gone.
    @available(macOS 15.0, iOS 18.0, *)
    static func resolveCancelWait(members count: Int) async throws -> Double {
        let bench = try await SyncBench.scaleBench(members: count + 1, room: nil)
        let engine = bench.engine
        let members = bench.entries.dropLast().map(\.identifier)
        let resolved = try #require(bench.entries.last)
        guard case .success = await engine.registerGroup(Array(members), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
            await Task.yield()
        }
        let caller = Task {
            await engine.awaitAsset(resolved.identifier, lane: .userInitiated)
        }
        let transfer = resolved.transferID
        while !Task.isCancelled, !(await SyncBench.isRunning(engine, transfer)) {
            await Task.yield()
        }
        await engine.waitForAllHandles()
        let wait = try await SyncBench.longestWait(on: engine) {
            caller.cancel()
            guard case .failure(.cancelled) = await caller.value else {
                throw SyncBenchError.incomplete("the cancelled resolve was not answered cancelled")
            }
            while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
                await Task.yield()
            }
        }
        await engine.shutdown()
        return wait
    }

    /// The heartbeat's longest wait while the clock reaches the cooldown's end of a breaker that parked a prefetch group
    /// of `count` on-demand members on a roomy volume: the running members answer 500 until the 5xx breaker opens (three
    /// run at a time; five samples open it), the open breaker parks every queued member, then the clock jumps to the
    /// cooldown's end, until every member is parked again but the half-open probe and nothing is owed.
    @available(macOS 15.0, iOS 18.0, *)
    static func cooldownEndWait(members count: Int) async throws -> Double {
        let bench = try await SyncBench.scaleBench(members: count, room: nil)
        let engine = bench.engine
        guard case .success = await engine.registerGroup(bench.entries.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
            await Task.yield()
        }
        // Each round fails the members running once one runs; how many run at a round's start depends on when the
        // pump refilled the slots, so the loop is bounded by the failures injected, never by a number of rounds.
        var failed = 0
        while !Task.isCancelled, await SyncBench.cooldownEnd(engine) == nil {
            guard failed < count else {
                throw SyncBenchError.incomplete("the breaker did not open")
            }
            await engine.awaitCondition { engine in
                !SyncBench.running(engine).isEmpty || SyncBench.cooldownEnd(engine) != nil
            }
            await engine.waitForAllHandles()
            let running = await SyncBench.running(engine)
            failed += running.count
            for transfer in running {
                await bench.source.script(transfer, [.fail(.transient(.serverError(httpStatus: 500), retryAfter: nil))])
            }
            while !Task.isCancelled, !(await SyncBench.attemptsEnded(engine, running)) {
                await Task.yield()
            }
        }
        while !Task.isCancelled, !(await SyncBench.originSettled(engine, probing: false)) {
            await Task.yield()
        }
        guard let until = await SyncBench.cooldownEnd(engine) else {
            throw SyncBenchError.incomplete("the breaker closed before its cooldown ended")
        }
        let wait = try await SyncBench.longestWait(on: engine) {
            bench.time.advance(to: until)
            while !Task.isCancelled, !(await SyncBench.originSettled(engine, probing: true)) {
                await Task.yield()
            }
        }
        await engine.shutdown()
        return wait
    }

    /// The heartbeat's longest wait, and the chain's total time in seconds, while the clock reaches the cooldown's end of a
    /// breaker that parked a prefetch group of `count` on-demand members on a roomy volume, every member answering 400 from
    /// then on: the running members answer 500 until the 5xx breaker opens, as in `cooldownEndWait`, then every member is
    /// scripted to answer 400 (a probe exit without a verdict that writes nothing to the store), and the clock jumps to
    /// the cooldown's end, until no member is parked, queued, downloading or
    /// owed a re-queue (each probed once and failed, or waits for a retry deadline the clock has not reached).
    @available(macOS 15.0, iOS 18.0, *)
    static func probeChainWait(members count: Int) async throws -> (wait: Double, total: Double) {
        let bench = try await SyncBench.scaleBench(members: count, room: nil)
        let engine = bench.engine
        // The chain is 10,000 probes in a row, each a handful of hops between the engine's owned tasks; below the
        // heartbeat's priority each hop queued behind its pulses on the actor, and a chain took 6 to 88 s on a quiet host.
        // The owned tasks run at the heartbeat's priority, as the engine tests' harness raises them (F-17); the turns are
        // the same, and no measured figure depends on a task's priority.
        await SyncBench.raiseOwnedTaskPriority(engine)
        guard case .success = await engine.registerGroup(bench.entries.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        // Each wait below is driven by the engine's own notifications with an O(1) condition, then confirmed once by the
        // O(n) check: polling the O(n) check on the actor in a loop ran it between the chain's turns at default priority
        // against the engine's utility-priority tasks, where it took actor time from the chain and sat in the heartbeat's
        // measured waits.
        await engine.awaitCondition { $0.state.jobs.count == count }
        while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
            await Task.yield()
        }
        var failed = 0
        while !Task.isCancelled, await SyncBench.cooldownEnd(engine) == nil {
            guard failed < count else {
                throw SyncBenchError.incomplete("the breaker did not open")
            }
            await engine.awaitCondition { engine in
                !SyncBench.running(engine).isEmpty || SyncBench.cooldownEnd(engine) != nil
            }
            await engine.waitForAllHandles()
            let running = await SyncBench.running(engine)
            failed += running.count
            for transfer in running {
                await bench.source.script(transfer, [.fail(.transient(.serverError(httpStatus: 500), retryAfter: nil))])
            }
            while !Task.isCancelled, !(await SyncBench.attemptsEnded(engine, running)) {
                await Task.yield()
            }
        }
        await engine.awaitCondition { SyncBench.originQuiet($0) }
        while !Task.isCancelled, !(await SyncBench.originSettled(engine, probing: false)) {
            await Task.yield()
        }
        guard let until = await SyncBench.cooldownEnd(engine) else {
            throw SyncBenchError.incomplete("the breaker closed before its cooldown ended")
        }
        for entry in bench.entries {
            await bench.source.script(entry.transferID, [.fail(.rejected(.unexpectedStatus(400)))])
        }
        let clock = ContinuousClock()
        var total = Duration.zero
        let wait = try await SyncBench.longestWait(on: engine) {
            let start = clock.now
            bench.time.advance(to: until)
            // `advance(to:)` can stop 1 ns short of `until` (seconds as a `Double`, truncated): each step adds exactly 1 ns.
            while bench.time.monotonicNow() < until {
                bench.time.advance(by: 1e-9)
            }
            await engine.awaitCondition { $0.state.circuitParked.isEmpty && SyncBench.originQuiet($0) }
            while !Task.isCancelled, !(await SyncBench.chainEnded(engine)) {
                await Task.yield()
            }
            total = clock.now - start
        }
        await engine.shutdown()
        return (wait, Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18)
    }

    /// Whether no transfer is in flight and no re-queue, park, sweep or pump is owed to a later turn: O(1), so a wait on
    /// it, re-evaluated after every mutation of the engine, adds nothing measurable to a turn. A wait on it precedes the
    /// O(n) `originSettled(_:probing: false)`, which then confirms that no job is left queued.
    static func originQuiet(_ engine: isolated SyncEngine) -> Bool {
        engine.state.inFlight.isEmpty && engine.state.originOwed.isEmpty && !engine.state.readmissionFollowUpScheduled
            && !engine.state.pumpFollowUpScheduled
    }

    /// Spawns every later owned task of `engine` at the heartbeat's priority (`.high`) or above (`ownedTaskPriorityFloor`,
    /// the seam the engine tests' harness uses, F-17).
    static func raiseOwnedTaskPriority(_ engine: isolated SyncEngine) {
        engine.state.ownedTaskPriorityFloor = .high
    }

    /// Whether a chain of probes ended: no job parked by the breaker, queued, downloading or owed a re-queue, and no
    /// follow-up turn owed.
    static func chainEnded(_ engine: isolated SyncEngine) -> Bool {
        engine.state.circuitParked.isEmpty && SyncBench.originSettled(engine, probing: false)
    }

    /// The heartbeat's longest wait while a 429 extends the origin's throttle under `count` user-initiated `resolve`
    /// callers of on-demand members: one member's 1 s 429 throttles the origin, the callers' jobs park within
    /// `interactiveMaxWait`, then a held member answers 429 with 60 s, until every caller is answered. Each caller must get
    /// the fail-fast answer.
    @available(macOS 15.0, iOS 18.0, *)
    static func throttleExtensionWait(waiters count: Int) async throws -> Double {
        let bench = try await SyncBench.scaleBench(members: count + 2, room: nil)
        let engine = bench.engine
        let throttling = bench.entries[0]
        let extending = bench.entries[1]
        await bench.source.script(extending.transferID, [.hold])
        await bench.source.script(throttling.transferID, [.fail(.transient(.throttled, retryAfter: .seconds(1)))])
        let holder = Task { await engine.awaitAsset(extending.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[extending.transferID]?.active != nil }
        let parker = Task { await engine.awaitAsset(throttling.identifier, lane: .prefetch) }
        await engine.awaitCondition { $0.state.jobs[throttling.transferID]?.state.isThrottleParked == true }
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        for entry in bench.entries.dropFirst(2) {
            callers.append(Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) })
        }
        await engine.awaitCondition { engine in
            engine.state.throttleParked.count == count + 1 && engine.state.waiters.count == count + 2 && !engine.state.pumpFollowUpScheduled
        }
        let wait = try await SyncBench.longestWait(on: engine) {
            await bench.source.release(extending.transferID, with: .failed(.transient(.throttled, retryAfter: .seconds(60))))
            await engine.awaitCondition { engine in
                engine.state.waiters.count == 2 && !engine.state.throttleAnswersScheduled
            }
        }
        for caller in callers {
            guard case .failure(.serverUnavailable) = await caller.value else {
                throw SyncBenchError.incomplete("a user-initiated caller was not failed fast")
            }
        }
        await engine.shutdown()
        _ = await holder.value
        _ = await parker.value
        return wait
    }

    /// When the origin's open breaker half-opens, if it is open.
    static func cooldownEnd(_ engine: isolated SyncEngine) -> MonotonicInstant? {
        for breaker in engine.state.breakers.values {
            if case .open(_, let until, _) = breaker.state {
                return until
            }
        }
        return nil
    }

    /// The transfers whose jobs download.
    static func running(_ engine: isolated SyncEngine) -> [TransferID] {
        engine.state.inFlight.filter { engine.state.jobs[$0]?.state == .downloading }.sorted()
    }

    /// Whether none of `transfers` downloads any more.
    static func attemptsEnded(_ engine: isolated SyncEngine, _ transfers: [TransferID]) -> Bool {
        transfers.allSatisfy { engine.state.jobs[$0]?.state != .downloading }
    }

    /// Whether no job waits in a queue and no re-queue, park or sweep is owed to a later turn, with a transfer running
    /// (the half-open probe) when `probing`, none otherwise.
    static func originSettled(_ engine: isolated SyncEngine, probing: Bool) -> Bool {
        let downloading = engine.state.jobs.values.contains { $0.state == .downloading }
        return downloading == probing && engine.state.originOwed.isEmpty && !engine.state.readmissionFollowUpScheduled
            && !engine.state.pumpFollowUpScheduled && !engine.state.jobs.values.contains { $0.state == .queued }
    }

    /// Whether `transfer`'s job downloads.
    static func isRunning(_ engine: isolated SyncEngine, _ transfer: TransferID) -> Bool {
        engine.state.jobs[transfer]?.state == .downloading
    }

    /// Whether the engine holds no job.
    static func noJobs(_ engine: isolated SyncEngine) -> Bool {
        engine.state.jobs.isEmpty
    }

    /// Whether the engine applied conditions without a network.
    static func seesOffline(_ engine: isolated SyncEngine) -> Bool {
        engine.state.conditions?.network.satisfied == false
    }

    /// Whether the engine holds `count` jobs and none is parked or failed (each runs or waits in a queue).
    static func noneParked(_ engine: isolated SyncEngine, count: Int) -> Bool {
        engine.state.jobs.count == count && !engine.state.jobs.values.contains { job in
            switch job.state {
            case .blocked, .failed:
                return true
            case .queued, .downloading, .verifying, .committing:
                return false
            }
        }
    }

    /// An engine over a fake volume, synced to a manifest of `count` on-demand 400-byte entries (none present), whose
    /// free-space reading leaves `room` bytes above the reserve (32 MiB when `nil`); unscripted transfers wait in the
    /// fake source.
    @available(macOS 15.0, iOS 18.0, *)
    static func scaleBench(members count: Int, room: Int64?) async throws -> ScaleBench {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let conditions = FakeDeviceConditionsSource()
        // 32 MiB above the reserve hold the store's files; a ballast takes the rest but `room` (a ballast on the fake's
        // default 64 GiB volume is a 64 GiB buffer).
        let capacity = StoragePolicy().reserveFreeBytes + (32 << 20)
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: capacity, opportunisticCapacity: capacity)
        )
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 0x11),
            conditions: conditions,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        // No commit window: nothing here needs the clock.
        let configuration = StoreConfiguration(
            location: .applicationSupport,
            policy: StoragePolicy(),
            legacy: LegacyMigrationPolicy(enabled: false),
            limits: ManifestLimits(),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
        let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: SyncTuning()))
        let size = 400
        let entries = (0..<count).map { index in
            SyncBench.entry("s\(index)", GeneratedPayload.bytes(seed: 0x11_000 + UInt64(index), offset: 0, length: size), policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(entries), etag: ETag(rawValue: "\"v1\""))])
        _ = try await engine.start().get()
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the setup sync did not complete")
        }
        var ballast: URL?
        if let room {
            let free = try await store.freeSpace()
            let ballastBytes = free.volumeOpportunistic - free.reserveBytes - room
            guard ballastBytes >= 0 else {
                throw SyncBenchError.incomplete("the store's files left less than \(room) bytes above the reserve")
            }
            let file = URL(fileURLWithPath: "/fake-volume/Library/Application Support/ballast")
            try fileSystem.write(Data(repeating: 1, count: Int(ballastBytes)), to: file, mode: .truncate)
            ballast = file
            await engine.refreshFreeSpace()
        }
        return ScaleBench(engine: engine, source: source, conditions: conditions, entries: entries, size: size, fileSystem: fileSystem, ballast: ballast, time: time)
    }

    /// An engine configuration with defaults and `tuning`.
    static func configuration(tuning: SyncTuning, remote: RemoteConfiguration = RemoteConfiguration()) -> EngineConfiguration {
        EngineConfiguration(
            tuning: tuning,
            storage: StoragePolicy(),
            network: NetworkPolicy(),
            power: PowerPolicy(),
            refresh: .oncePerAppVersion,
            remote: remote,
            limits: ManifestLimits()
        )
    }

    /// What one step of `drive` found, decided in one engine turn.
    enum DriveStep: Sendable {
        /// The predicate holds.
        case done
        /// The clock moved to the earliest sleeper.
        case advanced
        /// The advance budget is spent while a sleeper was still due to be woken.
        case exhausted
        /// Nothing may be woken now: wait for a change of these, or for one more sleeper than `sleepers`.
        case wait(EngineIntrospection, fence: MonotonicInstant?, sleepers: Int)
    }

    /// The earliest deadline that would time out work the fakes finish without the clock: an in-flight manifest
    /// fetch's deadline (`FakeRemoteSource` answers at once) or a half-open probe's watchdog (a copy of the Sync tests'
    /// `SyncEngine.clockFence()` seam, which this target does not link).
    static func clockFence(_ engine: isolated SyncEngine) -> MonotonicInstant? {
        var fence: MonotonicInstant?
        if let fetch = engine.state.manifestFetch, let at = engine.state.heap.deadline(for: .manifest(fetch.sequence)) {
            fence = at
        }
        for origin in engine.state.breakers.keys.sorted() {
            guard case .halfOpen(_, _, _?, let watchdog?)? = engine.state.breakers[origin]?.state else {
                continue
            }
            fence = min(fence ?? watchdog, watchdog)
        }
        return fence
    }

    /// One step of `drive` in one engine turn: the predicate, the clock fence, the sleeper count (read before the
    /// deadline: a sleeper registered after the count, even one the deadline read misses, ends the wait for one more)
    /// and the advance, so the clock never jumps to a timeout of work the engine began a moment earlier.
    @available(macOS 15.0, iOS 18.0, *)
    static func driveStep(
        _ engine: isolated SyncEngine,
        time: ManualTimeSource,
        maxStep: TimeInterval,
        budgetLeft: Bool,
        predicate: (EngineIntrospection) -> Bool
    ) -> DriveStep {
        let state = engine.introspect()
        if predicate(state) {
            return .done
        }
        let fence = SyncBench.clockFence(engine)
        let sleepers = time.pendingSleepers
        guard let deadline = time.nextDeadline, deadline <= time.monotonicNow().adding(seconds: maxStep), fence.map({ deadline < $0 }) ?? true else {
            return .wait(state, fence: fence, sleepers: sleepers)
        }
        guard budgetLeft else {
            return .exhausted
        }
        time.advance(to: deadline)
        return .advanced
    }

    /// Drives `time` until `predicate` holds (the engine's alarm and store waits move only with the manual clock), as
    /// the Sync tests' `EngineHarness.drive` does since close-out cycle 11 (L4-R17): each step advances to the earliest
    /// sleeper when it is at most 20 s away (commit windows, installs and the 10 s deletion grace pass) and earlier than
    /// the engine's clock fence, deciding that in one engine turn; otherwise it waits for whichever comes first: the
    /// predicate, a change of the engine's counters or fence, or one more sleeper. The budget bounds the clock's moves,
    /// not the waits (how many intermediate states a wait observes depends on scheduling); every wait ends on
    /// cancellation.
    @available(macOS 15.0, iOS 18.0, *)
    static func drive(engine: SyncEngine, time: ManualTimeSource, until predicate: @escaping @Sendable (EngineIntrospection) -> Bool) async throws {
        var advanced = 0
        while true {
            switch await SyncBench.driveStep(engine, time: time, maxStep: 20, budgetLeft: advanced < 1_024, predicate: predicate) {
            case .done:
                return
            case .advanced:
                advanced += 1
            case .exhausted:
                throw SyncBenchError.incomplete("the clock moved 1,024 times and the predicate still does not hold")
            case .wait(let state, let fence, let waiting):
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await engine.awaitCondition { engine in
                            let now = engine.introspect()
                            return now != state || predicate(now) || SyncBench.clockFence(engine) != fence
                        }
                    }
                    group.addTask {
                        await time.waitForSleepers(atLeast: waiting + 1)
                    }
                    _ = await group.next()
                    group.cancelAll()
                }
                try Task.checkCancellation()
            }
        }
    }

    /// A directory inside this repository (`.build-tests/`, git-ignored); the caller removes it.
    static func directory(_ name: String, filePath: String = #filePath) throws -> URL {
        let repository = URL(fileURLWithPath: filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent(".build-tests/bench-sync/\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: P-7

    /// Syncs a catalog of `catalogBytes` (4 MiB assets streamed in 256 KiB chunks) into real files and returns the peak
    /// resident delta above the resident size measured before the engine started.
    @available(macOS 15.0, iOS 18.0, *)
    static func syncMemoryDelta(catalogBytes: Int64) async throws -> UInt64 {
        let directory = try SyncBench.directory("p7")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let assetBytes: Int64 = 4 << 20
        let count = Int(max(1, catalogBytes / assetBytes))
        let entries = (0..<count).map { index -> ManifestEntry in
            let seed = 0x7_0000 + UInt64(index)
            return ManifestEntry(
                identifier: AssetID("p7.\(index)"),
                fileExtension: "bin",
                remotePath: "media/p7-\(index).bin",
                localPathComponents: ["dir"],
                byteSize: assetBytes,
                checksum: GeneratedPayload.sha256(seed: seed, byteCount: assetBytes)
            )
        }
        let sampler = MemoryProbe.PeakSampler()
        let fake = FakeRemoteSource()
        await fake.scriptManifest([.fetched(SyncBench.manifestData(entries), etag: ETag(rawValue: "\"p7\""))])
        for (index, entry) in entries.enumerated() {
            await fake.script(entry.transferID, [.stageGenerated(seed: 0x7_0000 + UInt64(index), byteCount: assetBytes)])
        }
        let source = SamplingSource(base: fake, sampler: sampler)
        let environment = AssetEnvironment(
            fileSystem: LiveFileSystem(),
            metadataExecutor: DispatchBlockingExecutor(label: "bench-sync.metadata"),
            bulkExecutor: DispatchBlockingExecutor(label: "bench-sync.bulk"),
            time: LiveTimeSource(),
            random: SeededRandom(seed: 0x7),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        let store = AssetStore(
            configuration: StoreConfiguration(location: .custom(directory), legacy: LegacyMigrationPolicy(enabled: false)),
            environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink())
        )
        let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: SyncTuning()))
        sampler.start()
        _ = try await engine.start().get()
        let outcome = await engine.sync(.force)
        sampler.sample()
        guard outcome.isComplete else {
            await engine.shutdown()
            throw SyncBenchError.incomplete(String(describing: outcome))
        }
        await engine.waitUntil { $0.groups == 0 }
        sampler.sample()
        await engine.shutdown()
        return sampler.peakDelta
    }

    // MARK: P-11

    /// Seconds a sync of `assets` 1 KiB assets takes over the real HTTP source against the loopback server answering
    /// after `latencyMs`, at `concurrency`.
    @available(macOS 15.0, iOS 18.0, *)
    static func timedLoopbackSync(assets: Int, latencyMs: Double, concurrency: Int) async throws -> Double {
        let bodies = (0..<assets).map { GeneratedPayload.bytes(seed: 0x11_000 + UInt64($0), offset: 0, length: 1_024) }
        let entries = bodies.enumerated().map { index, body in SyncBench.entry("p11.\(index)", body) }
        let manifest = SyncBench.manifestData(entries)
        let latency = UInt64(latencyMs * 1_000_000)
        let server = LoopbackHTTPServer(delay: LiveLoopbackDelay()) { request in
            if request.target == "/manifest.json" {
                return LoopbackResponse(body: manifest)
            }
            let index = Int(request.target.dropFirst("/media/p11.".count).dropLast(".bin".count)) ?? 0
            return LoopbackResponse(body: bodies[min(max(index, 0), bodies.count - 1)], latencyNanoseconds: latency)
        }
        let port = try await server.start()
        let base = try #require(URL(string: "http://127.0.0.1:\(port)/"))
        let time = LiveTimeSource()
        let environment = AssetEnvironment(
            fileSystem: FakeFileSystem(time: time),
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 0x11),
            conditions: FakeDeviceConditionsSource(),
            remoteSources: LoopbackBenchFactory(base: base, connections: max(concurrency, 1) + 1),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        let store = AssetStore(
            configuration: StoreConfiguration(legacy: LegacyMigrationPolicy(enabled: false)),
            environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink())
        )
        let tuning = SyncTuning(maxConcurrentTransfers: concurrency, reservedInteractiveSlots: 0)
        let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: tuning, remote: RemoteConfiguration(http: HTTPSourceConfiguration(baseURL: base))))
        _ = try await engine.start().get()
        // `start()` launched the due run; its manifest fetch is part of the measured run either way.
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await engine.sync(.force)
        await engine.waitUntil { $0.groups == 0 }
        let elapsed = clock.now - started
        let report = await engine.availability(scope: .all)
        await engine.shutdown()
        await server.stop()
        guard (try? report.get())?.present == assets else {
            throw SyncBenchError.incomplete(String(describing: outcome))
        }
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}

/// Why a benchmark could not measure.
enum SyncBenchError: Error {
    /// The sync did not complete.
    case incomplete(String)
}

/// A source that samples the resident size at every transfer start, then forwards to `base` (P-7).
@available(macOS 15.0, iOS 18.0, *)
struct SamplingSource: RemoteSource, StagingAttachable {
    let base: FakeRemoteSource
    let sampler: MemoryProbe.PeakSampler

    var originID: String {
        self.base.originID
    }

    var capabilities: RemoteSourceCapabilities {
        self.base.capabilities
    }

    func attach(staging: any StagingSink) async {
        await self.base.attach(staging: staging)
    }

    func fetchManifest(_ request: ManifestRequest) async throws(TransferError) -> ManifestFetchResult {
        try await self.base.fetchManifest(request)
    }

    func transfer(_ request: TransferRequest) async -> any TransferHandle {
        self.sampler.sample()
        return await self.base.transfer(request)
    }

    func reattachedTransfers() async -> [ReattachedTransfer] {
        await self.base.reattachedTransfers()
    }

    func cancelTransfer(_ name: StagingFileName) async {
        await self.base.cancelTransfer(name)
    }

    func reclaimSourceCopies(_ report: AdoptionReport) async -> ReclaimReport {
        await self.base.reclaimSourceCopies(report)
    }

    func sourceCopyBytes() async -> Int64 {
        await self.base.sourceCopyBytes()
    }

    func handleBackgroundEvents(identifier: String) async {
        await self.base.handleBackgroundEvents(identifier: identifier)
    }

    func invalidate() async {
        await self.base.invalidate()
    }
}

/// The real HTTP source over the store's staging sink against the loopback server (P-11).
struct LoopbackBenchFactory: RemoteSourceFactory {
    let base: URL
    let connections: Int

    func makeRemoteSource(configuration: RemoteConfiguration, staging: any StagingSink, log: LogRoute) async throws(AssetError) -> any RemoteSource {
        let policy = TransportSecurityPolicy.loopbackTesting(allowedHosts: ["127.0.0.1"])
        let delegate = SessionDelegate(mode: .foreground, staging: staging, policy: policy)
        let foreground = ForegroundTransferBackend(delegate: delegate, maxConnectionsPerHost: self.connections, requestTimeout: 30, appKey: nil, log: log)
        let http = HTTPSourceConfiguration(baseURL: self.base, appKey: nil, maxConnectionsPerHost: self.connections, requestTimeout: 30)
        return HTTPRemoteSource(configuration: http, staging: staging, policy: policy, foreground: foreground, background: nil, log: log)
    }
}

extension SyncOutcome {
    /// Whether the run completed.
    var isComplete: Bool {
        if case .complete = self {
            return true
        }
        return false
    }

}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    /// `scaleBench(members:room: nil)` with production's executors: the engine's manifest decode and the store's units
    /// run on dedicated dispatch queues, off the actors (`InlineBlockingExecutor` would run them on the calling actor and
    /// charge them to its turn).
    static func dispatchBench(members count: Int) async throws -> ScaleBench {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let conditions = FakeDeviceConditionsSource()
        let capacity = StoragePolicy().reserveFreeBytes + (32 << 20)
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: capacity, opportunisticCapacity: capacity)
        )
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: DispatchBlockingExecutor(label: "bench.metadata"),
            bulkExecutor: DispatchBlockingExecutor(label: "bench.bulk"),
            time: time,
            random: SeededRandom(seed: 0x11),
            conditions: conditions,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        let configuration = StoreConfiguration(
            location: .applicationSupport,
            policy: StoragePolicy(),
            legacy: LegacyMigrationPolicy(enabled: false),
            limits: ManifestLimits(),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
        let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: SyncTuning()))
        let size = 400
        let entries = (0..<count).map { index in
            SyncBench.entry("s\(index)", GeneratedPayload.bytes(seed: 0x11_000 + UInt64(index), offset: 0, length: size), policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(entries), etag: ETag(rawValue: "\"v1\""))])
        _ = try await engine.start().get()
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the setup sync did not complete")
        }
        return ScaleBench(engine: engine, source: source, conditions: conditions, entries: entries, size: size, fileSystem: fileSystem, ballast: nil, time: time)
    }

    /// The heartbeat's longest wait while `shutdown()` runs over a `count`-member prefetch group (three run, the others
    /// wait in the queue) whose members, when `waiters`, each have one waiting user-initiated `resolve` caller; every
    /// caller must be answered `shutDown`.
    static func shutdownWait(members count: Int, waiters: Bool = true) async throws -> Double {
        let bench = try await SyncBench.dispatchBench(members: count)
        let engine = bench.engine
        guard case .success = await engine.registerGroup(bench.entries.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
            await Task.yield()
        }
        await engine.waitForAllHandles()
        var callers: [Task<Result<AssetLocation, AssetError>, Never>] = []
        callers.reserveCapacity(count)
        for entry in bench.entries where waiters {
            callers.append(Task { await engine.awaitAsset(entry.identifier, lane: .userInitiated) })
        }
        let expected = waiters ? count : 0
        await engine.awaitCondition { $0.state.waiters.count == expected }
        await engine.waitForAllHandles()
        let wait = try await SyncBench.longestWait(on: engine) {
            await engine.shutdown()
        }
        for caller in callers {
            guard case .failure(.shutDown) = await caller.value else {
                throw SyncBenchError.incomplete("a waiting resolve was not answered shutDown")
            }
        }
        return wait
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    /// The heartbeat's longest wait while a forced sync applies a manifest with one more entry under a `count`-member
    /// prefetch group (three run, the others wait in the queue).
    static func refreshWait(members count: Int) async throws -> Double {
        let bench = try await SyncBench.dispatchBench(members: count)
        let engine = bench.engine
        guard case .success = await engine.registerGroup(bench.entries.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
            await Task.yield()
        }
        await engine.waitForAllHandles()
        let extra = SyncBench.entry("extra", GeneratedPayload.bytes(seed: 0xE1, offset: 0, length: 400), policy: .onDemand)
        await bench.source.scriptManifest([.fetched(SyncBench.manifestData(bench.entries + [extra]), etag: ETag(rawValue: "\"v2\""))])
        let wait = try await SyncBench.longestWait(on: engine) {
            guard await engine.sync(.force).isComplete else {
                throw SyncBenchError.incomplete("the refresh did not complete")
            }
        }
        await engine.shutdown()
        return wait
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    /// The heartbeat's longest wait while a forced sync applies a manifest that changes the content of every member of a
    /// waiting prefetch group of `count` on-demand entries; every invariant must hold afterwards.
    static func changedRefreshWait(members count: Int) async throws -> Double {
        let bench = try await SyncBench.dispatchBench(members: count)
        let engine = bench.engine
        guard case .success = await engine.registerGroup(bench.entries.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.noneParked(engine, count: count)) {
            await Task.yield()
        }
        await engine.waitForAllHandles()
        let changed = bench.entries.enumerated().map { index, entry in
            SyncBench.entry(entry.identifier.rawValue, GeneratedPayload.bytes(seed: 0x77_000 + UInt64(index), offset: 0, length: bench.size), policy: .onDemand)
        }
        await bench.source.scriptManifest([.fetched(SyncBench.manifestData(changed), etag: ETag(rawValue: "\"v2\""))])
        let wait = try await SyncBench.longestWait(on: engine) {
            guard await engine.sync(.force).isComplete else {
                throw SyncBenchError.incomplete("the refresh did not complete")
            }
        }
        let violations = await engine.invariantViolations()
        await engine.shutdown()
        guard violations.isEmpty else {
            throw SyncBenchError.incomplete("invariants: \(violations.prefix(3))")
        }
        return wait
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    /// The heartbeat's longest wait while a forced sync applies a manifest that drops `count` on-demand ids while one
    /// subscriber reads nothing.
    static func pruneAnnouncementWait(count: Int) async throws -> Double {
        let bench = try await SyncBench.dispatchBench(members: count)
        let engine = bench.engine
        let subscription = try await engine.subscribe().get()
        let keep = SyncBench.entry("keep", GeneratedPayload.bytes(seed: 0x12_000, offset: 0, length: 16), policy: .onDemand)
        await bench.source.scriptManifest([.fetched(SyncBench.manifestData([keep]), etag: ETag(rawValue: "\"v2\""))])
        let wait = try await SyncBench.longestWait(on: engine) {
            guard case .complete(let report) = await engine.sync(.force), report.pruned == count else {
                throw SyncBenchError.incomplete("the pruning sync did not complete")
            }
        }
        let buffered = await engine.introspect().bufferedEvents
        // The stream must outlive the measurement (an optimised build may end an unused value's lifetime early, which
        // ends the subscription).
        withExtendedLifetime(subscription) {}
        if buffered < count {
            throw SyncBenchError.incomplete("the stalled subscriber did not hold one slot per pruned id: \(buffered) for \(count)")
        }
        await engine.shutdown()
        return wait
    }

    /// The heartbeat's longest wait while the clock moves past the retry deadlines of a `count`-member prefetch group
    /// whose every first attempt failed with a timeout (each job `failed(.at)`), so they fall due in one alarm turn.
    static func dueRetriesWait(members count: Int) async throws -> Double {
        let bench = try await SyncBench.dispatchBench(members: count)
        let engine = bench.engine
        for entry in bench.entries {
            await bench.source.script(entry.transferID, [.fail(.transient(.timedOut, retryAfter: nil)), .hold])
        }
        guard case .success(let token) = await engine.registerGroup(bench.entries.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        await engine.awaitCondition { engine in
            engine.state.failedJobs.count == count
        }
        guard let latest = await SyncBench.latestRetry(engine) else {
            throw SyncBenchError.incomplete("no member waits for a retry")
        }
        let wait = try await SyncBench.longestWait(on: engine) {
            bench.time.advance(to: latest)
            await engine.awaitCondition { $0.state.failedJobs.isEmpty }
        }
        await engine.releaseGroup(token)
        await engine.shutdown()
        return wait
    }

    /// The latest retry deadline of the engine's failed jobs.
    static func latestRetry(_ engine: isolated SyncEngine) -> MonotonicInstant? {
        engine.state.jobs.values.compactMap { job -> MonotonicInstant? in
            if case .failed(.at(let at)) = job.state {
                return at
            }
            return nil
        }.max()
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    /// The heartbeat's longest wait while the deletion grace of a pruned 2,000-byte blob ends under `handles` prefetch
    /// handles over `count` on-demand members alternating 400 and 3,000 bytes, every one parked `awaitingSpace` with
    /// 100 bytes of room, during the owed follow of a forced sync that changed every member's content (its follow-ups
    /// held): the alarm reaps the blob and its `.reclaimed` sweep and follow-up sweeps re-queue the 400-byte members and
    /// park the 3,000-byte ones, until no sweep is owed. Every member must have left `awaitingSpace`. With `changeEvery`
    /// above 1, only the members whose index it divides change content (VERIFY-C8-C2-MIXED): the follow owes few visits
    /// and the sweep that follows them has every member left to judge.
    static func reclaimDuringFollowWait(members count: Int, handles: Int, changeEvery: Int = 1) async throws -> Double {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let conditions = FakeDeviceConditionsSource()
        let capacity = StoragePolicy().reserveFreeBytes + (32 << 20)
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: capacity, opportunisticCapacity: capacity)
        )
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 0x11),
            conditions: conditions,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        // A 60 s deletion grace and no residency: the pruned blob is reclaimed when the clock passes the grace.
        let configuration = StoreConfiguration(
            location: .applicationSupport,
            policy: StoragePolicy(minimumResidency: 0, deletionGrace: 60),
            legacy: LegacyMigrationPolicy(enabled: false),
            limits: ManifestLimits(),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
        let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: SyncTuning()))
        let xBytes = Data(repeating: 0x78, count: 2_000)
        let x = SyncBench.entry("x", xBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData([x]), etag: ETag(rawValue: "\"v1\""))])
        await source.script(x.transferID, [.stage(xBytes)])
        _ = try await engine.start().get()
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the setup sync did not complete")
        }
        let members = { (seed: UInt64) in
            (0..<count).map { index in
                SyncBench.entry(String(format: "s%05d", index), GeneratedPayload.bytes(seed: seed + UInt64(index), offset: 0, length: index % 2 == 0 ? 400 : 3_000), policy: .onDemand)
            }
        }
        // v2 prunes x: its 2,000 bytes wait for the grace.
        await source.scriptManifest([.fetched(SyncBench.manifestData(members(0x21_000)), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the pruning sync did not complete")
        }
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast")
        guard try await store.freeSpace().pendingReclaim == Int64(xBytes.count) else {
            throw SyncBenchError.incomplete("x's bytes do not wait for the reclaim")
        }
        await engine.refreshFreeSpace()
        let old = members(0x21_000)
        for _ in 0..<handles {
            // A second handle over the same ids (another prefetch window over the same catalog): two interests per job.
            guard case .success = await engine.registerGroup(old.map(\.identifier), lane: .prefetch) else {
                throw SyncBenchError.incomplete("the prefetch group was refused")
            }
        }
        while !Task.isCancelled, !(await SyncBench.allAwaitingSpace(engine, count: count)) {
            await Task.yield()
        }
        let changed = members(0x55_000)
        let v3 = (0..<count).map { $0 % changeEvery == 0 ? changed[$0] : old[$0] }
        await source.scriptManifest([.fetched(SyncBench.manifestData(v3), etag: ETag(rawValue: "\"v3\""))])
        await engine.holdFollowFollowUps()
        let sync = Task { await engine.sync(.force) }
        while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
            await Task.yield()
        }
        // The apply's index commit may have moved the room: 100 bytes again, with a second ballast.
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast-2")
        _ = try await engine.readFreeSpace()
        await SyncBench.raiseOwnedTaskPriority(engine)
        let wait = try await SyncBench.longestWait(on: engine) {
            time.advance(by: 61)
            while !Task.isCancelled, !(await SyncBench.reclaimSwept(engine)) {
                await Task.yield()
            }
        }
        let awaiting = await SyncBench.awaitingSpace(engine)
        await engine.releaseFollowFollowUps()
        await engine.shutdown()
        _ = await sync.value
        guard awaiting == 0 else {
            throw SyncBenchError.incomplete("\(awaiting) members still wait for space after the reclaim's sweeps")
        }
        return wait
    }

    /// Takes the room above the reserve on the opportunistic volume down to `room` with the file `ballast`.
    static func leaveRoom(_ room: Int64, store: AssetStore, fileSystem: FakeFileSystem, ballast: String) async throws {
        let free = try await store.freeSpace()
        let excess = free.volumeOpportunistic - free.reserveBytes - room
        guard excess >= 0 else {
            throw SyncBenchError.incomplete("the room above the reserve is already below \(room): \(free)")
        }
        let file = URL(fileURLWithPath: "/fake-volume/Library/Application Support/\(ballast)")
        try fileSystem.write(Data(repeating: 1, count: Int(excess)), to: file, mode: .truncate)
    }

    /// Whether the engine holds `count` jobs, each parked `awaitingSpace`.
    static func allAwaitingSpace(_ engine: isolated SyncEngine, count: Int) -> Bool {
        engine.state.jobs.count == count && engine.state.jobs.values.allSatisfy { $0.state == .blocked(.awaitingSpace) }
    }

    /// Whether the follow's next turn is held (`holdFollowFollowUps()`).
    static func followWaiting(_ engine: isolated SyncEngine) -> Bool {
        engine.state.followFollowUpWaiting
    }

    /// Whether the alarm's store work is over, its read after the reclaim was adopted and no space sweep is owed: O(1).
    /// The alarm's read and its `.reclaimed` sweep run in one turn, and each sweep owes its follow-up in its own turn.
    static func reclaimSwept(_ engine: isolated SyncEngine) -> Bool {
        engine.state.storeWorkRuns == 0 && engine.state.freeSpace?.pendingReclaim == 0 && engine.state.spaceSweepFollowUp == nil
    }

    /// The jobs parked `awaitingSpace`.
    static func awaitingSpace(_ engine: isolated SyncEngine) -> Int {
        engine.state.spaceParked.filter { engine.state.jobs[$0]?.state == .blocked(.awaitingSpace) }.count
    }
}

/// One release of held follow follow-ups, timed inside the actor turn that runs it (`SyncBench.releaseHeldFollow`).
struct FollowReleaseTurn: CustomStringConvertible {
    /// The turn's duration in milliseconds.
    let milliseconds: Double
    /// The visits the follow still owed when the turn began.
    let owedVisits: Int
    /// Whether the follow still owed a pass over a replaced copy when the turn began.
    let owedPass: Bool
    /// The events that waited for the follow and were applied in the turn.
    let drained: Int
    /// Whether the follow was still owed when the turn ended.
    let followOwedAfter: Bool

    var description: String {
        "\(self.milliseconds) ms, \(self.owedVisits) visits owed, pass owed \(self.owedPass), \(self.drained) drained, owed after \(self.followOwedAfter)"
    }
}

/// One run of `SyncBench.inboundWalk`.
struct InboundWalkRun: CustomStringConvertible {
    /// The heartbeat's longest wait, in milliseconds, from the 404's release to its waiting verdict.
    let wait: Double
    /// The median `followedLane` call afterwards, in milliseconds (`nil` without the member's job).
    let lane: Double?
    /// The jobs when the 404 arrived.
    let jobs: Int
    /// Whether the follow was owed when the 404 arrived.
    let followOwed: Bool
    /// Whether the 404's verdict waited for the follow.
    let verdictWaits: Bool
    /// The ids the 404's job gained in its turn.
    let moved: Int

    var description: String {
        "wait \(self.wait) ms, followedLane \(String(describing: self.lane)) ms, \(self.jobs) jobs, follow owed \(self.followOwed), verdict waits \(self.verdictWaits), \(self.moved) moved"
    }
}

/// One run of `SyncBench.followDrainWait`.
struct FollowDrainRun {
    /// The heartbeat's longest wait, in milliseconds, from the release to the drain's end.
    let wait: Double
    /// The release's own turn.
    let release: FollowReleaseTurn
    /// Milliseconds from the release to the follow's end.
    let followEnded: Double
    /// Milliseconds from the release to the drain's end: no admission is made before it.
    let drainEnded: Double
}

@available(macOS 15.0, iOS 18.0, *)
extension SyncBench {
    /// A held follow's release and the drain after it (F-28; S3-R11 design D3, VERIFY-D3-DRAIN-C2, and amendment (f)):
    /// a prefetch group of `count` on-demand members alternating 400 and 3,000 bytes waits `awaitingSpace` with 100 bytes
    /// of room; a forced sync changes the content of `changed` of them, spread evenly, and its follow's follow-ups are
    /// held after the apply's turn; a second prefetch group of `count` other 400-byte members registers then, and each
    /// member's join waits for the follow (`EventAfterFollow.join`). The release's turn is timed inside the actor,
    /// and the heartbeat's longest wait runs from it until every follow and drain turn has run.
    static func followDrainWait(members count: Int, changed: Int) async throws -> FollowDrainRun {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let conditions = FakeDeviceConditionsSource()
        let capacity = StoragePolicy().reserveFreeBytes + (32 << 20)
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: capacity, opportunisticCapacity: capacity)
        )
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
            time: time,
            random: SeededRandom(seed: 0x11),
            conditions: conditions,
            remoteSources: FakeRemoteSourceFactory(source: source),
            appVersion: FakeAppVersionSource(),
            legacyDefaults: FakeLegacyDefaults()
        )
        // A 60 s deletion grace and no residency, as `reclaimDuringFollowWait`: the pruned blob keeps the members
        // `awaitingSpace`, and the clock never passes the grace here.
        let configuration = StoreConfiguration(
            location: .applicationSupport,
            policy: StoragePolicy(minimumResidency: 0, deletionGrace: 60),
            legacy: LegacyMigrationPolicy(enabled: false),
            limits: ManifestLimits(),
            commitMinimumInterval: 0,
            snapshotInstallInterval: 0
        )
        let store = AssetStore(configuration: configuration, environment: StoreEnvironment(environment: environment, snapshotSink: ScriptedSnapshotSink()))
        let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: SyncTuning()))
        let xBytes = Data(repeating: 0x78, count: 2_000)
        let x = SyncBench.entry("x", xBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData([x]), etag: ETag(rawValue: "\"v1\""))])
        await source.script(x.transferID, [.stage(xBytes)])
        _ = try await engine.start().get()
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the setup sync did not complete")
        }
        let members = { (seed: UInt64) in
            (0..<count).map { index in
                SyncBench.entry(String(format: "s%05d", index), GeneratedPayload.bytes(seed: seed + UInt64(index), offset: 0, length: index % 2 == 0 ? 400 : 3_000), policy: .onDemand)
            }
        }
        let extras = (0..<count).map { index in
            SyncBench.entry(String(format: "t%05d", index), GeneratedPayload.bytes(seed: 0x77_000 + UInt64(index), offset: 0, length: 400), policy: .onDemand)
        }
        let old = members(0x21_000)
        // v2 prunes x: its 2,000 bytes wait for the grace.
        await source.scriptManifest([.fetched(SyncBench.manifestData(old + extras), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the pruning sync did not complete")
        }
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast")
        await engine.refreshFreeSpace()
        guard case .success = await engine.registerGroup(old.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.allAwaitingSpace(engine, count: count)) {
            await Task.yield()
        }
        let renewed = members(0x55_000)
        let stride = count / changed
        let v3 = (0..<count).map { $0 % stride == 0 && $0 / stride < changed ? renewed[$0] : old[$0] }
        await source.scriptManifest([.fetched(SyncBench.manifestData(v3 + extras), etag: ETag(rawValue: "\"v3\""))])
        await engine.holdFollowFollowUps()
        let sync = Task { await engine.sync(.force) }
        while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
            await Task.yield()
        }
        // A second prefetch window registers `count` other members while the follow is owed: each member's join waits.
        guard case .success = await engine.registerGroup(extras.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the second prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.eventsWaiting(engine, atLeast: count)) {
            await Task.yield()
        }
        await SyncBench.raiseOwnedTaskPriority(engine)
        let clock = ContinuousClock()
        var release: FollowReleaseTurn?
        var followEnded = Duration.zero
        var drainEnded = Duration.zero
        let wait = try await SyncBench.longestWait(on: engine) {
            let start = clock.now
            release = await SyncBench.releaseHeldFollow(engine)
            while !Task.isCancelled, await engine.followOwed {
                await Task.yield()
            }
            followEnded = clock.now - start
            while !Task.isCancelled, !(await SyncBench.followDrained(engine)) {
                await Task.yield()
            }
            drainEnded = clock.now - start
        }
        let placesLeft = await SyncBench.barrierLeftovers(engine)
        await engine.shutdown()
        _ = await sync.value
        guard let release else {
            throw SyncBenchError.incomplete("the held follow was not released")
        }
        guard placesLeft == 0 else {
            throw SyncBenchError.incomplete("\(placesLeft) joins and views of the follow barrier are left after its drain")
        }
        return FollowDrainRun(wait: wait, release: release, followEnded: SyncBench.milliseconds(followEnded), drainEnded: SyncBench.milliseconds(drainEnded))
    }

    /// An owed follow over `count` jobs and a 404 whose verdict waits for it (Stage 3 close-out cycle 17,
    /// `inboundWalkTurns`): a prefetch group of `count` on-demand members alternating 400 and 3,000 bytes waits
    /// `awaitingSpace` (a pruned blob's grace, as `followDrainWait`) while O, 16 bytes for a user request, downloads. v3
    /// gives every member a new content; with the follow's follow-ups held after its first turn, O's attempt ends in a
    /// 404. Returns the heartbeat's longest wait from the 404's release to its waiting verdict, the median of 21 timed
    /// `followedLane` calls afterwards on the job of the last member (which the follow's first turn does not visit), the
    /// jobs at the 404, whether the follow was owed then, and the ids O's job gained in the 404's turn.
    static func inboundWalk(members count: Int) async throws -> InboundWalkRun {
        let time = ManualTimeSource()
        let source = FakeRemoteSource()
        let conditions = FakeDeviceConditionsSource()
        let capacity = StoragePolicy().reserveFreeBytes + (32 << 20)
        let fileSystem = FakeFileSystem(
            disk: DiskImage(),
            time: time,
            configuration: FakeFileSystemConfiguration(importantCapacity: capacity, opportunisticCapacity: capacity)
        )
        let environment = AssetEnvironment(
            fileSystem: fileSystem,
            metadataExecutor: InlineBlockingExecutor(),
            bulkExecutor: InlineBlockingExecutor(),
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
        let engine = SyncEngine(store: store, environment: environment, configuration: SyncBench.configuration(tuning: SyncTuning()))
        let xBytes = Data(repeating: 0x78, count: 2_000)
        let x = SyncBench.entry("x", xBytes)
        await source.scriptManifest([.fetched(SyncBench.manifestData([x]), etag: ETag(rawValue: "\"v1\""))])
        await source.script(x.transferID, [.stage(xBytes)])
        _ = try await engine.start().get()
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the setup sync did not complete")
        }
        let oBytes = Data(repeating: 0x6F, count: 16)
        let o = SyncBench.entry("o", oBytes, policy: .onDemand)
        let old = (0..<count).map { index in
            SyncBench.entry(String(format: "s%05d", index), GeneratedPayload.bytes(seed: 0x21_000 + UInt64(index), offset: 0, length: index % 2 == 0 ? 400 : 3_000), policy: .onDemand)
        }
        // v2 prunes x: its 2,000 bytes wait for the grace, so the members wait `awaitingSpace`.
        await source.scriptManifest([.fetched(SyncBench.manifestData(old + [o]), etag: ETag(rawValue: "\"v2\""))])
        guard await engine.sync(.force).isComplete else {
            throw SyncBenchError.incomplete("the pruning sync did not complete")
        }
        try await store.flush(.ordered)
        try await SyncBench.leaveRoom(100, store: store, fileSystem: fileSystem, ballast: "ballast")
        await engine.refreshFreeSpace()
        await source.script(o.transferID, [.hold, .fail(.permanentMissing(httpStatus: 404))])
        let waiter = Task { await engine.awaitAsset(o.identifier, lane: .userInitiated) }
        while !Task.isCancelled, !(await SyncBench.isRunning(engine, o.transferID)) {
            await Task.yield()
        }
        guard case .success = await engine.registerGroup(old.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
        while !Task.isCancelled, !(await SyncBench.othersAwaitingSpace(engine, count: count, besides: o.transferID)) {
            await Task.yield()
        }
        let v3 = (0..<count).map { index in
            SyncBench.entry(String(format: "s%05d", index), GeneratedPayload.bytes(seed: 0x55_000 + UInt64(index), offset: 0, length: index % 2 == 0 ? 400 : 3_000), policy: .onDemand)
        }
        await source.scriptManifest([.fetched(SyncBench.manifestData(v3 + [o]), etag: ETag(rawValue: "\"v3\""))])
        await engine.holdFollowFollowUps()
        let sync = Task { await engine.sync(.force) }
        while !Task.isCancelled, !(await SyncBench.followWaiting(engine)) {
            await Task.yield()
        }
        let before = await SyncBench.inbound(engine, o.transferID)
        await SyncBench.raiseOwnedTaskPriority(engine)
        let wait = try await SyncBench.longestWait(on: engine) {
            await source.release(o.transferID, with: .progress(received: 0, expected: nil))
            while !Task.isCancelled, !(await SyncBench.verdictWaits(engine, o.transferID)) {
                await Task.yield()
            }
        }
        let after = await SyncBench.inbound(engine, o.transferID)
        let lane = await SyncBench.followedLaneMedian(engine, old.last?.transferID, calls: 21)
        await engine.shutdown()
        _ = await sync.value
        _ = await waiter.value
        return InboundWalkRun(wait: wait, lane: lane, jobs: before.jobs, followOwed: before.owed, verdictWaits: after.waits, moved: after.ids - before.ids)
    }

    /// Whether the engine holds `count` jobs besides `transfer`'s, each parked `awaitingSpace`.
    static func othersAwaitingSpace(_ engine: isolated SyncEngine, count: Int, besides transfer: TransferID) -> Bool {
        let others = engine.state.jobs.filter { $0.key != transfer }
        return others.count == count && others.values.allSatisfy { $0.state == .blocked(.awaitingSpace) }
    }

    /// Whether `transfer`'s exit verdict waits for the follow.
    static func verdictWaits(_ engine: isolated SyncEngine, _ transfer: TransferID) -> Bool {
        engine.state.verdictsAfterFollow[transfer] != nil
    }

    /// The jobs, whether the follow is owed, the ids of `transfer`'s job and whether its verdict waits.
    static func inbound(_ engine: isolated SyncEngine, _ transfer: TransferID) -> (jobs: Int, owed: Bool, ids: Int, waits: Bool) {
        (engine.state.jobs.count, engine.followOwed, engine.state.jobs[transfer]?.assets.count ?? 0, engine.state.verdictsAfterFollow[transfer] != nil)
    }

    /// The median of `calls` timed `followedLane` calls on `transfer`'s job, inside the actor, in milliseconds; `nil`
    /// without a job.
    static func followedLaneMedian(_ engine: isolated SyncEngine, _ transfer: TransferID?, calls: Int) -> Double? {
        guard let transfer, let job = engine.state.jobs[transfer] else {
            return nil
        }
        let clock = ContinuousClock()
        var spans: [Double] = []
        for _ in 0..<calls {
            let start = clock.now
            _ = engine.followedLane(job)
            spans.append(SyncBench.milliseconds(clock.now - start))
        }
        return spans.sorted()[calls / 2]
    }

    /// Releases the held follow follow-up and times the turn that runs it, inside that turn: the follow's next turn and,
    /// when it is the last, the drain's first batch (`continueFollow`).
    static func releaseHeldFollow(_ engine: isolated SyncEngine) -> FollowReleaseTurn {
        let clock = ContinuousClock()
        let owedVisits = engine.state.followOrder.count - engine.state.followNext
        let owedPass = !engine.state.followScans.isEmpty
        let waiting = engine.state.eventsAfterFollow.count
        let start = clock.now
        engine.releaseFollowFollowUps()
        let span = clock.now - start
        return FollowReleaseTurn(
            milliseconds: SyncBench.milliseconds(span),
            owedVisits: owedVisits,
            owedPass: owedPass,
            drained: waiting - engine.state.eventsAfterFollow.count,
            followOwedAfter: engine.followOwed
        )
    }

    /// Whether at least `count` events wait for the follow.
    static func eventsWaiting(_ engine: isolated SyncEngine, atLeast count: Int) -> Bool {
        engine.state.eventsAfterFollow.count >= count
    }

    /// The follow ended, every event that waited for it is applied, and no drain or pump follow-up is owed.
    static func followDrained(_ engine: isolated SyncEngine) -> Bool {
        !engine.followOwed && engine.state.eventsAfterFollow.isEmpty && !engine.state.drainFollowUpScheduled && !engine.state.pumpFollowUpScheduled
    }

    /// What the follow barrier still holds: the joins that wait for the drain and the views of its world history
    /// (Stage 3 close-out cycle 12: no place waits for the follow any more, its group's joins do, S3-R14; the history ends
    /// with the barrier, S3-R15).
    static func barrierLeftovers(_ engine: isolated SyncEngine) -> Int {
        engine.state.joinsAfterFollow.count + engine.state.worldHistory.count
    }

    /// `duration` in milliseconds.
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
