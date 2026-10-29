import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport

/// The test clock's ordering and its three clocks (H-8, ADR-017): time moves only on `advance`, sleepers wake in
/// `(deadline, registration)` order, and a device sleep stops only the awake clock.
@Suite("Test support: ManualTimeSource")
struct TestSupportManualTimeSourceTests {
    /// Registers one sleeper per deadline, in order, waiting for each registration (so sequence numbers are fixed).
    /// Throws when the test is cancelled before a sleeper registered (its time limit), so the test ends there instead
    /// of awaiting sleepers that never registered and that nothing would ever wake (L2 follow-up).
    @available(macOS 15.0, iOS 18.0, *)
    private static func sleepers(
        _ time: ManualTimeSource,
        _ offsets: [TimeInterval]
    ) async throws(CancellationError) -> [Task<Bool, Never>] {
        let start = time.monotonicNow()
        var tasks: [Task<Bool, Never>] = []
        for (index, offset) in offsets.enumerated() {
            tasks.append(Self.sleeper(time, until: start.adding(seconds: offset)))
            try await time.requireSleepers(atLeast: index + 1)
        }
        return tasks
    }

    /// One sleeper in a task of its own: `true` when woken, `false` when cancelled.
    @available(macOS 15.0, iOS 18.0, *)
    private static func sleeper(_ time: ManualTimeSource, until deadline: MonotonicInstant) -> Task<Bool, Never> {
        Task {
            do {
                try await time.sleep(until: deadline)
                return true
            } catch {
                return false
            }
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-ENV-1: one advance wakes exactly the due sleepers in deadline then registration order and keeps the rest", .timeLimit(.minutes(1)))
    func advanceWakesDueSleepersInOrder() async throws {
        let time = ManualTimeSource()
        let start = time.monotonicNow()
        let tasks = try await Self.sleepers(time, [5, 2, 1, 2, 9])
        time.advance(by: 2)
        for index in [1, 2, 3] {
            #expect(await tasks[index].value)
        }
        #expect(time.wakeLog == [3, 2, 4])
        #expect(time.pendingSleepers == 2)
        #expect(time.nextDeadline == start.adding(seconds: 5))
        time.advance(to: start.adding(seconds: 9))
        #expect(await tasks[0].value)
        #expect(await tasks[4].value)
        #expect(time.wakeLog == [3, 2, 4, 1, 5])
        #expect(time.monotonicNow() == start.adding(seconds: 9))
    }

    /// Stage 3 (S3AH-3, L4-R24(2)): `advance(to:)` moved by `seconds(since:)` through a `Double`, and landed 1 ns short
    /// of the target for about 3 % of gaps, so a sleeper registered at exactly that deadline stayed asleep. It now moves
    /// in nanoseconds: monotonic time lands on the target, awake time moves by the same nanoseconds, and a sleeper at
    /// the target wakes, for every seeded gap up to 2^60 ns.
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-ENV-1: advance(to:) lands exactly on the target instant, moves the awake clock by the same nanoseconds and wakes a sleeper there", .timeLimit(.minutes(1)))
    func advanceToLandsExactly() async throws {
        var random = SplitMix64(seed: 0x5EED_0000_0104)
        var gaps: [UInt64] = [1, 999_999_999, 1_000_000_001, 1 << 60]
        for _ in 0..<2_000 {
            gaps.append(UInt64.random(in: 1..<(1 << UInt64.random(in: 1...60, using: &random)), using: &random))
        }
        for (index, gap) in gaps.enumerated() {
            try Task.checkCancellation()
            let time = ManualTimeSource()
            let start = time.monotonicNow()
            let uptime = time.uptimeNow()
            let wall = time.now()
            let target = MonotonicInstant(nanoseconds: start.nanoseconds + gap)
            // The first gaps also park a sleeper at exactly the target (its deadline is the instant itself).
            let sleeper = index < 64 ? Self.sleeper(time, until: target) : nil
            if sleeper != nil {
                try await time.requireSleepers(atLeast: 1)
            }
            time.advance(to: target)
            #expect(time.monotonicNow() == target, "gap \(gap) ns")
            #expect(time.uptimeNow().nanoseconds == uptime.nanoseconds + gap, "gap \(gap) ns")
            #expect(time.now() == wall.addingTimeInterval(target.seconds(since: start)), "gap \(gap) ns")
            if let sleeper {
                // A sleeper left asleep is cancelled, so a miss fails here instead of hanging until the time limit.
                let asleep = time.pendingSleepers
                #expect(asleep == 0, "gap \(gap) ns: the sleeper at the target is still asleep")
                if asleep > 0 {
                    sleeper.cancel()
                }
                #expect(await sleeper.value, "gap \(gap) ns: the sleeper at the target did not wake")
            }
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-ENV-1: advancing to an earlier instant moves no clock and wakes nobody", .timeLimit(.minutes(1)))
    func advanceToThePastIsANoOp() async throws {
        let time = ManualTimeSource()
        let start = time.monotonicNow()
        let wall = time.now()
        let tasks = try await Self.sleepers(time, [1])
        time.advance(to: .zero)
        #expect(time.monotonicNow() == start)
        #expect(time.now() == wall)
        #expect(time.pendingSleepers == 1)
        tasks[0].cancel()
        #expect(await tasks[0].value == false)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-ENV-1: a device sleep advances wall and monotonic time, wakes due sleepers, and keeps the awake clock still", .timeLimit(.minutes(1)))
    func deviceSleepStopsTheAwakeClock() async throws {
        let time = ManualTimeSource()
        let wall = time.now()
        let monotonic = time.monotonicNow()
        let uptime = time.uptimeNow()
        let tasks = try await Self.sleepers(time, [30])
        time.sleepDevice(for: 60)
        #expect(await tasks[0].value)
        #expect(time.now() == wall.addingTimeInterval(60))
        #expect(time.monotonicNow() == monotonic.adding(seconds: 60))
        #expect(time.uptimeNow() == uptime)
        time.advance(by: 1)
        #expect(time.uptimeNow() == uptime.adding(seconds: 1))
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-ENV-1: a wall-clock jump moves neither the monotonic nor the awake clock")
    func wallClockJump() {
        let time = ManualTimeSource()
        let monotonic = time.monotonicNow()
        let uptime = time.uptimeNow()
        let past = Date(timeIntervalSince1970: 1_000)
        time.setWallClock(past)
        #expect(time.now() == past)
        #expect(time.monotonicNow() == monotonic)
        #expect(time.uptimeNow() == uptime)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-ENV-1: a sleep whose deadline already passed returns at once and never registers", .timeLimit(.minutes(1)))
    func pastDeadlineReturnsAtOnce() async throws {
        let time = ManualTimeSource()
        try await time.sleep(until: time.monotonicNow())
        #expect(time.pendingSleepers == 0)
        #expect(time.wakeLog.isEmpty)
        #expect(time.nextDeadline == nil)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-ENV-1: a sleeper cancelled before it could register throws and leaves nothing registered", .timeLimit(.minutes(1)))
    func cancelledBeforeRegistration() async {
        let time = ManualTimeSource()
        let deadline = time.monotonicNow().adding(seconds: 60)
        let gate = AsyncStream<Void>.makeStream()
        let sleeper = Task { () -> Bool in
            for await _ in gate.stream {}
            do {
                try await time.sleep(until: deadline)
                return false
            } catch {
                return true
            }
        }
        sleeper.cancel()
        gate.continuation.finish()
        #expect(await sleeper.value)
        #expect(time.pendingSleepers == 0)
        #expect(time.nextDeadline == nil)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-ENV-1: waitForSleepers returns once enough sleepers are registered, at once when they already are", .timeLimit(.minutes(1)))
    func waitForSleepersIsEventDriven() async throws {
        // The `Void` form under test registers the sleepers here (the helper uses the throwing form); a wait that the
        // test's time limit ended early leaves fewer registered, and the `#require` ends the test there.
        let time = ManualTimeSource()
        let deadline = time.monotonicNow().adding(seconds: 1)
        var tasks: [Task<Bool, Never>] = []
        for index in 0..<2 {
            tasks.append(Self.sleeper(time, until: deadline))
            await time.waitForSleepers(atLeast: index + 1)
        }
        try #require(time.pendingSleepers == 2)
        await time.waitForSleepers(atLeast: 1)
        #expect(time.pendingSleepers == 2)
        time.advance(by: 1)
        for task in tasks {
            #expect(await task.value)
        }
        #expect(time.wakeLog == [1, 2])
    }
}
