import Foundation
import ZTronAssetModel

/// Phase checks, counted units and the waiter tables (store-1 S1-09, store-2 S2-07; WP-B).
///
/// Every executor unit and every snapshot install goes through `runUnit` / `installCounted`, which count it in
/// `unitsInFlight`, so `close()` can drain them before its durable flush. Waiters (open, commit, key, drain) are
/// continuations held in actor state: the store owns no task (ADR-022), and `close()` resumes every one of them,
/// so nothing suspended on the store outlives it.
extension AssetStore {
    // MARK: Phase

    /// Throws unless the store is opening or open: `.closed` once `close()` began, `.notOpen` before `open()`.
    /// Every resumption after an await calls it (ARCHITECTURE §10: "store: `open`, else drop the mutation").
    func checkLive() throws(StoreError) {
        switch self.state.core.phase {
        case .open, .opening:
            return
        case .closing, .closed:
            throw .closed
        case .created:
            throw .notOpen
        }
    }

    /// Throws when the root was replaced or vanished while running (store-1 S1-08): nothing is written any more.
    func checkWritable() throws(StoreError) {
        if let reason = self.state.core.unavailable {
            throw .storageUnavailable(reason)
        }
    }

    /// Async APIs await a running `open()` (REENTRANCY R1); before `open()` they fail with `.notOpen`, after
    /// `close()` began with `.closed`.
    func awaitOpen() async throws(StoreError) {
        while true {
            switch self.state.core.phase {
            case .open:
                return
            case .created:
                throw .notOpen
            case .closing, .closed:
                throw .closed
            case .opening:
                // REENTRANCY: R1 — the loop re-reads the phase: open, failed back to created, or closing.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.state.core.openWaiters.append(continuation)
                }
            }
        }
    }

    // MARK: Counted units

    /// Runs one bounded unit on `executor` (ADR-003) and counts it for `close()`'s drain. The caller re-validates
    /// after the await, under its own REENTRANCY row.
    func runUnit<T: Sendable>(on executor: any BlockingExecutor, _ work: @escaping @Sendable () -> T) async -> T {
        self.state.core.unitsInFlight += 1
        // REENTRANCY: R1/R2/R4/R5/R7/R10/R13/R14 (the caller's row) — nothing here: the drain counter is decremented
        // on resumption, and every caller re-checks the phase and the state its row names.
        let value = await executor.run(work)
        self.unitFinished()
        return value
    }

    /// Installs `snapshot` through the sink, counted like a unit.
    func installCounted(_ snapshot: AssetSnapshot) async -> InstallAck {
        self.state.core.unitsInFlight += 1
        // REENTRANCY: R6 — nothing here; `installSnapshot` validates the acknowledgement's epoch and merges it.
        let ack = await self.environment.snapshotSink.install(snapshot)
        self.unitFinished()
        return ack
    }

    private func unitFinished() {
        self.state.core.unitsInFlight -= 1
        if self.state.core.unitsInFlight == 0 {
            let waiters = self.state.core.drainWaiters
            self.state.core.drainWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    // MARK: Waiters

    /// Resumes every caller waiting for `open()`.
    func resumeOpenWaiters() {
        let waiters = self.state.core.openWaiters
        self.state.core.openWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Resumes every caller waiting for the running commit.
    func resumeCommitWaiters() {
        let waiters = self.state.core.commits.waiters
        self.state.core.commits.waiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Resumes every caller waiting for the `apply`/`admit` gate; each re-checks the gate and the phase.
    func resumeApplyWaiters() {
        let waiters = self.state.core.applyGate.waiters
        self.state.core.applyGate.waiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Suspends until the in-flight publication or deletion of `key` finishes (REENTRANCY R3).
    func waitForKey(_ key: BlobKey) async {
        // REENTRANCY: R3 — nothing here: the caller re-reads `blobTable[key]` and `publishing` and decides anew.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.state.core.keyWaiters[key, default: []].append(continuation)
        }
    }

    /// Resumes the publishers waiting for `key`.
    func resumeKeyWaiters(_ key: BlobKey) {
        guard let waiters = self.state.core.keyWaiters.removeValue(forKey: key) else {
            return
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    // MARK: Close

    /// `close()`: no new mutation, drain in-flight units, durable flush, unlock, resume every waiter.
    func performClose() async {
        while true {
            switch self.state.core.phase {
            case .closing, .closed:
                return
            case .created:
                self.state.core.phase = .closed
                self.resumeOpenWaiters()
                return
            case .opening:
                // REENTRANCY: R1 — the loop re-reads the phase once `open()` finished or failed.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.state.core.openWaiters.append(continuation)
                }
            case .open:
                // REENTRANCY: R1, R5 — `closeOpenStore` re-reads the drain counter; closing is terminal.
                await self.closeOpenStore()
                return
            }
        }
    }

    private func closeOpenStore() async {
        self.state.core.phase = .closing
        // Publishers parked on a key re-check the phase and unwind with `.closed`.
        for key in Array(self.state.core.keyWaiters.keys) {
            self.resumeKeyWaiters(key)
        }
        while self.state.core.unitsInFlight > 0 {
            // REENTRANCY: b-1 (proposed) — the loop re-reads the counter; units resuming meanwhile see `closing` and
            // drop their mutation.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.state.core.drainWaiters.append(continuation)
            }
        }
        if self.state.core.unavailable == nil, !self.state.core.commits.covers(self.state.core.commits.mutationSerial, .durable) {
            // REENTRANCY: R5 — closing is terminal: nothing but this flush runs any more, and its failure leaves the
            // last committed generation in place.
            try? await self.commitNow(.durable)
        }
        if let lock = self.state.core.lock {
            let fileSystem = self.environment.fileSystem
            // REENTRANCY: b-1 (proposed) — nothing: closing is terminal and the lock field is cleared below.
            await self.runUnit(on: self.environment.metadataExecutor) {
                fileSystem.releaseLock(lock)
            }
            self.state.core.lock = nil
        }
        self.state.core.phase = .closed
        self.resumeCommitWaiters()
        self.resumeOpenWaiters()
        self.resumeApplyWaiters()
        for key in Array(self.state.core.keyWaiters.keys) {
            self.resumeKeyWaiters(key)
        }
    }
}
