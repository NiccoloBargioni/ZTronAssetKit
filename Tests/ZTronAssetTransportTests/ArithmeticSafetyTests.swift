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

    /// One size-guard input at the edges of `Int64`.
    struct GuardRow: Sendable, CustomTestStringConvertible {
        var label: String
        var written: Int64
        var announced: Int64?
        var expected: Int64?
        var limit: Int64
        var verdict: SizeVerdict

        var testDescription: String {
            self.label
        }
    }

    /// The contract table (`TransportContractTests`) covers ordinary sizes; these rows are the extremes a
    /// configuration (`maxAssetBytes = Int64.max` meaning "unlimited") or a server can produce.
    static let guardRows: [GuardRow] = [
        GuardRow(label: "an announced length under a cap of Int64.max", written: 0, announced: 100, expected: nil, limit: .max, verdict: .proceed),
        GuardRow(label: "Int64.max announced under a cap of Int64.max", written: 0, announced: .max, expected: nil, limit: .max, verdict: .proceed),
        GuardRow(label: "Int64.max announced under a cap just below it", written: 0, announced: .max, expected: nil, limit: .max - 1, verdict: .proceed),
        GuardRow(label: "Int64.max announced under an ordinary cap", written: 0, announced: .max, expected: nil, limit: 1 << 30, verdict: .abortOversize),
        GuardRow(label: "Int64.max written and expected under a cap of Int64.max", written: .max, announced: nil, expected: .max, limit: .max, verdict: .proceed),
        GuardRow(label: "a negative cap whose slack underflows", written: .min, announced: 0, expected: nil, limit: .min, verdict: .abortOversize),
        GuardRow(label: "a negative cap with nothing written", written: 0, announced: nil, expected: nil, limit: -1, verdict: .abortOversize),
    ]

    @Test("R-NET-7: the size guard decides at the edges of Int64 without trapping", arguments: ArithmeticSafetyTests.guardRows)
    func sizeGuardExtremes(_ row: GuardRow) {
        #expect(SizeGuard.verdict(written: row.written, announced: row.announced, expected: row.expected, limit: row.limit) == row.verdict)
    }

    @available(macOS 15.0, *)
    @Test("R-NET-7: a size cap of Int64.max means unlimited and a negative one nothing, both through a whole transfer", .timeLimit(.minutes(1)))
    func extremeConfiguredCaps() async throws {
        let body = TransportFixtures.payload(1_000)
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(body: body) }
        let unlimited = rig.request(TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(1), path: "a.bin", expected: 1_000, maxBytes: .max)
        guard case .staged(let file)? = await run(await rig.source.transfer(unlimited)).terminal else {
            Issue.record("not staged under a cap of Int64.max")
            await rig.stop()
            return
        }
        #expect(file.byteCount == 1_000 && rig.staging.contents[file.name] == body)
        // A negative cap is read as 0 when the job is built: nothing is allowed, and the failure names that cap.
        let none = rig.request(TransportFixtures.contentID(2), attempt: TransportFixtures.attempt(2), path: "a.bin", expected: 1_000, maxBytes: .min)
        #expect(await run(await rig.source.transfer(none)).terminal == .failed(.integrity(.oversize(announced: 1_000, limit: 0))))
        #expect(rig.staging.contents[none.partialName] == nil)
        await rig.stop()
    }

    @available(macOS 15.0, *)
    @Test("R-NET-8: a resume offset of Int64.min from a corrupt sidecar never traps, and the origin's 200 is staged from zero", .timeLimit(.minutes(1)))
    func corruptResumeOffset() async throws {
        let body = TransportFixtures.payload(1_000)
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(body: body) }
        let id = TransportFixtures.contentID(1)
        let earlier = StagingFileName(transfer: id, attempt: TransportFixtures.attempt(1), kind: .partial)
        let tag = try #require(ETag(rawValue: "\"v1\""))
        let resumed = rig.request(id, attempt: TransportFixtures.attempt(2), path: "a.bin", expected: 1_000,
                                  resume: ResumePoint(previous: earlier, offset: .min, validator: .strongETag(tag)))
        guard case .staged(let file)? = await run(await rig.source.transfer(resumed)).terminal else {
            Issue.record("not staged")
            await rig.stop()
            return
        }
        #expect(!file.resumed && file.byteCount == 1_000 && rig.staging.contents[file.name] == body)
        await rig.stop()
    }

    @available(macOS 15.0, *)
    @Test("R-NET-8: a live resumed transfer counts the resume offset only when the origin continued it with a 206", .timeLimit(.minutes(1)), arguments: [true, false])
    func liveBytesCountTheOffsetOnlyFor206(_ continued: Bool) async throws {
        // 600,000 bytes give a progress quantum of 256 KiB, so the chunk that reaches 262,144 staged bytes is reported
        // exactly when the server stalls: the staged size is known when the live transfer is listed.
        let quantum = 262_144
        let body = TransportFixtures.payload(600_000)
        let rig = try await LoopbackRig.make { _ in
            LoopbackResponse(body: body, ending: .stallAfter(bodyBytes: continued ? quantum - 1_000 : quantum), rangeETag: "\"v1\"")
        }
        let id = TransportFixtures.contentID(1)
        let earlier = rig.request(id, attempt: TransportFixtures.attempt(1), path: "a.bin", expected: 600_000)
        try rig.staging.createPartial(earlier.partialName)
        _ = try rig.staging.appendPartial(body.prefix(1_000), to: earlier.partialName)
        // A matching validator continues the partial (206); a changed one makes the origin send everything (200).
        let validator = try #require(ETag(rawValue: continued ? "\"v1\"" : "\"v0\""))
        let resumed = rig.request(id, attempt: TransportFixtures.attempt(2), path: "a.bin", expected: 600_000,
                                  resume: ResumePoint(previous: earlier.partialName, offset: 1_000, validator: .strongETag(validator)))
        let handle = await rig.source.transfer(resumed)
        var iterator = handle.updates.makeAsyncIterator()
        #expect(await awaitProgress(&iterator, reaching: Int64(quantum)))
        #expect(rig.staging.contents[resumed.partialName]?.count == quantum)
        // The figure the engine sees is what the partial holds, whether or not the offset was continued.
        #expect(await rig.foreground.liveTransfers().map(\.bytesReceived) == [Int64(quantum)])
        handle.cancel()
        #expect(await iterator.next() == .failed(.cancelled(.byClient)))
        await rig.stop()
    }

    @available(macOS 15.0, *)
    @Test("R-NET-3: a background task cap of Int.max sizes the coordinator's tables without trapping", .timeLimit(.minutes(1)))
    func unboundedTaskCap() async throws {
        let rig = try BackgroundCoordinatorTests.Rig("cap-int-max", maxTasks: .max)
        defer { rig.cleanUp() }
        let coordinator = rig.coordinator()
        #expect(await coordinator.admits())
        let job = rig.job()
        let handle = await coordinator.start(job)
        await rig.driver.complete(job.partialName, body: TransportFixtures.payload(4_000))
        #expect(await run(handle).terminal == .staged(StagedFile(name: job.partialName, byteCount: 4_000, resumed: false, httpStatus: 200, etag: nil)))
        #expect(await coordinator.admits())
    }
}
