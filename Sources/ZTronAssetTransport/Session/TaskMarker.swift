import Foundation
import ZTronAssetModel

/// Why a foreground data task was stopped, written onto the task itself before `cancel()` (transport.md §4.5).
///
/// The `SessionDelegate` is stateless (only `let`s, so `Sendable` without an escape), so a decision taken in one
/// callback cannot be remembered in the delegate for the completion callback. `URLSessionTask.taskDescription` is
/// the per-task slot that both sides can reach: the task is `Sendable` and the property is atomic (`copy`, not
/// `nonatomic`, NSURLSession.h). Foreground tasks route through their `TaskMailbox`, so the slot is free for this.
///
/// Precedence: the delegate's own verdicts (size, staging, range) overwrite whatever is there, because they explain
/// the bytes; a client `pause` is written only onto an unmarked task, so it never hides a verdict. The remaining
/// race (a verdict written between the pause's check and its write) loses the verdict and reports `paused`; the
/// next attempt meets the same verdict again.
enum TaskMarker: Sendable, Hashable {
    /// `TransferHandle.pause()` or `cancel(_:keepingPartial: true)`: keep the partial, report `paused`.
    case pause
    /// `cancel(_:keepingPartial: false)`: the partial is being discarded, append nothing more.
    case discard
    /// The size guard saw the cap exceeded (R-NET-7).
    case oversize(announced: Int64?)
    /// More than the manifest's `byteSize` was written (transport-1 TR1-8).
    case exceedsExpected(written: Int64)
    /// A staging write failed.
    case staging(StagingError)
    /// A 206 whose `Content-Range` did not start at our partial's size (ARCHITECTURE §6.3).
    case rangeMismatch
    /// An error response's body passed the evidence cap; classify by status.
    case finalStatus
    /// The response was not HTTP.
    case notHTTP

    private static let prefix = "ztak-marker "

    /// The encoded marker, prefixed so a foreign description never decodes.
    var encoded: String {
        Self.prefix + self.body
    }

    private var body: String {
        switch self {
        case .pause:
            return "pause"
        case .discard:
            return "discard"
        case .oversize(let announced):
            return "oversize \(announced.map(String.init) ?? "-")"
        case .exceedsExpected(let written):
            return "exceeds \(written)"
        case .staging(let error):
            switch error {
            case .insufficientSpace:
                return "staging nospace"
            case .io(let code):
                return "staging io \(code)"
            case .tooLarge(let limit):
                return "staging toolarge \(limit)"
            case .nameInUse:
                return "staging nameinuse"
            case .source:
                return "staging source"
            }
        case .rangeMismatch:
            return "range"
        case .finalStatus:
            return "final"
        case .notHTTP:
            return "nothttp"
        }
    }

    /// Decodes a task description; `nil` for an unmarked task or anything that is not a marker. Only `encoded`
    /// writes markers, so the verbs are decoded exactly and their numbers leniently (a number that does not parse
    /// reads as unknown).
    init?(decoding description: String?) {
        guard let description, description.hasPrefix(Self.prefix) else {
            return nil
        }
        let fields = description.dropFirst(Self.prefix.count).split(separator: " ").map(String.init)
        let number = fields.count > 1 ? fields.last.flatMap { Int64($0) } : nil
        switch fields.first {
        case "pause":
            self = .pause
        case "discard":
            self = .discard
        case "oversize":
            self = .oversize(announced: number)
        case "exceeds":
            self = .exceedsExpected(written: number ?? 0)
        case "staging":
            self = .staging(Self.stagingError(fields.dropFirst().first, number))
        case "range":
            self = .rangeMismatch
        case "final":
            self = .finalStatus
        case "nothttp":
            self = .notHTTP
        default:
            return nil
        }
    }

    private static func stagingError(_ kind: String?, _ number: Int64?) -> StagingError {
        switch kind {
        case "nospace":
            return .insufficientSpace
        case "toolarge":
            return .tooLarge(limit: number ?? 0)
        case "nameinuse":
            return .nameInUse
        case "source":
            return .source(.readFailed)
        default:
            return .io(posixCode: Int32(truncatingIfNeeded: number ?? Int64(EIO)))
        }
    }

    /// Writes a delegate verdict onto `task`, replacing any client marker.
    static func record(_ marker: TaskMarker, on task: URLSessionTask) {
        task.taskDescription = marker.encoded
    }

    /// Writes a client marker onto `task` only when it carries none yet.
    static func requestIfUnmarked(_ marker: TaskMarker, on task: URLSessionTask) {
        if TaskMarker(decoding: task.taskDescription) == nil {
            task.taskDescription = marker.encoded
        }
    }
}

extension StagingError {
    /// The `TransferError` a failed staging write becomes (R-NET-6): ENOSPC is `insufficientSpace`, a cap is
    /// `oversize`, anything else a transient local I/O failure (a name clash is a uniqueness bug, `EEXIST`).
    func transferError(requiredBytes: Int64?) -> TransferError {
        switch self {
        case .insufficientSpace:
            return .insufficientSpace(requiredBytes: requiredBytes)
        case .io(let code):
            return .transient(.localIO(posixCode: code), retryAfter: nil)
        case .tooLarge(let limit):
            return .integrity(.oversize(announced: nil, limit: limit))
        case .nameInUse:
            return .transient(.localIO(posixCode: EEXIST), retryAfter: nil)
        case .source:
            return .transient(.localIO(posixCode: EIO), retryAfter: nil)
        }
    }
}
