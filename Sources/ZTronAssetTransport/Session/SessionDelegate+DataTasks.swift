import Foundation
import ZTronAssetModel

/// The foreground callbacks (ADR-019): data tasks whose chunks are appended into `staging/<name>.part` on the
/// delegate queue, a size guard on every chunk, and the classification of the final state into exactly one
/// terminal update, yielded to the task's `TaskMailbox`.
///
/// Every per-task fact comes from the task itself (its mailbox's job, response, requests, byte counts and the
/// `TaskMarker` in `taskDescription`) or from staging, never from delegate state: the delegate holds only `let`s.
extension SessionDelegate {
    /// Error bodies are counted, never staged; past this many bytes the evidence is complete (an empty or XML 403
    /// is all a hint needs) and the task is stopped.
    static let errorBodyEvidenceCap: Int64 = 64 * 1_024

    /// Decides what to do with a response before any body byte arrives: success statuses open (or continue) the
    /// partial and pass the announced size through the size guard; other statuses are let through so their body
    /// length can serve as 403 evidence. A task the client already discarded is stopped without touching staging.
    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let mailbox = dataTask.delegate as? TaskMailbox else {
            completionHandler(.cancel)
            return
        }
        guard TaskMarker(decoding: dataTask.taskDescription) != .discard else {
            // The client discarded this transfer and its cancel is on its way: open, move or truncate nothing.
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            TaskMarker.record(.notHTTP, on: dataTask)
            completionHandler(.cancel)
            return
        }
        completionHandler(self.open(http, for: mailbox.job, task: dataTask) ? .allow : .cancel)
    }

    /// Appends one chunk of a success response into staging, checks the size guard, and reports progress at
    /// quantum boundaries only (stateless rate limit, transport.md §4.4).
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let mailbox = dataTask.delegate as? TaskMailbox, let http = dataTask.response as? HTTPURLResponse else {
            return
        }
        self.receive(data, task: dataTask, mailbox: mailbox, response: http)
    }

    /// One chunk of `dataTask`'s body under `http`: the data callback passes the task's response; tests pass one,
    /// since an unresumed task has none (ARCHITECTURE §14).
    package func receive(_ data: Data, task dataTask: URLSessionDataTask, mailbox: TaskMailbox, response http: HTTPURLResponse) {
        let job = mailbox.job
        guard Self.isStagedStatus(http.statusCode, job: job) else {
            if dataTask.countOfBytesReceived > Self.errorBodyEvidenceCap {
                TaskMarker.record(.finalStatus, on: dataTask)
                dataTask.cancel()
            }
            return
        }
        if let marker = TaskMarker(decoding: dataTask.taskDescription), marker != .pause {
            // A verdict or a discard is already on its way to the completion callback: write nothing more.
            return
        }
        let written: Int64
        do {
            written = try self.staging.appendPartial(data, to: job.partialName)
        } catch {
            TaskMarker.record(.staging(error), on: dataTask)
            dataTask.cancel()
            return
        }
        let announced = HTTPResponseReading.announcedTotal(of: http, offset: job.resume?.offset ?? 0)
        switch SizeGuard.verdict(written: written, announced: announced, expected: job.expectedBytes, limit: job.maxBytes) {
        case .proceed:
            break
        case .abortOversize:
            TaskMarker.record(.oversize(announced: announced), on: dataTask)
            dataTask.cancel()
            return
        case .abortExceedsExpected:
            TaskMarker.record(.exceedsExpected(written: written), on: dataTask)
            dataTask.cancel()
            return
        }
        let expected = job.expectedBytes ?? announced
        if ProgressQuantum.crossesBoundary(before: written - Int64(data.count), after: written, expected: expected) {
            mailbox.continuation.yield(.progress(received: written, expected: expected))
        }
    }

    /// Follows a redirect only as `RedirectPolicy` allows, stripping the key on any hop off the original origin
    /// (R-NET-4). A refusal delivers the 3xx as the final response.
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let hop = RedirectHop.count(of: task.currentRequest) + 1
        let decision = self.redirectDecision(task: task, previousURL: response.url, proposedURL: request.url, hop: hop)
        switch decision {
        case .follow(let keepKey):
            completionHandler(RedirectHop.prepare(request, hop: hop, keepKey: keepKey, policy: self.policy))
        case .refuse:
            completionHandler(nil)
        }
    }

    /// Ends the task's stream with exactly one terminal update (foreground), or reports a background task's
    /// failure on the session stream (`.background`, where a success was already reported when the file was moved).
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        switch self.mode {
        case .foreground:
            guard let mailbox = task.delegate as? TaskMailbox else {
                return
            }
            let update = self.foregroundOutcome(task: task, job: mailbox.job, response: task.response as? HTTPURLResponse, error: error)
            mailbox.continuation.yield(update)
            mailbox.continuation.finish()
        case .background:
            self.backgroundCompletion(task: task, error: error)
        }
    }

    /// The session is gone: the last callback, which `ForegroundTransferBackend.invalidate()` waits for
    /// (transport-2 T2-04).
    public func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        self.sessionEventSink.yield(.invalidated)
        self.sessionEventSink.finish()
    }

    // MARK: - Decisions

    /// Whether a response with `status` is written into staging for `job`: a 200, or a 206 to a resumed request.
    static func isStagedStatus(_ status: Int, job: TransferJob) -> Bool {
        status == 200 || (status == 206 && job.resume != nil)
    }

    /// Opens the partial for a success response and applies the size guard to the announced length; `false` when
    /// the task must stop (the reason is marked on the task).
    private func open(_ http: HTTPURLResponse, for job: TransferJob, task: URLSessionTask) -> Bool {
        guard Self.isStagedStatus(http.statusCode, job: job) else {
            return true
        }
        // The guard runs before anything is opened, so an announced oversize leaves no partial behind.
        let start = http.statusCode == 206 ? job.resume?.offset ?? 0 : 0
        let announced = HTTPResponseReading.announcedTotal(of: http, offset: start)
        switch SizeGuard.verdict(written: start, announced: announced, expected: job.expectedBytes, limit: job.maxBytes) {
        case .proceed:
            break
        case .abortOversize:
            TaskMarker.record(.oversize(announced: announced), on: task)
            return false
        case .abortExceedsExpected:
            TaskMarker.record(.exceedsExpected(written: start), on: task)
            return false
        }
        do {
            try self.openPartial(http, for: job)
        } catch {
            TaskMarker.record(error.marker, on: task)
            return false
        }
        return true
    }

    private struct OpenFailure: Error {
        let marker: TaskMarker
    }

    /// Opens the partial: a 206 continues the earlier attempt's partial (exclusive rename) only when its
    /// `Content-Range` starts exactly at that partial's size, and a vanished earlier partial cannot be continued
    /// either (both `resumeRejected`); a 200 starts from zero, also when it answers a resumed request (the validator
    /// changed, so the origin sent the whole body).
    private func openPartial(_ http: HTTPURLResponse, for job: TransferJob) throws(OpenFailure) {
        guard http.statusCode == 206, let resume = job.resume else {
            if let resume = job.resume {
                // Take over the stale partial's name so nothing is left behind, then truncate it.
                _ = try? self.staging.continuePartial(from: resume.previous, as: job.partialName)
            }
            do {
                try self.staging.createPartial(job.partialName)
            } catch {
                throw OpenFailure(marker: .staging(error))
            }
            return
        }
        let start = HTTPResponseReading.contentRangeStart(http.value(forHTTPHeaderField: "Content-Range"))
        guard start == resume.offset else {
            throw OpenFailure(marker: .rangeMismatch)
        }
        let size: Int64
        do {
            size = try self.staging.continuePartial(from: resume.previous, as: job.partialName)
        } catch {
            throw OpenFailure(marker: error == .io(posixCode: ENOENT) ? .rangeMismatch : .staging(error))
        }
        guard size == resume.offset else {
            throw OpenFailure(marker: .rangeMismatch)
        }
    }

    /// The redirect decision for one proposed hop of `task`.
    func redirectDecision(task: URLSessionTask, previousURL: URL?, proposedURL: URL?, hop: Int) -> RedirectPolicy.Decision {
        guard let originalURL = task.originalRequest?.url, let original = Origin(url: originalURL),
            let previous = (previousURL ?? task.currentRequest?.url).flatMap(Origin.init(url:))
        else {
            return .refuse(.invalidLocation)
        }
        return RedirectPolicy.decide(
            original: original,
            previous: previous,
            proposed: proposedURL.flatMap(Origin.init(url:)),
            hop: hop,
            keyStillPresent: HTTPResponseReading.carriesKey(task.currentRequest, policy: self.policy),
            policy: self.policy
        )
    }

    /// The one terminal update of a foreground task whose response is `http`: the completion callback reads it off
    /// the task; tests pass one, since an unresumed task has none (ARCHITECTURE §14). The task's marker is honoured
    /// whatever ended the task: a client `discard` is always the client's cancellation (nothing is kept, no sidecar),
    /// and a delegate verdict stands even when the completion was already queued when its cancel was issued.
    package func foregroundOutcome(task: URLSessionTask, job: TransferJob, response http: HTTPURLResponse?, error: (any Error)?) -> TransferUpdate {
        let marker = TaskMarker(decoding: task.taskDescription)
        if marker == .discard {
            return .failed(.cancelled(.byClient))
        }
        if let error {
            return self.failureOutcome(task: task, job: job, http: http, error: error, marker: marker)
        }
        guard let http else {
            return .failed(.transient(.badServerResponse, retryAfter: nil))
        }
        return self.completedOutcome(task: task, job: job, http: http, marker: marker)
    }

    private func completedOutcome(task: URLSessionTask, job: TransferJob, http: HTTPURLResponse, marker: TaskMarker?) -> TransferUpdate {
        let facts = self.facts(of: http, task: task)
        if Self.isStagedStatus(http.statusCode, job: job) {
            if let marker, let verdict = Self.verdict(of: marker, job: job) {
                return verdict
            }
            // `open` already checked a 206's `Content-Range` against the partial, so the status needs no classifier.
            return self.stagedOutcome(job: job, http: http, facts: facts)
        }
        if (300...399).contains(http.statusCode), http.statusCode != 304 {
            let location = http.value(forHTTPHeaderField: "Location")
            let base = http.url ?? task.currentRequest?.url
            let proposed = location.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
            let hop = RedirectHop.count(of: task.currentRequest) + 1
            if case .refuse(let reason) = self.redirectDecision(task: task, previousURL: http.url, proposedURL: proposed, hop: hop) {
                return .failed(.rejected(.redirectRefused(reason)))
            }
        }
        let keyWithheld = HTTPResponseReading.carriesKey(task.originalRequest, policy: self.policy) && !facts.keyPresented
        let sentConditional = task.originalRequest?.value(forHTTPHeaderField: "If-None-Match") != nil
        if let failure = TransferClassifier.classify(
            facts, purpose: job.purpose, sentConditional: sentConditional, resumed: job.resume != nil, keyWithheld: keyWithheld)
        {
            return .failed(failure)
        }
        // A conditional 304: nothing was staged; the manifest fetch reads `httpStatus` (R-NET-5).
        return .staged(StagedFile(name: job.partialName, byteCount: 0, resumed: false, httpStatus: http.statusCode, etag: facts.etag ?? job.ifNoneMatch))
    }

    /// Compares the staged size with `byteSize` (never `Content-Length`, R-NET-7) and the cap.
    private func stagedOutcome(job: TransferJob, http: HTTPURLResponse, facts: ResponseFacts) -> TransferUpdate {
        let staged: Int64
        do {
            // Appending nothing returns the partial's size: the delegate keeps no byte count of its own.
            staged = try self.staging.appendPartial(Data(), to: job.partialName)
        } catch {
            return .failed(error.transferError(requiredBytes: job.expectedBytes))
        }
        // The size guard stops every chunk past the cap or `byteSize`, but a completion already queued when its
        // cancel was issued arrives here too: the whole staged size is checked again.
        if staged > job.maxBytes {
            return .failed(.integrity(.oversize(announced: nil, limit: job.maxBytes)))
        }
        if let expected = job.expectedBytes {
            if staged != expected {
                let failure: TransferIntegrityFailure = staged < expected
                    ? .truncated(expected: expected, received: staged)
                    : .sizeMismatch(expected: expected, actual: staged)
                return .failed(.integrity(failure))
            }
        } else if staged == 0 && job.purpose == .asset {
            return .failed(.integrity(.truncated(expected: nil, received: 0)))
        }
        let resumed = http.statusCode == 206
        return .staged(StagedFile(name: job.partialName, byteCount: staged, resumed: resumed, httpStatus: http.statusCode, etag: facts.etag))
    }

    /// The outcome of a task that ended with `error`. A delegate verdict stands whatever the error: the guard's
    /// `cancel()` can follow a completion with another error (a lost connection, a timeout) that was already queued
    /// behind the chunk it judged, and that error must neither hide the verdict nor keep the judged bytes for resume.
    /// Only a client pause depends on the error being the cancellation it asked for.
    private func failureOutcome(task: URLSessionTask, job: TransferJob, http: HTTPURLResponse?, error: any Error, marker: TaskMarker?) -> TransferUpdate {
        switch marker {
        case .finalStatus?:
            // Set only after a response arrived.
            let completed = http.map { self.completedOutcome(task: task, job: job, http: $0, marker: .finalStatus) }
            return completed ?? .failed(.transient(.badServerResponse, retryAfter: nil))
        case let marker?:
            if let verdict = Self.verdict(of: marker, job: job) {
                return verdict
            }
        case nil:
            break
        }
        let errorFacts = HTTPResponseReading.errorFacts(error)
        if errorFacts.code == NSURLErrorCancelled, marker == .pause {
            return .paused(resumable: self.keepForResume(job: job, http: http))
        }
        let failure = TransferClassifier.classify(
            urlErrorCode: errorFacts.code,
            networkUnavailableReason: errorFacts.unavailable,
            backgroundCancelReason: errorFacts.cancelReason,
            resumed: job.resume != nil,
            underlyingPOSIXCode: errorFacts.posix
        )
        switch failure {
        case .transient(.connectionLost, let retryAfter):
            return .failed(.transient(.connectionLost(resumable: self.keepForResume(job: job, http: http)), retryAfter: retryAfter))
        case .transient(.timedOut, _):
            _ = self.keepForResume(job: job, http: http)
            return .failed(failure)
        default:
            return .failed(failure)
        }
    }

    /// The failure a delegate verdict on the task stands for; `nil` for the client's markers and for `finalStatus`,
    /// which is classified by the response's status.
    static func verdict(of marker: TaskMarker, job: TransferJob) -> TransferUpdate? {
        switch marker {
        case .oversize(let announced):
            return .failed(.integrity(.oversize(announced: announced, limit: job.maxBytes)))
        case .exceedsExpected(let written):
            return .failed(.integrity(.sizeMismatch(expected: job.expectedBytes ?? written, actual: written)))
        case .staging(let failure):
            return .failed(failure.transferError(requiredBytes: job.expectedBytes))
        case .rangeMismatch:
            return .failed(.transient(.resumeRejected, retryAfter: nil))
        case .notHTTP:
            return .failed(.transient(.badServerResponse, retryAfter: nil))
        case .pause, .discard, .finalStatus:
            return nil
        }
    }

    /// Writes the sidecar a later attempt continues from (R-NET-8) and says whether one was written: only for
    /// checksummed content (a checksum-less transfer is never resumed, transport-1 TR1-3), only after a success
    /// response that carried a validator, and only when the partial holds bytes.
    private func keepForResume(job: TransferJob, http: HTTPURLResponse?) -> Bool {
        guard job.id.kind == .content, let http, Self.isStagedStatus(http.statusCode, job: job),
            let validator = HTTPResponseReading.resumeValidator(of: http),
            let size = try? self.staging.appendPartial(Data(), to: job.partialName), size > 0
        else {
            return false
        }
        let expected = job.expectedBytes ?? HTTPResponseReading.announcedTotal(of: http, offset: job.resume?.offset ?? 0)
        self.staging.writeSidecar(ResumeSidecar(name: job.partialName, validator: validator, receivedBytes: size, expectedBytes: expected))
        return true
    }

    /// The classification facts of a response as `task` saw it.
    func facts(of http: HTTPURLResponse, task: URLSessionTask) -> ResponseFacts {
        HTTPResponseReading.facts(
            of: http,
            bodyBytes: task.countOfBytesReceived,
            keyPresented: HTTPResponseReading.carriesKey(task.currentRequest, policy: self.policy)
        )
    }
}

/// The stateless progress rate limit (transport.md §4.4): a chunk is reported when it is the first one or crosses a
/// quantum boundary of `max(256 KiB, expected / 64)`, so a transfer reports at most 65 + size / 256 KiB times.
enum ProgressQuantum {
    /// The smallest quantum.
    static let minimum: Int64 = 256 * 1_024

    /// Whether the chunk that moved the partial from `before` to `after` bytes is reported.
    static func crossesBoundary(before: Int64, after: Int64, expected: Int64?) -> Bool {
        let quantum = max(Self.minimum, (expected ?? 0) / 64)
        return before <= 0 || before / quantum != after / quantum
    }
}
