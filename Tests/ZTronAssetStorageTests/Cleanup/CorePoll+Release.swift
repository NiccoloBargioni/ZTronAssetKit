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

    /// Lets `executor`'s held units through until `condition` holds, then returns, releasing nothing more.
    ///
    /// Each round evaluates `condition` and, while it is false, releases the held units `release` names.
    static func releasing(
        _ executor: SteppedBlockingExecutor,
        _ release: Release = .oldest,
        until waitingFor: @autoclosure () -> String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () async throws -> Bool
    ) async throws {
        try await CorePoll.until(waitingFor(), sourceLocation: sourceLocation) {
            if try await condition() {
                return true
            }
            let held = await executor.heldUnits
            switch release {
            case .oldest:
                if let unit = held.first {
                    await executor.release(unit)
                }
            case .allExcept(let kept):
                for unit in held where !kept.contains(unit) {
                    await executor.release(unit)
                }
            }
            return false
        }
    }
}
