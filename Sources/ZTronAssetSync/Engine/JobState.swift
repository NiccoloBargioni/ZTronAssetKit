import ZTronAssetModel

/// The in-flight half of the per-asset state machine (R-SYN-2, ARCHITECTURE §7.1). `absent` and `present` are
/// derived from the store; only outstanding work has a job, so engine memory scales with work, not catalog size.
package enum JobState: Sendable, Hashable {
    /// Waiting in a lane.
    case queued
    /// A transfer is running.
    case downloading
    /// The store is hashing the staged file.
    case verifying
    /// The store is publishing and committing.
    case committing
    /// Failed; runs again per the disposition.
    case failed(RetryDisposition)
    /// Parked until the reason clears.
    case blocked(BlockReason)

    /// The state without its payload.
    package var kind: JobStateKind {
        switch self {
        case .queued:
            return .queued
        case .downloading:
            return .downloading
        case .verifying:
            return .verifying
        case .committing:
            return .committing
        case .failed:
            return .failed
        case .blocked:
            return .blocked
        }
    }

    /// Whether moving to `next` is a legal transition (the only mutator, `transition(_:to:)`, consults it).
    package func allows(_ next: JobState) -> Bool {
        JobStateKind.allows(from: self.kind, to: next.kind)
    }
}

/// `JobState` without payloads: the transition table's alphabet.
package enum JobStateKind: String, Sendable, Hashable, CaseIterable {
    /// `queued`.
    case queued
    /// `downloading`.
    case downloading
    /// `verifying`.
    case verifying
    /// `committing`.
    case committing
    /// `failed(retryAt)`.
    case failed
    /// `blocked(reason)`.
    case blocked

    /// The legal transitions (sync.md §5.2 as amended by the reviews; leaving the table — job removal to `absent`
    /// or `present` — is not a transition and is always allowed):
    /// - `queued → downloading | blocked`
    /// - `downloading → verifying | failed | blocked | queued` (paused or preempted; a policy pause whose lane is
    ///   admitted again; an offline failure after a satisfied-path edge passed during the attempt; the immediate
    ///   re-queues of ARCHITECTURE §7.6; superseded)
    /// - `verifying → committing | failed | queued` (superseded content)
    /// - `committing → failed | queued` (stale entry, store failure)
    /// - `failed → queued | failed` (re-armed with a new disposition)
    /// - `blocked → queued | blocked` (the reason changed)
    package static func allows(from: JobStateKind, to: JobStateKind) -> Bool {
        switch (from, to) {
        case (.queued, .downloading), (.queued, .blocked):
            return true
        case (.downloading, .verifying), (.downloading, .failed), (.downloading, .blocked), (.downloading, .queued):
            return true
        case (.verifying, .committing), (.verifying, .failed), (.verifying, .queued):
            return true
        case (.committing, .failed), (.committing, .queued):
            return true
        case (.failed, .queued), (.failed, .failed):
            return true
        case (.blocked, .queued), (.blocked, .blocked):
            return true
        default:
            return false
        }
    }
}
