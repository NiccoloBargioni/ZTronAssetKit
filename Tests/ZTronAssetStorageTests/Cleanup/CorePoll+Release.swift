import Testing
import ZTronAssetTestSupport

/// The one poll that lets a `SteppedBlockingExecutor`'s held store units through until a condition holds (Stage 3 ruling
/// S3C-1; S3-STAB-01, S3-STAB-02, S3-B-034). WP-C's file: an extension of WP-B's `CorePoll` (`Core/CoreHarness.swift`).
@available(macOS 15.0, iOS 18.0, *)
extension CorePoll {
    /// Which held units a round of `releasing(_:_:until:_:)` lets through.
    enum Release: Sendable {
        /// The oldest held unit only: a flow that runs one unit at a time advances by one unit per round.
        case oldest
        /// Every held unit except the given ones: the units a test holds on purpose stay held.
        case allExcept(Set<Int>)
    }

    /// Lets `executor`'s held units through until `condition` holds, then returns, releasing nothing more; a test past
    /// its time limit ends here (`CorePoll.until`).
    ///
    /// Each round reads the held units **first**, then evaluates `condition`, and releases only units it read before a
    /// condition that was false. The order is the point (S3-STAB-01): the condition is a separate read (the fake
    /// volume's log, or a hop to the store), so a poll that read the held units after it could see a unit the product
    /// submitted after the condition had become true, and let through the very unit the test means to hold.
    ///
    /// What the poll relies on, as every store flow it drives does: `condition`, once true, stays true while the poll
    /// runs, and the product makes the change `condition` reads before it submits the next unit. Then a unit held at
    /// the first read was submitted before that read; the condition was still false then, since it is false at the later
    /// read; so every unit released was submitted before the condition held. A caller that also needs the unit submitted
    /// after the change waits for it once this returns (`requireHeldUnits(atLeast:)`): this poll never releases it.
    /// Returns the units it released, in order.
    @discardableResult
    static func releasing(
        _ executor: SteppedBlockingExecutor,
        _ release: Release = .oldest,
        until waitingFor: @autoclosure () -> String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () async throws -> Bool
    ) async throws -> [Int] {
        var released: [Int] = []
        try await CorePoll.until(waitingFor(), sourceLocation: sourceLocation) {
            let held = await executor.heldUnits
            if try await condition() {
                return true
            }
            switch release {
            case .oldest:
                if let unit = held.first {
                    await executor.release(unit)
                    released.append(unit)
                }
            case .allExcept(let kept):
                for unit in held where !kept.contains(unit) {
                    await executor.release(unit)
                    released.append(unit)
                }
            }
            return false
        }
        return released
    }
}
