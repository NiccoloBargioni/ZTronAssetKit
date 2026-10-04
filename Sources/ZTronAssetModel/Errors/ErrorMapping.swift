import Foundation

extension RetryAfter {
    /// Seconds from `now` until the server's hint, never negative; a delta is taken as is. The engine clamps the
    /// value to `RetryPolicy.maxRetryAfter` (H-8): this conversion only reads the clock value it is given.
    public func seconds(from now: Date) -> TimeInterval {
        switch self {
        case .seconds(let delta):
            return TimeInterval(delta)
        case .date(let date):
            return max(0, date.timeIntervalSince(now))
        }
    }
}

extension TransferError {
    /// The metrics class (R-OBS-2) and engine action row of ARCHITECTURE §7.6; `nil` for cancellations, which are
    /// not failures.
    public var failureClass: FailureClass? {
        switch self {
        case .offline:
            return .offline
        case .transient(let cause, _):
            switch cause {
            case .serverError:
                return .serverError
            case .throttled:
                return .throttled
            default:
                return .transient
            }
        case .permanentMissing:
            return .notFound
        case .authentication:
            return .authentication
        case .integrity:
            return .integrity
        case .insufficientSpace:
            return .insufficientSpace
        case .rejected:
            return .rejected
        case .cancelled:
            return nil
        }
    }

    /// The UI-mappable error a waiter receives (R-CAR-7, ARCHITECTURE §7.6), given the wall clock for
    /// `Retry-After` dates.
    ///
    /// Two cases are completed by the engine, which knows more than the transport: an `insufficientSpace` carries
    /// the store's measured free space (here `available` is 0), and an ambiguous 403 becomes
    /// `.authRejected(.confirmed)` only when the auth breaker opened on key-rejected evidence (ARCHITECTURE §7.7).
    public func assetError(now: Date) -> AssetError {
        switch self {
        case .offline:
            return .offline
        case .transient(_, let retryAfter):
            return .serverUnavailable(retryAfter: retryAfter?.seconds(from: now))
        case .permanentMissing:
            return .notFound
        case .authentication:
            return .authRejected(.ambiguous)
        case .integrity:
            return .integrityFailure
        case .insufficientSpace(let required):
            return .insufficientSpace(required: required ?? 0, available: 0)
        case .rejected:
            return .serverUnavailable(retryAfter: nil)
        case .cancelled:
            return .cancelled
        }
    }
}
