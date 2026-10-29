import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetStorage
@testable import ZTronAssetSync
import ZTronAssetTestSupport

extension EngineLaneTests {
    /// With one slot, a bulk job running (held) and two bulk jobs queued behind it (`b`, then `c`), a request for `c` at
    /// `lane` joins and promotes its queued job: it is queued again in the higher lane and starts before `b` when the
    /// slot frees (R-SYN-3, sync-1 S1-06; `relane`). Returns the transfers' start order.
    @available(macOS 15.0, iOS 18.0, *)
    static func promotedQueuedJobStarts(lane: AssetPriority) async throws -> (starts: [TransferID], order: [TransferID]) {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 1))
        let a = EngineFixture.entry("a", EngineFixture.bytes(31))
        let b = EngineFixture.entry("b", EngineFixture.bytes(32))
        let c = EngineFixture.entry("c", EngineFixture.bytes(33))
        await harness.serveManifest([a, b, c])
        await harness.source.script(a.transferID, [.hold, .stage(EngineFixture.bytes(31))])
        await harness.source.script(b.transferID, [.stage(EngineFixture.bytes(32))])
        await harness.source.script(c.transferID, [.stage(EngineFixture.bytes(33))])
        try await harness.start()
        let engine = harness.engine
        let run = Task { await engine.sync(.force) }
        await engine.waitUntil { $0.running == 1 }
        await engine.waitForHandle(a.transferID)
        let waiter = Task { await engine.awaitAsset("c", lane: lane) }
        await engine.waitUntil { $0.waiters == 1 }
        await harness.source.release(a.transferID, with: .progress(received: 0, expected: nil))
        _ = await waiter.value
        _ = await run.value
        let starts = await harness.source.starts.map(\.id)
        await engine.shutdown()
        return (starts, [a.transferID, c.transferID])
    }

    /// Stage 3, mutant M-N-09: a promotion of a queued job from bulk to prefetch re-queued nothing under the mutant.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a queued bulk job a prefetch request joins is promoted and starts before the bulk job queued ahead of it", .timeLimit(.minutes(1)))
    func queuedJobPromotedToPrefetch() async throws {
        let result = try await EngineLaneTests.promotedQueuedJobStarts(lane: .prefetch)
        #expect(Array(result.starts.prefix(2)) == result.order, "c was promoted to prefetch and starts before b: \(result.starts)")
    }

    /// Stage 3, mutant M-N-12: a promotion of a queued job to the user lane re-queued nothing under the mutant.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-3: a queued bulk job a user-initiated request joins is promoted and starts before the bulk job queued ahead of it", .timeLimit(.minutes(1)))
    func queuedJobPromotedToUser() async throws {
        let result = try await EngineLaneTests.promotedQueuedJobStarts(lane: .userInitiated)
        #expect(Array(result.starts.prefix(2)) == result.order, "c was promoted to the user lane and starts before b: \(result.starts)")
    }
}

extension EngineSupportTests {
    /// The backoff's ceiling doubles with every attempt (full jitter under `baseDelay · 2^(attempt−1)`, capped at
    /// `maxDelay`): over 200 keys some draw of each attempt exceeds the previous attempt's ceiling and none exceeds its
    /// own (R-SYN-5; Stage 3, mutant M-N-14: a ceiling one step late passed the upper-bound-only test).
    @Test("R-SYN-5: the backoff ceiling doubles with every attempt, so some key draws above the previous attempt's ceiling")
    func backoffCeilingDoubles() throws {
        let policy = RetryPolicy.background
        var compared = 0
        for attempt in 2...6 {
            let ceiling = min(policy.maxDelay, policy.baseDelay * pow(2, Double(attempt - 1)))
            let previous = min(policy.maxDelay, policy.baseDelay * pow(2, Double(attempt - 2)))
            guard ceiling > previous else {
                continue
            }
            compared += 1
            let draws = try (1...200).map { key in
                try #require(Backoff.delay(attempt: attempt, retryAfter: nil, policy: policy, seed: 0x5EED, key: UInt64(key)))
            }
            let largest = try #require(draws.max())
            #expect(largest > previous, "attempt \(attempt): no draw above the previous ceiling \(previous)")
            #expect(largest <= ceiling, "attempt \(attempt): \(largest) above the ceiling \(ceiling)")
        }
        #expect(compared >= 2, "premise: at least two attempts double below maxDelay: \(compared)")
    }

