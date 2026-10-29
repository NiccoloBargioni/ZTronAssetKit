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
        /// breaker parks every queued member, every member then answers 404, and the clock reaches the cooldown's end. Each
        /// member probes in turn, and each exit re-admits every member the breaker still parks while the pump parks all but
        /// the next probe again (F-40), so the chain's total actor work grows with the square of the parked members while
        /// each turn stays within C2. 1,000 members (10,000 would take minutes: the verifier measured 160.88 s); the best of
        /// three runs' longest actor wait against C2, the median against P-9, after a warm-up of 250. The totals are
        /// reported for the orchestrator's ruling on the burst (F-41), not checked against a budget: none exists.
        @Test("R-SYN-5: a chain of half-open probes ending without a verdict over 1,000 prefetch members parked by the breaker holds the engine's actor at most C2's 10 ms per turn, and reports the chain's total time", .timeLimit(.minutes(3)))
        @available(macOS 15.0, iOS 18.0, *)
        func probeChainTurns() async throws {
            let budgets = try QualityBudgets()
            let gapMax = try #require(budgets.value("P-9", "heartbeat_gap_ms_p99_max"))
            _ = try await SyncBench.probeChainWait(members: 250)
            var runs: [(wait: Double, total: Double)] = []
            for _ in 0..<3 {
                runs.append(try await SyncBench.probeChainWait(members: 1_000))
            }
            let waits = runs.map(\.wait)
            let median = waits.sorted()[1]
            print("R-SYN-5 chain of probes without a verdict over 1,000 prefetch members parked by the breaker: longest actor wait \(median) ms (budgets \(gapMax) ms median, \(Self.c2Budget) ms best); totals \(runs.map(\.total)) s; runs \(waits)")
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
    /// breaker that parked a prefetch group of `count` on-demand members on a roomy volume, every member answering 404 from
    /// then on: the running members answer 500 until the 5xx breaker opens, as in `cooldownEndWait`, then every member is
    /// scripted to answer 404, and the clock jumps to the cooldown's end, until no member is parked, queued, downloading or
    /// owed a re-queue (each probed once and failed, or waits for a retry deadline the clock has not reached).
    @available(macOS 15.0, iOS 18.0, *)
    static func probeChainWait(members count: Int) async throws -> (wait: Double, total: Double) {
        let bench = try await SyncBench.scaleBench(members: count, room: nil)
        let engine = bench.engine
        guard case .success = await engine.registerGroup(bench.entries.map(\.identifier), lane: .prefetch) else {
            throw SyncBenchError.incomplete("the prefetch group was refused")
        }
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
        while !Task.isCancelled, !(await SyncBench.originSettled(engine, probing: false)) {
            await Task.yield()
        }
        guard let until = await SyncBench.cooldownEnd(engine) else {
            throw SyncBenchError.incomplete("the breaker closed before its cooldown ended")
        }
        for entry in bench.entries {
            await bench.source.script(entry.transferID, [.fail(.permanentMissing(httpStatus: 404))])
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
            while !Task.isCancelled, !(await SyncBench.chainEnded(engine)) {
                await Task.yield()
            }
            total = clock.now - start
        }
        await engine.shutdown()
        return (wait, Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18)
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
