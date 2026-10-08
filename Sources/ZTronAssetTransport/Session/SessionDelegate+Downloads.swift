import Foundation
import ZTronAssetModel

/// The `.background` callbacks (R-NET-3, H-6): download tasks route through their `taskDescription` tag
/// (`BackgroundTaskTag`) and the session stream, because a background task carries no mailbox (S-2) and must be
/// recognisable after a relaunch. The OS's temporary file is moved into `staging/<name>` before the callback
/// returns (R-STO-1); nothing else of the task is kept.
extension SessionDelegate: URLSessionDownloadDelegate {
    /// Moves a finished download into staging and reports it on `sessionEvents` (`.background` only; a foreground
    /// session runs data tasks, which never call this).
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard self.mode == .background, let tag = BackgroundTaskTag(decoding: downloadTask.taskDescription) else {
            return
        }
        let http = downloadTask.response as? HTTPURLResponse
        self.finishDownload(
            tag: tag,
            response: http.map { self.facts(of: $0, task: downloadTask) },
            originalURL: downloadTask.originalRequest?.url,
            finalURL: http?.url ?? downloadTask.currentRequest?.url,
            location: location
        )
    }

    /// Every event the OS queued for this launch was delivered (`.backgroundEventsFinished`): the coordinator
    /// completes UIKit's handler only after the events before it were staged (transport.md §10.6).
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        self.sessionEventSink.yield(.backgroundEventsFinished)
    }

    /// Reports a finished background download on `sessionEvents`: `didFinishDownloadingTo` with the facts read off
    /// the task, callable with explicit facts so tests and the fake driver drive it without a real download task
    /// (ARCHITECTURE §14). Must run before the OS deletes `location`, i.e. inside the delegate callback.
    package func finishDownload(
        tag: BackgroundTaskTag,
        response: ResponseFacts?,
        originalURL: URL?,
        finalURL: URL?,
        location: URL
    ) {
        let update = self.downloadOutcome(tag: tag, response: response, originalURL: originalURL, finalURL: finalURL, location: location)
        self.sessionEventSink.yield(.finished(name: tag.name, update: update))
    }

    /// The terminal update of a finished background download.
    ///
    /// The OS follows redirects in a background session without asking (NSURLSession.h), so the hop rules are
    /// checked after the fact: bytes that arrived from another origin are refused and never adopted (ADR-026). The
    /// staged size is compared with `byteSize` (R-NET-7). A 206 with a `Content-Range` is the OS continuing resume
    /// data the coordinator handed it (checksummed content only, TR1-3; we never send a `Range` in the background):
    /// the OS's file holds the whole body, staged as resumed (and hashed at publication).
    private func downloadOutcome(
        tag: BackgroundTaskTag,
        response: ResponseFacts?,
        originalURL: URL?,
        finalURL: URL?,
        location: URL
    ) -> TransferUpdate {
        guard let response else {
            return .failed(.transient(.badServerResponse, retryAfter: nil))
        }
        guard let original = originalURL.flatMap(Origin.init(url:)), let final = finalURL.flatMap(Origin.init(url:)),
            original == final
        else {
            return .failed(.rejected(.redirectRefused(.unenforceableInBackground)))
        }
        let continued = response.status == 206 && response.contentRangeStart != nil
        guard response.status == 200 || continued else {
            let failure = TransferClassifier.classify(response, purpose: .asset, sentConditional: false, resumed: false, keyWithheld: false)
            return .failed(failure ?? .transient(.badServerResponse, retryAfter: nil))
        }
        let size: Int64
        do {
            size = try self.staging.adoptDownload(at: location, as: tag.name)
        } catch {
            return .failed(error.transferError(requiredBytes: tag.expectedBytes))
        }
        if let expected = tag.expectedBytes, size != expected {
            if size > expected {
                return .failed(.integrity(.sizeMismatch(expected: expected, actual: size)))
            }
            return .failed(.integrity(.truncated(expected: expected, received: size)))
        }
        if tag.expectedBytes == nil && size == 0 {
            return .failed(.integrity(.truncated(expected: nil, received: 0)))
        }
        return .staged(StagedFile(name: tag.name, byteCount: size, resumed: continued, httpStatus: response.status, etag: response.etag))
    }

    /// A background task ended with an error: report it under its tag (a success was reported when its file was
    /// moved). A cancellation is reported as such; the coordinator, which recorded any pause intent, turns its own
    /// pause into `paused` (transport-2 T2-05).
    func backgroundCompletion(task: URLSessionTask, error: (any Error)?) {
        guard let error, let tag = BackgroundTaskTag(decoding: task.taskDescription) else {
            return
        }
        let facts = HTTPResponseReading.errorFacts(error)
        let failure = TransferClassifier.classify(
            urlErrorCode: facts.code,
            networkUnavailableReason: facts.unavailable,
            backgroundCancelReason: facts.cancelReason,
            resumed: false,
            underlyingPOSIXCode: facts.posix
        )
        self.sessionEventSink.yield(.finished(name: tag.name, update: .failed(failure)))
    }
}
