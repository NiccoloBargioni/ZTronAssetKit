import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import ZTronAssetTransport

/// Every figure the transport adds or multiplies comes from a server (`Content-Length`, `Content-Range`), from disk
/// (a sidecar's resume offset) or from public configuration (the size cap, the task cap). Swift traps on overflow in
/// every build, so each such sum is saturated and an extreme value fails a transfer, never the process (review
/// round 3).
@Suite("Arithmetic on server and configuration figures")
struct ArithmeticSafetyTests {
    static let policy = TransportSecurityPolicy.production(allowedHosts: ["cdn.example.com"])
    static let url = URL(string: "https://cdn.example.com/a.bin")!

    /// A 206 answering a resume at `offset` 5 whose `Content-Length` is `Int64.max`.
    static func huge206() throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(
            url: Self.url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes 5-9/10", "Content-Type": "application/octet-stream", "Content-Length": String(Int64.max)]
        ))
    }

    @available(macOS 15.0, *)
    @Test("R-NET-7: a resumed 206 announcing Content-Length Int64.max aborts as oversize and leaves the earlier partial untouched", .timeLimit(.minutes(1)))
    func hugeContentLengthOnResumed206() async throws {
        let rig = try await LoopbackRig.make { _ in
            LoopbackResponse(
                status: 206,
                headers: [
                    "Content-Range": "bytes 5-9/10", "ETag": "\"v1\"", "Content-Type": "application/octet-stream",
                    "Content-Length": String(Int64.max),
                ],
                body: TransportFixtures.payload(5),
                ending: .closeAfter(bodyBytes: 5)
            )
        }
        let id = TransportFixtures.contentID(1)
        let earlier = rig.request(id, attempt: TransportFixtures.attempt(1), path: "a.bin", expected: 10)
        try rig.staging.createPartial(earlier.partialName)
        _ = try rig.staging.appendPartial(TransportFixtures.payload(5), to: earlier.partialName)
        let tag = try #require(ETag(rawValue: "\"v1\""))
        let resumed = rig.request(id, attempt: TransportFixtures.attempt(2), path: "a.bin", expected: 10,
                                  resume: ResumePoint(previous: earlier.partialName, offset: 5, validator: .strongETag(tag)))
        let result = await run(await rig.source.transfer(resumed))
        #expect(result.terminal == .failed(.integrity(.oversize(announced: .max, limit: 1 << 30))))
        #expect(result.progress.isEmpty)
        // The guard ran before anything was opened: the earlier partial is where and as it was, nothing was staged.
        #expect(rig.staging.contents[earlier.partialName] == TransportFixtures.payload(5))
        #expect(rig.staging.contents[resumed.partialName] == nil)
        #expect(rig.staging.sidecars.isEmpty)
        await rig.stop()
    }

    @available(macOS 15.0, *)
    @Test("R-NET-7: a chunk of a resumed 206 announcing Int64.max is judged oversize, not added up", .timeLimit(.minutes(1)))
    func hugeContentLengthPerChunk() async throws {
        let staging = FakeStagingSink()
        let delegate = SessionDelegate(mode: .foreground, staging: staging, policy: Self.policy)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let earlier = StagingFileName(transfer: TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(1), kind: .partial)
        let job = TransportFixtures.job(
            id: TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(2), url: Self.url, expected: 10,
            resume: ResumePoint(previous: earlier, offset: 5, validator: .strongETag(try #require(ETag(rawValue: "\"v1\"")))))
        try staging.createPartial(job.partialName)
        _ = try staging.appendPartial(TransportFixtures.payload(5), to: job.partialName)
        let (updates, continuation) = AsyncStream.makeStream(of: TransferUpdate.self)
        let task = session.dataTask(with: Self.url)
        let mailbox = TaskMailbox(continuation: continuation, job: job)
        task.delegate = mailbox
        let response = try Self.huge206()
        delegate.receive(TransportFixtures.payload(2), task: task, mailbox: mailbox, response: response)
        // The completion that follows the guard's cancel reports the verdict; no progress was reported for the chunk.
        let outcome = delegate.foregroundOutcome(task: task, job: job, response: response, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        #expect(outcome == .failed(.integrity(.oversize(announced: .max, limit: 1 << 30))))
        continuation.finish()
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(staging.sidecars.isEmpty)
    }
}