    /// The 5xx breaker opens when the window's server-error share reaches `serverErrorRatio` exactly: 2 of 5 (0.4) keeps
    /// it closed, a third (3 of 6, exactly 0.5) opens it with the first cooldown (R-SYN-5, ARCHITECTURE §7.7; Stage 3,
    /// mutant M-N-16: `>` for `>=` passed the tests whose windows were all failures).
    @Test("R-SYN-5: a window whose 5xx share equals serverErrorRatio exactly opens the breaker")
    func serverRatioBoundaryOpens() {
        var breaker = CircuitBreaker(policy: CircuitBreakerPolicy())
        let now = EngineSupportTests.origin
        for index in 0..<3 {
            breaker.record(.objectSuccess(EngineSupportTests.transfer(index)), at: now, seed: 3)
        }
        for index in 10..<12 {
            breaker.record(.failure(EngineSupportTests.transfer(index), .serverErrors, distinctAsset: nil), at: now, seed: 3)
        }
        #expect(breaker.state == .closed, "2 of 5 is 0.4, below the 0.5 ratio")
        breaker.record(.failure(EngineSupportTests.transfer(12), .serverErrors, distinctAsset: nil), at: now, seed: 3)
        #expect(breaker.state == .open(cause: .serverErrors, until: now.adding(seconds: 30), trips: 1), "3 of 6 is exactly the 0.5 ratio")
    }

    /// A `Retry-After` equal to `maxRetryAfter` is honoured (the delay is at least it); one second above it defers the
    /// retry to the next run (R-SYN-5; Stage 3, mutant M-N-20: `>=` for `>` passed the test of the value above the limit).
    @Test("R-SYN-5: a Retry-After equal to maxRetryAfter is honoured, one above it defers to the next run")
    func retryAfterBoundary() throws {
        let policy = RetryPolicy.background
        let delay = try #require(Backoff.delay(attempt: 1, retryAfter: policy.maxRetryAfter, policy: policy, seed: 1, key: 1))
        #expect(delay >= policy.maxRetryAfter)
        #expect(Backoff.delay(attempt: 1, retryAfter: policy.maxRetryAfter + 1, policy: policy, seed: 1, key: 1) == nil)
    }
}

extension EngineRecoveryTests {
    /// A later transfer 429 with a shorter `Retry-After` never shortens the origin's throttle (ARCHITECTURE §7.6: a later
    /// 429 only extends it): `p` answers 429 for 60 s, then `q` answers 429 for 10 s; the throttle still ends 60 s after
    /// `p`'s, and moving the clock 10 s restarts neither (R-SYN-5; Stage 3, mutant M-N-39). The two answers are released
    /// in that order from held attempts, so the order does not depend on scheduling.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: a later transfer 429 with a shorter Retry-After never shortens the origin's throttle", .timeLimit(.minutes(1)))
    func shorterTransfer429DoesNotShorten() async throws {
        let harness = EngineHarness.make(tuning: SyncTuning(maxConcurrentTransfers: 2, reservedInteractiveSlots: 0))
        let pBytes = EngineFixture.bytes(1_401)
        let qBytes = EngineFixture.bytes(1_402)
        let p = EngineHarness.onDemand("p", pBytes)
        let q = EngineHarness.onDemand("q", qBytes)
        await harness.serveManifest([p, q])
        try await harness.start()
        let engine = harness.engine
        _ = try #require(await engine.sync(.force).completeReport)
        await harness.source.script(p.transferID, [.hold, .stage(pBytes)])
        await harness.source.script(q.transferID, [.hold, .stage(qBytes)])
        let group = try await engine.registerGroup(["p", "q"], lane: .prefetch).get()
        await engine.waitUntil { $0.running == 2 }
        await engine.waitForAllHandles()
        let throttledAt = harness.time.monotonicNow()
        await harness.source.release(p.transferID, with: .failed(.transient(.throttled, retryAfter: .seconds(60))))
        await engine.awaitCondition { $0.state.jobs[p.transferID]?.state.isThrottleParked == true }
        await harness.source.release(q.transferID, with: .failed(.transient(.throttled, retryAfter: .seconds(10))))
        await engine.waitUntil { ($0.jobsByState[.blocked] ?? 0) == 2 }
        let origin = harness.source.originID
        let end = await engine.readForTests { $0.state.throttles[origin] }
        #expect(end == throttledAt.adding(seconds: 60), "the 10 s 429 left the 60 s throttle in place: \(String(describing: end))")
        try await harness.time.requireSleepers(atLeast: 1)
        #expect(harness.time.nextDeadline == throttledAt.adding(seconds: 60), "the alarm waits for the 60 s end")
        harness.time.advance(by: 10)
        await engine.waitForAllHandles()
        #expect(await harness.source.starts.count == 2, "nothing restarts before the throttle's end")
        await engine.releaseGroup(group)
        await engine.shutdown()
    }
}

