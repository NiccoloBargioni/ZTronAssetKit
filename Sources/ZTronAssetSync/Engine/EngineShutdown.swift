import Foundation
import ZTronAssetModel

/// What one shutdown drain took out of the engine's state (`SyncEngine.drainEverything(with:)`): the continuations whose
/// number grows with the callers and the tables whose size grows with the catalog. `SyncEngine.settle(_:)` answers and
/// frees them over turns of at most `SyncEngine.shutdownStepsPerTurn` steps, so no turn of a shutdown holds the actor for
/// all of them (C2): at SPEC §6's 10,000, answering every waiter and group and freeing the job table in one turn held it
/// 17 to 22 ms (Stage 3, S3-PERF-01), also while the app runs, when a vanished root retires the engine.
struct ShutdownDrain {
    /// The `resolve` waiters' continuations (known ids, then unknown ids), each in token order.
    var waiters: [CheckedContinuation<Result<AssetLocation, AssetError>, Never>] = []
    /// The groups' join continuations, in token order.
    var groupJoins: [CheckedContinuation<Bool, Never>] = []
    /// The groups themselves: a 10,000-member group holds several 10,000-element tables.
    var groups: [InterestToken: Group] = [:]
    /// The job table, freed a slice per turn.
    var jobs: [TransferID: Job] = [:]
    /// The other tables sized by the catalog, freed together once the jobs are.
    var indexes = RetiredIndexes()
}

/// The engine's indexes and pending claims a shutdown drops, kept whole until the last turn of `settle(_:)` frees them.
struct RetiredIndexes {
    /// `EngineState.claims`.
    var claims: [ClaimKey: Int] = [:]
    /// `EngineState.claimHeld`.
    var claimHeld: [ClaimKey: TransferID] = [:]
    /// `EngineState.releasing`.
    var releasing: [InterestToken: Release] = [:]
    /// The parked, failed and owed indexes and the in-flight set (`EngineState`).
    var transfers: [Set<TransferID>] = []
    /// `EngineState.heap`.
    var heap = DeadlineHeap()
}

extension SyncEngine {
    /// The continuations a shutdown turn resumes, or the jobs it frees, at most (C2): a resumption or a job's release
    /// costs about 1 µs in release, so a turn of 512 stays well under a millisecond (`readmissionsPerTurn`'s figure).
    static let shutdownStepsPerTurn = 512

    /// Takes every continuation table and every catalog-sized table out of the state (S1-02), answering the small tables
    /// (start, sync, run, entry, manifest and conditions joiners) and releasing the test seams' holds at once; the waiters,
    /// the groups and the job table go into the drain `settle(_:)` answers and frees in bounded turns. Safe to call
    /// repeatedly: a later call drains what registered meanwhile. The running attempts' handles were cancelled before
    /// (`cancelRunningHandles()`).
    func drainEverything(with error: AssetError) -> ShutdownDrain {
        var drain = ShutdownDrain()
        let waiters = self.state.waiters
        self.state.waiters = [:]
        drain.waiters.reserveCapacity(waiters.count + self.state.unknownWaiters.count)
        for token in waiters.keys.sorted() {
            if let waiter = waiters[token] {
                drain.waiters.append(waiter.continuation)
            }
        }
        let unknown = self.state.unknownWaiters
        self.state.unknownWaiters = [:]
        for token in unknown.keys.sorted() {
            if let waiter = unknown[token] {
                drain.waiters.append(waiter.continuation)
            }
        }
        drain.groups = self.state.groups
        self.state.groups = [:]
        for token in drain.groups.keys.sorted() {
            if let continuation = drain.groups[token]?.continuation {
                drain.groupJoins.append(continuation)
            }
        }
        // Every pending claim ends with the engine (L5-R1), those a release or a join's give-up left for later turns
        // included (L5-R15).
        drain.indexes.claims = self.state.claims
        self.state.claims = [:]
        drain.indexes.claimHeld = self.state.claimHeld
        self.state.claimHeld = [:]
        self.state.unlistedClaims = 0
        drain.indexes.releasing = self.state.releasing
        self.state.releasing = [:]
        self.resumeJoiners(with: error)
        self.releaseApplyFollow()
        self.releaseStoreDeadlineRead()
        self.releaseManifestOutcomeDelivery()
        self.releaseRunSettlementDelivery()
        self.releaseAlarmTurns()
        self.releaseApplyQueue()
        drain.jobs = self.state.jobs
        self.state.jobs = [:]
        drain.indexes.transfers = [
            self.state.inFlight, self.state.spaceParked, self.state.laneParked, self.state.circuitParked,
            self.state.throttleParked, self.state.failedJobs, self.state.edgeOwed, self.state.originOwed,
        ]
        self.state.inFlight = []
        self.state.spaceParked = []
        self.state.laneParked = []
        self.state.circuitParked = []
        self.state.throttleParked = []
        self.state.failedJobs = []
        self.state.edgeOwed = []
        self.state.originOwed = []
        self.state.spaceSweepFollowUp = nil
        self.state.spaceAdmitted.removeAll()
        self.state.readmissionsOwed = []
        self.state.laneParksOwed.removeAll()
        self.state.inFlightBytes = InFlightBytes()
        self.state.draining.removeAll()
        self.state.run = nil
        self.state.pendingRun = nil
        drain.indexes.heap = self.state.heap
        self.state.heap = DeadlineHeap()
        self.state.alarm = nil
        self.state.watcher = nil
        self.state.pressure.task = nil
        self.state.pressure.handler = nil
        self.state.heals.removeAll()
        self.notifyObservers()
        return drain
    }

