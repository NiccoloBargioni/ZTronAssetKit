import Dispatch

/// Runs bounded blocking units off the cooperative pool (ADR-003, C2).
///
/// A unit is one rename, one ≤ 1 MiB read plus a hash update, one index commit, 64 unlinks or one directory
/// listing: each well under ~10 ms. Long operations are decomposed into units with `Task.checkCancellation()`
/// between them, so cancellation needs no shared flag. A unit, once submitted, always runs to completion: the
/// actor applies its result (store design §6.9).
///
/// The requirement takes a **non-throwing** closure on purpose: a typed-throws closure must never become runtime
/// metadata at the iOS 15 floor (APPLE-API-VERIFICATION §0 Q3), so typed errors travel as `Result` values, and
/// `run(throwing:)` restores them.
public protocol BlockingExecutor: Sendable {
    /// Runs `work` to completion on the executor and returns its value.
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T
}

extension BlockingExecutor {
    /// Runs a typed-throwing unit and rethrows its error with its type intact.
    public func run<T: Sendable, E: Error>(throwing work: @escaping @Sendable () throws(E) -> T) async throws(E) -> T {
        let result: Result<T, E> = await self.run { () -> Result<T, E> in
            do throws(E) {
                return .success(try work())
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }
}

/// The live executor: one dedicated serial `DispatchQueue` (`autoreleaseFrequency: .workItem`, so a 256 MiB hash
/// never accumulates autoreleased buffers, store.md §10) bridged with a checked continuation.
///
/// The store uses two: *metadata* (commits, renames, unlinks, listings) and *bulk* (hash and copy reads), so a
/// long hash never delays a commit.
public struct DispatchBlockingExecutor: BlockingExecutor {
    private let queue: DispatchQueue

    /// Creates an executor with its own serial queue.
    public init(label: String, qos: DispatchQoS = .utility) {
        self.queue = DispatchQueue(label: label, qos: qos, autoreleaseFrequency: .workItem)
    }

    /// Submits `work` to the queue and suspends until it returns.
    public func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            self.queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