extension EngineSupportTests {
    /// One alarm turn takes at most `dueDeadlinesPerTurn` due deadlines, in `(deadline, seq)` order, and never one not
    /// yet due; the rest stay first in the heap for the alarm's next turn (C2; Stage 3, S3-B-077: 10,000 retries falling
    /// due together were re-queued in one turn, and the heap removed them one at a time, quadratic in their number).
    @Test("R-SYN-5: an alarm turn takes at most dueDeadlinesPerTurn due deadlines, in order, and none that is not due")
    func popDueIsBounded() {
        var heap = DeadlineHeap()
        let now = EngineSupportTests.origin
        let count = SyncEngine.dueDeadlinesPerTurn + 88
        for index in 0..<count {
            heap.schedule(.retry(EngineSupportTests.transfer(index), epoch: 1), at: now.adding(seconds: -Double(count - index)))
        }
        heap.schedule(.store, at: now.adding(seconds: 1))
        let first = heap.popDue(at: now, limit: SyncEngine.dueDeadlinesPerTurn)
        #expect(first.count == SyncEngine.dueDeadlinesPerTurn)
        #expect(first.map(\.reason) == (0..<SyncEngine.dueDeadlinesPerTurn).map { .retry(EngineSupportTests.transfer($0), epoch: 1) }, "in deadline order")
        #expect(heap.count == 89 && heap.first?.reason == .retry(EngineSupportTests.transfer(SyncEngine.dueDeadlinesPerTurn), epoch: 1), "the rest stay first")
        let second = heap.popDue(at: now, limit: SyncEngine.dueDeadlinesPerTurn)
        #expect(second.count == 88, "the next turn takes the rest and not the store deadline, which is not due")
        #expect(heap.count == 1 && heap.first?.reason == .store)
        #expect(heap.popDue(at: now).isEmpty)
    }

    /// The engine's alarm turn takes at most `dueDeadlinesPerTurn` due deadlines (C2; Stage 3, S3-B-077), pinned through
    /// the engine, not only `DeadlineHeap.popDue`: the retries of `dueDeadlinesPerTurn` + 88 prefetch members fall due
    /// together (each failed once transiently while the alarm's turns were held, then the clock passes every backoff),
    /// and one released alarm turn re-queues at most `dueDeadlinesPerTurn` of them; the next turns re-queue the rest.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-SYN-5: one alarm turn of the engine re-queues at most dueDeadlinesPerTurn retries that fell due together", .timeLimit(.minutes(1)))
    func alarmTurnRequeuesABoundedSlice() async throws {
        let count = SyncEngine.dueDeadlinesPerTurn + 88
        let harness = EngineHarness.make()
        let members = (0..<count).map { EngineHarness.onDemand(String(format: "due-%04d", $0), EngineFixture.bytes(UInt64(5_000 + $0), count: 16)) }
        try await EngineSingleFlightTests.applied(members, harness: harness)
        let engine = harness.engine
        let transient = TransferError.transient(.unknown(urlErrorCode: -1001), retryAfter: nil)
        for member in members {
            await harness.source.script(member.transferID, [.fail(transient), .hold])
        }
        await engine.holdAlarmTurns()
        let group = try await engine.registerGroup(members.map(\.identifier), lane: .prefetch).get()
        await engine.awaitCondition { $0.state.failedJobs.count == count }
        harness.time.advance(by: 3_600)
        await engine.awaitCondition { $0.alarmTurnHeld }
        // One alarm turn: the held one runs, and the turn it re-arms (due at once) is held again.
        await engine.readForTests { engine in
            engine.releaseAlarmTurns()
            engine.holdAlarmTurns()
        }
        // The turn ends with its successor held, or with no alarm left when it took every deadline.
        await engine.awaitCondition { ($0.alarmTurnHeld || $0.state.alarm == nil) && $0.state.failedJobs.count < count }
        let left = await engine.readForTests { $0.state.failedJobs.count }
        #expect(count - left <= SyncEngine.dueDeadlinesPerTurn, "one turn re-queued \(count - left) retries")
        #expect(left >= count - SyncEngine.dueDeadlinesPerTurn && left > 0, "the rest wait for the next turn: \(left)")
        await engine.releaseAlarmTurns()
        await engine.awaitCondition { $0.state.failedJobs.isEmpty }
        #expect(await engine.invariantViolations().isEmpty)
        await engine.releaseGroup(group)
        await engine.shutdown()
    }
}