    /// Cancels the running attempts' handles: only a downloading job has one (`transition` clears it on every other
    /// state), and every downloading job is in flight, so the handles are those of `inFlight`, not of the whole job
    /// table (C2; Stage 3, S3-PERF-01).
    func cancelRunningHandles() {
        for transfer in self.state.inFlight.sorted() {
            self.state.jobs[transfer]?.active?.handle?.cancel()
        }
    }

    /// Answers the drain's waiters and groups with the shutdown and frees its tables, at most `shutdownStepsPerTurn`
    /// steps per turn: each slice ends in a yield, so a caller waiting for the actor (a heartbeat, a cancelled waiter's
    /// withdrawal) gets in between. Nothing new is added meanwhile: the lifecycle is `shuttingDown`, so every
    /// registration answers at once, and the drained values belong to this call. The drain is consumed and each table
    /// is swapped out of it, so this call holds the only reference and a removal frees one entry instead of copying
    /// the table.
    func settle(_ drain: consuming ShutdownDrain, with error: AssetError) async {
        var steps = 0
        var waiters: [CheckedContinuation<Result<AssetLocation, AssetError>, Never>] = []
        swap(&waiters, &drain.waiters)
        for continuation in waiters {
            continuation.resume(returning: .failure(error))
            steps += 1
            if steps == SyncEngine.shutdownStepsPerTurn {
                steps = 0
                // REENTRANCY: RE-S43 (proposed) — nothing: the drained continuations belong to this call, and while
                // the lifecycle is `shuttingDown` no new one is registered.
                await Task.yield()
            }
        }
        var joins: [CheckedContinuation<Bool, Never>] = []
        swap(&joins, &drain.groupJoins)
        for continuation in joins {
            continuation.resume(returning: false)
        }
        drain.groups = [:]
        var jobs: [TransferID: Job] = [:]
        swap(&jobs, &drain.jobs)
        for transfer in Array(jobs.keys) {
            jobs.removeValue(forKey: transfer)
            steps += 1
            if steps == SyncEngine.shutdownStepsPerTurn {
                steps = 0
                // REENTRANCY: RE-S43 (proposed) — as above: the retired job table belongs to this call.
                await Task.yield()
            }
        }
        drain.indexes = RetiredIndexes()
        self.notifyObservers()
    }

    /// Resumes the joiners' continuation tables whose size grows with concurrent callers, not with the catalog: `start`,
    /// `sync`, the run task, entry tasks, the manifest fetch's waiters and the conditions waiters.
    private func resumeJoiners(with error: AssetError) {
        let starts = self.state.startJoiners
        self.state.startJoiners.removeAll()
        for token in starts.keys.sorted() {
            starts[token]?.resume(returning: .failure(error))
        }
        let syncs = self.state.syncJoiners
        self.state.syncJoiners.removeAll()
        for token in syncs.keys.sorted() {
            syncs[token]?.resume(returning: .failed(error))
        }
        let runs = self.state.runCompletions
        self.state.runCompletions.removeAll()
        for token in runs.keys.sorted() {
            runs[token]?.resume(returning: .shutDown)
        }
        let entries = self.state.entryJoins
        self.state.entryJoins.removeAll()
        self.state.entryTasks.removeAll()
        for token in entries.keys.sorted() {
            entries[token]?.resume(returning: .done(.failure(error)))
        }
        if var fetch = self.state.manifestFetch {
            let waiting = fetch.waiters
            fetch.waiters.removeAll()
            self.state.manifestFetch = fetch
            for token in waiting.keys.sorted() {
                waiting[token]?.resume(returning: .shutDown)
            }
        }
        let conditionWaiters = self.state.conditionWaiters
        self.state.conditionWaiters.removeAll()
        for token in conditionWaiters.keys.sorted() {
            conditionWaiters[token]?.resume()
        }
    }
}
