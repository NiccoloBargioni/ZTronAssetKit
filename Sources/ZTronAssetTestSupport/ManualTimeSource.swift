import Foundation
import Synchronization
import ZTronAssetModel

/// The test clock (H-8, Q-4): time moves only when a test calls `advance`; nothing ever sleeps for real.
///
/// `TimeSource` has synchronous clock reads, so the state needs a lock: `Synchronization.Mutex`, hence the
/// availability gate (ADR-014). Tests that use it carry `@available(macOS 15.0, *)` **on each `@Test` function,
/// never on a `@Suite`** (Swift Testing rejects the latter). Zero unsafe escapes.
///
/// Semantics: `sleep(until:)` registers a sleeper; `advance` resumes every sleeper whose deadline passed, in
/// `(deadline, registration sequence)` order, recorded in `wakeLog`; cancellation removes a sleeper under the same
/// lock, so each sleeper resumes exactly once. `pendingSleepers` and `nextDeadline` are the positive witnesses idle
/// and "nothing before t" tests need (sync-2 S2-27); `waitForSleepers(atLeast:)` lets a test order registrations
/// without sleeping (store-2 S2-08). `sleepDevice(for:)` advances wall and monotonic time but not the awake clock
/// (ADR-017).
@available(macOS 15.0, iOS 18.0, *)
public final class ManualTimeSource: TimeSource {
    private typealias Wake = CheckedContinuation<Result<Void, CancellationError>, Never>

    private enum Phase {
        case allocated
        case registered(deadline: MonotonicInstant, continuation: Wake)
        case cancelled
    }

    private struct SleeperWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var wall: Date
        var monotonic: MonotonicInstant
        var uptime: MonotonicInstant
        var nextSequence: UInt64 = 0
        var phases: [UInt64: Phase] = [:]
        var wakeLog: [UInt64] = []
        var sleeperWaiters: [SleeperWaiter] = []

