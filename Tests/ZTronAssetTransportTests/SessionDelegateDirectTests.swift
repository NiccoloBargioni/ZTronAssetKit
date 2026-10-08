import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import ZTronAssetTransport

/// The delegate paths no loopback transfer reaches, driven by calling `SessionDelegate`'s methods directly with
/// **unresumed** tasks of an ephemeral session (no transfer, no CFNetwork temp file) and files this test wrote
/// inside the repository, then reading `sessionEvents` (ARCHITECTURE §14).
@Suite("Session delegate, called directly")
struct SessionDelegateDirectTests {
    static let policy = TransportSecurityPolicy.production(allowedHosts: ["cdn.example.com"])
    static let url = URL(string: "https://cdn.example.com/a.bin")!
    static let name = StagingFileName(transfer: TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(1), kind: .partial)

    @available(macOS 15.0, *)
    @Test("R-NET-3: a background download is reported under its tag, a foreign one is ignored, and didFinishEvents follows", .timeLimit(.minutes(1)))
    func backgroundDownloadRouting() async throws {
        let staging = FakeStagingSink()
        let delegate = SessionDelegate(mode: .background, staging: staging, policy: Self.policy)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let directory = try TransportFixtures.directory("direct-download")
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("os.tmp")
        try Data("bytes".utf8).write(to: location)

        let tagged = session.downloadTask(with: Self.url)
        tagged.taskDescription = BackgroundTaskTag(name: Self.name, expectedBytes: 5).encoded
        // An unresumed task has no response: nothing is adopted, and the event says why.
        delegate.urlSession(session, downloadTask: tagged, didFinishDownloadingTo: location)
        let foreign = session.downloadTask(with: Self.url)
        foreign.taskDescription = "not ours"
        delegate.urlSession(session, downloadTask: foreign, didFinishDownloadingTo: location)
        delegate.urlSession(session, task: tagged, didCompleteWithError: nil)
        delegate.urlSessionDidFinishEvents(forBackgroundURLSession: session)

        var events = delegate.sessionEvents.makeAsyncIterator()
        #expect(await events.next() == .finished(name: Self.name, update: .failed(.transient(.badServerResponse, retryAfter: nil))))
        #expect(await events.next() == .backgroundEventsFinished)
        #expect(staging.contents.isEmpty)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-6: background cancel reasons map to cancelled by the system and file errors keep their POSIX code", .timeLimit(.minutes(1)))
    func backgroundFailures() async throws {
        let delegate = SessionDelegate(mode: .background, staging: FakeStagingSink(), policy: Self.policy)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: Self.url)
        task.taskDescription = BackgroundTaskTag(name: Self.name, expectedBytes: nil).encoded
        delegate.urlSession(session, task: task, didCompleteWithError: NSError(
            domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [NSURLErrorBackgroundTaskCancelledReasonKey: 0]))
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        delegate.urlSession(session, task: task, didCompleteWithError: NSError(
            domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile, userInfo: [NSUnderlyingErrorKey: posix]))
        delegate.urlSession(session, task: task, didCompleteWithError: NSError(
            domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [NSURLErrorNetworkUnavailableReasonKey: 2]))
        let untagged = session.downloadTask(with: Self.url)
        delegate.urlSession(session, task: untagged, didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        delegate.urlSession(session, didBecomeInvalidWithError: nil)

        var events = delegate.sessionEvents.makeAsyncIterator()
        #expect(await events.next() == .finished(name: Self.name, update: .failed(.cancelled(.bySystem(.userForceQuitApplication)))))
        #expect(await events.next() == .finished(name: Self.name, update: .failed(.insufficientSpace(requiredBytes: nil))))
        #expect(await events.next() == .finished(name: Self.name, update: .failed(.offline(.constrainedDenied))))
        #expect(await events.next() == .invalidated)
        #expect(await events.next() == nil)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-2: a foreground delegate ignores download callbacks and tasks without a mailbox", .timeLimit(.minutes(1)))
    func foregroundIgnoresForeignCallbacks() async throws {
        let delegate = SessionDelegate(mode: .foreground, staging: FakeStagingSink(), policy: Self.policy)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let download = session.downloadTask(with: Self.url)
        download.taskDescription = BackgroundTaskTag(name: Self.name, expectedBytes: 5).encoded
        let directory = try TransportFixtures.directory("direct-foreground")
        defer { try? FileManager.default.removeItem(at: directory) }
        delegate.urlSession(session, downloadTask: download, didFinishDownloadingTo: directory.appendingPathComponent("absent"))
        delegate.urlSession(session, task: download, didCompleteWithError: nil)
        let orphan = session.dataTask(with: Self.url)
        let disposition = await withCheckedContinuation { continuation in
            delegate.urlSession(session, dataTask: orphan, didReceive: URLResponse(url: Self.url, mimeType: nil, expectedContentLength: 1, textEncodingName: nil)) { continuation.resume(returning: $0) }
        }
        #expect(disposition == .cancel)
        delegate.urlSession(session, dataTask: orphan, didReceive: Data("x".utf8))
        delegate.urlSession(session, didBecomeInvalidWithError: nil)
        var events = delegate.sessionEvents.makeAsyncIterator()
        #expect(await events.next() == .invalidated)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-6: a response that is not HTTP stops the task and is reported as a bad server response", .timeLimit(.minutes(1)))
    func nonHTTPResponse() async throws {
        let staging = FakeStagingSink()
        let delegate = SessionDelegate(mode: .foreground, staging: staging, policy: Self.policy)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let job = TransportFixtures.job(id: TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(1), url: Self.url, expected: 5)
        let (updates, continuation) = AsyncStream.makeStream(of: TransferUpdate.self)
        let task = session.dataTask(with: Self.url)
        task.delegate = TaskMailbox(continuation: continuation, job: job)
        let response = URLResponse(url: Self.url, mimeType: nil, expectedContentLength: 5, textEncodingName: nil)
        let disposition = await withCheckedContinuation { result in
            delegate.urlSession(session, dataTask: task, didReceive: response) { result.resume(returning: $0) }
        }
        #expect(disposition == .cancel)
        delegate.urlSession(session, task: task, didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .failed(.transient(.badServerResponse, retryAfter: nil)))
        #expect(await iterator.next() == nil)
        // A completion without a response and without an error is not a success either.
        let (silent, silentContinuation) = AsyncStream.makeStream(of: TransferUpdate.self)
        let silentTask = session.dataTask(with: Self.url)
        silentTask.delegate = TaskMailbox(continuation: silentContinuation, job: job)
        delegate.urlSession(session, task: silentTask, didCompleteWithError: nil)
        var silentIterator = silent.makeAsyncIterator()
        #expect(await silentIterator.next() == .failed(.transient(.badServerResponse, retryAfter: nil)))
        #expect(staging.contents.isEmpty)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-6: a timed-out foreground task without a response is reported as timed out and keeps nothing", .timeLimit(.minutes(1)))
    func timeoutWithoutResponse() async throws {
        let staging = FakeStagingSink()
        let delegate = SessionDelegate(mode: .foreground, staging: staging, policy: Self.policy)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let job = TransportFixtures.job(id: TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(1), url: Self.url, expected: 5)
        let (updates, continuation) = AsyncStream.makeStream(of: TransferUpdate.self)
        let task = session.dataTask(with: Self.url)
        task.delegate = TaskMailbox(continuation: continuation, job: job)
        delegate.urlSession(session, task: task, didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == .failed(.transient(.timedOut, retryAfter: nil)))
        #expect(staging.sidecars.isEmpty)
    }
}