        var pendingCount: Int {
            self.phases.values.reduce(0) { count, phase in
                if case .registered = phase {
                    return count + 1
                }
                return count
            }
        }
    }

    private let state: Mutex<State>

    /// Starts at a fixed wall time and monotonic instant (both arbitrary, never `Date()`).
    public init(
        wall: Date = Date(timeIntervalSince1970: 1_700_000_000),
        monotonic: MonotonicInstant = MonotonicInstant(nanoseconds: 1_000_000_000)
    ) {
        self.state = Mutex(State(wall: wall, monotonic: monotonic, uptime: monotonic))
    }

    /// The wall clock.
    public func now() -> Date {
        self.state.withLock { $0.wall }
    }

    /// The monotonic clock.
    public func monotonicNow() -> MonotonicInstant {
        self.state.withLock { $0.monotonic }
    }

    /// The awake clock.
    public func uptimeNow() -> MonotonicInstant {
        self.state.withLock { $0.uptime }
    }

    /// Suspends until `advance` passes `deadline`; returns at once for a past deadline; throws on cancellation.
    public func sleep(until deadline: MonotonicInstant) async throws(CancellationError) {
        let sequence = self.state.withLock { state -> UInt64 in
            state.nextSequence += 1
            state.phases[state.nextSequence] = .allocated
            return state.nextSequence
        }
        let outcome: Result<Void, CancellationError> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: Wake) in
                let immediate = self.state.withLock { state -> Result<Void, CancellationError>? in
                    switch state.phases[sequence] {
                    case .cancelled:
                        state.phases[sequence] = nil
                        return .failure(CancellationError())
                    case .allocated:
                        if deadline <= state.monotonic {
                            state.phases[sequence] = nil
                            return .success(())
                        }
                        state.phases[sequence] = .registered(deadline: deadline, continuation: continuation)
                        return nil
                    case .registered, nil:
                        return .success(())
                    }
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                } else {
                    self.notifySleeperWaiters()
                }
            }
        } onCancel: {
            let continuation = self.state.withLock { state -> Wake? in
                switch state.phases[sequence] {
                case .allocated:
                    state.phases[sequence] = .cancelled
                    return nil
                case .registered(_, let continuation):
                    state.phases[sequence] = nil
                    return continuation
                case .cancelled, nil:
                    return nil
                }
            }
            continuation?.resume(returning: .failure(CancellationError()))
        }
        try outcome.get()
    }

    /// Moves wall, monotonic and awake time forward and wakes every due sleeper in order.
    public func advance(by seconds: TimeInterval) {
        let due = self.state.withLock { state -> [Wake] in
            state.wall = state.wall.addingTimeInterval(seconds)
            state.monotonic = state.monotonic.adding(seconds: seconds)
            state.uptime = state.uptime.adding(seconds: seconds)
            return ManualTimeSource.collectDue(&state)
        }
        for continuation in due {
            continuation.resume(returning: .success(()))
        }
    }

    /// Moves monotonic time to `deadline` (if later), wall and awake time by the same amount, and wakes sleepers.
    public func advance(to deadline: MonotonicInstant) {
        let seconds = self.state.withLock { state in
            deadline.seconds(since: state.monotonic)
        }
        self.advance(by: seconds)
    }

    /// The device sleeps: wall and monotonic time advance, the awake clock does not (ADR-017).
    public func sleepDevice(for seconds: TimeInterval) {
        let due = self.state.withLock { state -> [Wake] in
            state.wall = state.wall.addingTimeInterval(seconds)
            state.monotonic = state.monotonic.adding(seconds: seconds)
            return ManualTimeSource.collectDue(&state)
        }
        for continuation in due {
            continuation.resume(returning: .success(()))
        }
    }

    /// A wall-clock jump (the user changed the date); monotonic and awake time are unchanged.
    public func setWallClock(_ date: Date) {
        self.state.withLock { $0.wall = date }
    }

    /// Registered sleepers.
    public var pendingSleepers: Int {
        self.state.withLock { $0.pendingCount }
    }

    /// The earliest registered deadline.
    public var nextDeadline: MonotonicInstant? {
        self.state.withLock { state in
            state.phases.values.compactMap { phase -> MonotonicInstant? in
                if case .registered(let deadline, _) = phase {
                    return deadline
                }
                return nil
            }.min()
        }
    }

    /// Registration sequences (1-based) in wake order.
    public var wakeLog: [UInt64] {
        self.state.withLock { $0.wakeLog }
    }

    /// Suspends until at least `count` sleepers are registered (event-driven, never polled).
    public func waitForSleepers(atLeast count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = self.state.withLock { state -> Bool in
                if state.pendingCount >= count {
                    return true
                }
                state.sleeperWaiters.append(SleeperWaiter(count: count, continuation: continuation))
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    private func notifySleeperWaiters() {
        let ready = self.state.withLock { state -> [CheckedContinuation<Void, Never>] in
            let pending = state.pendingCount
            var ready: [CheckedContinuation<Void, Never>] = []
            state.sleeperWaiters.removeAll { waiter in
                if waiter.count <= pending {
                    ready.append(waiter.continuation)
                    return true
                }
                return false
            }
            return ready
        }
        for continuation in ready {
            continuation.resume()
        }
    }

    private static func collectDue(_ state: inout State) -> [Wake] {
        var due: [(deadline: MonotonicInstant, sequence: UInt64, continuation: Wake)] = []
        for (sequence, phase) in state.phases {
            if case .registered(let deadline, let continuation) = phase, deadline <= state.monotonic {
                due.append((deadline, sequence, continuation))
            }
        }
        due.sort { ($0.deadline, $0.sequence) < ($1.deadline, $1.sequence) }
        for item in due {
            state.phases[item.sequence] = nil
            state.wakeLog.append(item.sequence)
        }
        return due.map(\.continuation)
    }
}
