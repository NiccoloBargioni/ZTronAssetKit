import Foundation
import Testing
import ZTronAssetModel
import ZTronAssetTestSupport
import ZTronAssetTransport

/// R-NET-7 and R-NET-8 through the real delegate (SPEC §7.3: gzip with decoded size ≠ `Content-Length`, an announced
/// size over the cap, a truncated body, a connection dropped mid-download then resumed).
@Suite("Sizes and resume")
struct SizeAndResumeTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-7: a gzip response is accepted when the decoded size equals byteSize though Content-Length differs", .timeLimit(.minutes(1)))
    func gzipDecodedSize() async throws {
        let body = Data(String(repeating: "ztron asset kit ", count: 19_688).utf8).prefix(315_000)
        #expect(Gzip.compress(body).count < 10_000)
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(body: body, encoding: .gzip) }
        let handle = await rig.source.transfer(rig.request(TransportFixtures.contentID(1), path: "a.txt", expected: 315_000))
        guard case .staged(let file)? = await run(handle).terminal else {
            Issue.record("not staged")
            await rig.stop()
            return
        }
        #expect(file.byteCount == 315_000)
        #expect(rig.staging.contents[file.name] == body)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-7: an announced size over maxAssetBytes aborts before any progress is reported", .timeLimit(.minutes(1)))
    func announcedOverCap() async throws {
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(body: Data(repeating: 1, count: 10 << 20)) }
        let request = rig.request(TransportFixtures.contentID(1), path: "big.bin", expected: nil, maxBytes: 1 << 20)
        let result = await run(await rig.source.transfer(request))
        #expect(result.terminal == .failed(.integrity(.oversize(announced: 10 << 20, limit: 1 << 20))))
        #expect(result.progress.isEmpty)
        #expect(rig.staging.contents[request.partialName] == nil)
        await rig.stop()
    }

    /// A close-delimited body (no `Content-Length`, explicit `Content-Type` so nothing is held back for MIME
    /// sniffing) of which the server sends `sent` bytes and then stalls with the connection open: only an abort while
    /// streaming can end such a transfer before the request timeout, after which it would be reported timed out.
    static func stalledUnannounced(_ body: Data, sent: Int) -> LoopbackResponse {
        LoopbackResponse(headers: ["Content-Type": "application/octet-stream"], body: body, ending: .stallAfter(bodyBytes: sent), omitContentLength: true)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-7: a body written past the cap without an announced length is aborted while streaming", .timeLimit(.minutes(1)))
    func writtenOverCap() async throws {
        let cap: Int64 = 1 << 20
        let body = Data(repeating: 1, count: 3 << 20)
        let rig = try await LoopbackRig.make { _ in Self.stalledUnannounced(body, sent: Int(cap) + 256 * 1_024) }
        let request = rig.request(TransportFixtures.contentID(1), path: "big.bin", expected: nil, maxBytes: cap)
        #expect(await run(await rig.source.transfer(request)).terminal == .failed(.integrity(.oversize(announced: nil, limit: cap))))
        // The guard stopped at the chunk that crossed the cap: the partial holds more than the cap, never the body.
        let written = try #require(rig.staging.contents[request.partialName]).count
        #expect(Int64(written) > cap && written < body.count)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-7: writing more than byteSize aborts early as a size mismatch", .timeLimit(.minutes(1)))
    func exceedsByteSize() async throws {
        let body = TransportFixtures.payload(2 << 20)
        let rig = try await LoopbackRig.make { _ in Self.stalledUnannounced(body, sent: 512 * 1_024) }
        let request = rig.request(TransportFixtures.contentID(1), path: "a.bin", expected: 1_000)
        guard case .failed(.integrity(.sizeMismatch(let expected, let actual)))? = await run(await rig.source.transfer(request)).terminal else {
            Issue.record("no size mismatch")
            await rig.stop()
            return
        }
        #expect(expected == 1_000 && actual > 1_000 && actual <= 512 * 1_024 && actual < Int64(body.count))
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-7: a close-delimited body shorter than byteSize is reported as truncated", .timeLimit(.minutes(1)))
    func closeDelimitedTruncated() async throws {
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(body: TransportFixtures.payload(40_000), omitContentLength: true) }
        let request = rig.request(TransportFixtures.contentID(1), path: "a.bin", expected: 100_000)
        #expect(await run(await rig.source.transfer(request)).terminal == .failed(.integrity(.truncated(expected: 100_000, received: 40_000))))
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-7: an empty body for an asset without byteSize is reported as truncated", .timeLimit(.minutes(1)))
    func emptyAsset() async throws {
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(body: Data()) }
        let request = rig.request(TransportFixtures.legacyID, path: "a.bin", expected: nil)
        #expect(await run(await rig.source.transfer(request)).terminal == .failed(.integrity(.truncated(expected: nil, received: 0))))
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-7: a body shorter than its Content-Length is reported as a lost connection", .timeLimit(.minutes(1)))
    func shorterThanContentLength() async throws {
        let rig = try await LoopbackRig.make { _ in
            LoopbackResponse(body: TransportFixtures.payload(100_000), ending: .closeAfter(bodyBytes: 40_000))
        }
        let request = rig.request(TransportFixtures.contentID(1), path: "a.bin", expected: 100_000)
        // No validator was sent, so nothing can be resumed.
        #expect(await run(await rig.source.transfer(request)).terminal == .failed(.transient(.connectionLost(resumable: false), retryAfter: nil)))
        #expect(rig.staging.sidecars.isEmpty)
        await rig.stop()
    }

    /// Attempt 1 of `video.bin` against a server that stalls after `stall` bytes and is then stopped, so the
    /// connection drops mid-body after the client provably staged those bytes (ARCHITECTURE §6.7: `stallAfter` +
    /// `stop()`; a FIN right behind the bytes races URLSession, which may report the loss first).
    @available(macOS 15.0, iOS 18.0, *)
    static func dropMidway(
        body: Data,
        stall: Int,
        staging: FakeStagingSink,
        appKey: AppKey,
        id: TransferID = TransportFixtures.contentID(1)
    ) async throws -> (TransferRequest, TransferUpdate?) {
        let rig = try await LoopbackRig.make(appKey: appKey, staging: staging) { _ in
            LoopbackResponse(body: body, ending: .stallAfter(bodyBytes: stall), rangeETag: "\"v1\"")
        }
        let first = rig.request(id, attempt: TransportFixtures.attempt(1), path: "video.bin", expected: Int64(body.count))
        let handle = await rig.source.transfer(first)
        var iterator = handle.updates.makeAsyncIterator()
        #expect(await awaitProgress(&iterator, reaching: Int64(stall)))
        await rig.server.stop()
        let terminal = await iterator.next()
        await rig.source.invalidate()
        return (first, terminal)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-8: a connection dropped mid-download resumes with Range and If-Range and the staged file is complete", .timeLimit(.minutes(1)))
    func droppedConnectionResumes() async throws {
        let body = TransportFixtures.payload(2 << 20)
        let staging = FakeStagingSink()
        let (first, terminal) = try await Self.dropMidway(body: body, stall: 1 << 20, staging: staging, appKey: TransportFixtures.canaryKey)
        #expect(terminal == .failed(.transient(.connectionLost(resumable: true), retryAfter: nil)))
        let sidecar = try #require(staging.sidecars[first.partialName])
        #expect(sidecar.receivedBytes == 1 << 20)
        #expect(staging.contents[first.partialName] == body.prefix(1 << 20))
        #expect(sidecar.validator == .strongETag(try #require(ETag(rawValue: "\"v1\""))))
        #expect(sidecar.expectedBytes == Int64(body.count))

        let rig = try await LoopbackRig.make(staging: staging) { _ in LoopbackResponse(body: body, rangeETag: "\"v1\"") }
        let resume = ResumePoint(previous: first.partialName, offset: sidecar.receivedBytes, validator: sidecar.validator)
        let second = rig.request(TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(2), path: "video.bin", expected: Int64(body.count), resume: resume)
        guard case .staged(let file)? = await run(await rig.source.transfer(second)).terminal else {
            Issue.record("resume not staged")
            await rig.stop()
            return
        }
        #expect(file.name == second.partialName && file.resumed && file.httpStatus == 206 && file.byteCount == Int64(body.count))
        #expect(staging.contents[second.partialName] == body)
        #expect(staging.contents[first.partialName] == nil)
        let resumed = try #require(await rig.requests(to: "/video.bin").last)
        #expect(resumed.header("range") == "bytes=\(1 << 20)-")
        #expect(resumed.header("if-range") == "\"v1\"")
        #expect(resumed.header("x-zombietron-app-key") == TransportFixtures.canaryValue)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-8: pause on a stalled transfer yields paused(resumable: true) and writes a sidecar", .timeLimit(.minutes(1)))
    func pauseKeepsThePartial() async throws {
        let rig = try await LoopbackRig.make { _ in
            LoopbackResponse(
                headers: ["Last-Modified": "Wed, 21 Oct 2026 07:28:00 GMT"],
                body: TransportFixtures.payload(1 << 20),
                ending: .stallAfter(bodyBytes: 512 * 1_024)
            )
        }
        let request = rig.request(TransportFixtures.contentID(1), path: "a.bin", expected: 1 << 20)
        let handle = await rig.source.transfer(request)
        var iterator = handle.updates.makeAsyncIterator()
        #expect(await awaitProgress(&iterator, reaching: 512 * 1_024))
        handle.pause()
        #expect(await iterator.next() == .paused(resumable: true))
        #expect(await iterator.next() == nil)
        let sidecar = try #require(rig.staging.sidecars[request.partialName])
        #expect(sidecar.receivedBytes == 512 * 1_024)
        #expect(sidecar.validator == .lastModified("Wed, 21 Oct 2026 07:28:00 GMT"))
        #expect(rig.staging.contents[request.partialName]?.count == 512 * 1_024)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-8: checksum-less transfers are never resumed", .timeLimit(.minutes(1)))
    func checksumLessNeverResumed() async throws {
        // The connection drops after the client staged bytes under a validator: only the identity forbids a sidecar.
        let staging = FakeStagingSink()
        let (request, terminal) = try await Self.dropMidway(
            body: TransportFixtures.payload(1 << 20), stall: 512 * 1_024, staging: staging, appKey: TransportFixtures.canaryKey, id: TransportFixtures.legacyID)
        #expect(staging.contents[request.partialName]?.count == 512 * 1_024)
        #expect(terminal == .failed(.transient(.connectionLost(resumable: false), retryAfter: nil)))
        #expect(staging.sidecars.isEmpty)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-8: a refused or invalid resume yields resumeRejected and a fresh attempt stages the whole body", .timeLimit(.minutes(1)))
    func refusedResume() async throws {
        let body = TransportFixtures.payload(2_000)
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(body: body, rangeETag: "\"v1\"") }
        let tag = try #require(ETag(rawValue: "\"v1\""))
        let id = TransportFixtures.contentID(1)
        // 416: the partial is longer than the resource.
        let tooLong = rig.request(id, attempt: TransportFixtures.attempt(1), path: "a.bin", expected: 2_000)
        try rig.staging.createPartial(tooLong.partialName)
        _ = try rig.staging.appendPartial(TransportFixtures.payload(3_000), to: tooLong.partialName)
        let past = rig.request(id, attempt: TransportFixtures.attempt(2), path: "a.bin", expected: 2_000,
                               resume: ResumePoint(previous: tooLong.partialName, offset: 3_000, validator: .strongETag(tag)))
        #expect(await run(await rig.source.transfer(past)).terminal == .failed(.transient(.resumeRejected, retryAfter: nil)))
        // Nothing was appended to the refused partial and nothing was staged under the new attempt: the engine
        // discards the earlier partial on resumeRejected (ARCHITECTURE §7.6), else staging GC collects it.
        #expect(rig.staging.contents[tooLong.partialName] == TransportFixtures.payload(3_000))
        #expect(rig.staging.contents[past.partialName] == nil)
        // A partial shorter than the offset the sidecar claims: the 206 cannot be appended.
        let short = rig.request(id, attempt: TransportFixtures.attempt(3), path: "a.bin", expected: 2_000)
        try rig.staging.createPartial(short.partialName)
        _ = try rig.staging.appendPartial(body.prefix(900), to: short.partialName)
        let mismatched = rig.request(id, attempt: TransportFixtures.attempt(4), path: "a.bin", expected: 2_000,
                                     resume: ResumePoint(previous: short.partialName, offset: 1_000, validator: .strongETag(tag)))
        #expect(await run(await rig.source.transfer(mismatched)).terminal == .failed(.transient(.resumeRejected, retryAfter: nil)))
        // The partial was taken over by the attempt (exclusive rename) and left exactly as it was: not one byte of the
        // 206 was appended to it.
        #expect(rig.staging.contents[mismatched.partialName] == body.prefix(900))
        #expect(rig.staging.contents[short.partialName] == nil)
        // An earlier partial that vanished (collected meanwhile) cannot be continued either.
        let vanished = rig.request(id, attempt: TransportFixtures.attempt(6), path: "a.bin", expected: 2_000,
                                   resume: ResumePoint(previous: tooLong.partialName, offset: 500, validator: .strongETag(tag)))
        await rig.staging.discard(tooLong.partialName)
        #expect(await run(await rig.source.transfer(vanished)).terminal == .failed(.transient(.resumeRejected, retryAfter: nil)))
        // The engine's next attempt starts fresh and stages everything.
        let fresh = rig.request(id, attempt: TransportFixtures.attempt(5), path: "a.bin", expected: 2_000)
        guard case .staged(let file)? = await run(await rig.source.transfer(fresh)).terminal else {
            Issue.record("fresh attempt not staged")
            await rig.stop()
            return
        }
        #expect(!file.resumed && rig.staging.contents[file.name] == body)
        #expect(await rig.server.requests.last?.header("range") == nil)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-8: a changed validator makes the origin send the whole body, which is staged from zero", .timeLimit(.minutes(1)))
    func changedValidatorRestartsFromZero() async throws {
        let body = TransportFixtures.payload(5_000, seed: 3)
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(body: body, rangeETag: "\"v2\"") }
        let id = TransportFixtures.contentID(1)
        let earlier = rig.request(id, attempt: TransportFixtures.attempt(1), path: "a.bin", expected: 5_000)
        try rig.staging.createPartial(earlier.partialName)
        _ = try rig.staging.appendPartial(TransportFixtures.payload(1_000, seed: 9), to: earlier.partialName)
        let resumed = rig.request(id, attempt: TransportFixtures.attempt(2), path: "a.bin", expected: 5_000,
                                  resume: ResumePoint(previous: earlier.partialName, offset: 1_000, validator: .strongETag(try #require(ETag(rawValue: "\"v1\"")))))
        guard case .staged(let file)? = await run(await rig.source.transfer(resumed)).terminal else {
            Issue.record("not staged")
            await rig.stop()
            return
        }
        #expect(!file.resumed && file.httpStatus == 200)
        #expect(rig.staging.contents[resumed.partialName] == body)
        #expect(rig.staging.contents[earlier.partialName] == nil)
        #expect(await rig.server.requests.first?.header("if-range") == "\"v1\"")
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-6: ENOSPC while staging maps to insufficientSpace and other staging failures to local I/O", .timeLimit(.minutes(1)))
    func stagingFailures() async throws {
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(body: TransportFixtures.payload(1_000)) }
        rig.staging.failNext(.appendPartial, with: .insufficientSpace)
        let full = rig.request(TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(1), path: "a.bin", expected: 1_000)
        #expect(await run(await rig.source.transfer(full)).terminal == .failed(.insufficientSpace(requiredBytes: 1_000)))
        rig.staging.failNext(.createPartial, with: .io(posixCode: EACCES))
        let denied = rig.request(TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(2), path: "a.bin", expected: 1_000)
        #expect(await run(await rig.source.transfer(denied)).terminal == .failed(.transient(.localIO(posixCode: EACCES), retryAfter: nil)))
        rig.staging.failNext(.createPartial, with: .nameInUse)
        let clash = rig.request(TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(3), path: "a.bin", expected: 1_000)
        #expect(await run(await rig.source.transfer(clash)).terminal == .failed(.transient(.localIO(posixCode: EEXIST), retryAfter: nil)))
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-7: a resumed partial already longer than byteSize is a size mismatch before any byte is appended", .timeLimit(.minutes(1)))
    func resumedPartialPastByteSize() async throws {
        let body = TransportFixtures.payload(5_000)
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(body: body, rangeETag: "\"v1\"") }
        let id = TransportFixtures.contentID(1)
        let earlier = rig.request(id, attempt: TransportFixtures.attempt(1), path: "a.bin", expected: 1_000)
        try rig.staging.createPartial(earlier.partialName)
        _ = try rig.staging.appendPartial(body.prefix(2_000), to: earlier.partialName)
        let resumed = rig.request(id, attempt: TransportFixtures.attempt(2), path: "a.bin", expected: 1_000,
                                  resume: ResumePoint(previous: earlier.partialName, offset: 2_000, validator: .strongETag(try #require(ETag(rawValue: "\"v1\"")))))
        #expect(await run(await rig.source.transfer(resumed)).terminal == .failed(.integrity(.sizeMismatch(expected: 1_000, actual: 2_000))))
        #expect(rig.staging.contents[earlier.partialName]?.count == 2_000)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-8: a 206 whose Content-Range does not start at the resume offset is never appended", .timeLimit(.minutes(1)), arguments: [
        "bytes 0-9/10", "items 5-9/10", "bytes x-9/10", "bytes 5",
    ])
    func contentRangeMismatch(_ contentRange: String) async throws {
        let rig = try await LoopbackRig.make { _ in
            LoopbackResponse(status: 206, headers: ["Content-Range": contentRange, "ETag": "\"v1\""], body: TransportFixtures.payload(5))
        }
        let id = TransportFixtures.contentID(1)
        let earlier = rig.request(id, attempt: TransportFixtures.attempt(1), path: "a.bin", expected: 10)
        try rig.staging.createPartial(earlier.partialName)
        _ = try rig.staging.appendPartial(TransportFixtures.payload(5), to: earlier.partialName)
        let resumed = rig.request(id, attempt: TransportFixtures.attempt(2), path: "a.bin", expected: 10,
                                  resume: ResumePoint(previous: earlier.partialName, offset: 5, validator: .strongETag(try #require(ETag(rawValue: "\"v1\"")))))
        #expect(await run(await rig.source.transfer(resumed)).terminal == .failed(.transient(.resumeRejected, retryAfter: nil)))
        #expect(rig.staging.contents[resumed.partialName] == nil)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-8: a Last-Modified validator is sent as If-Range and a full answer is staged from zero", .timeLimit(.minutes(1)))
    func lastModifiedValidator() async throws {
        let body = TransportFixtures.payload(3_000)
        let rig = try await LoopbackRig.make { _ in LoopbackResponse(body: body, rangeETag: "\"v1\"") }
        let id = TransportFixtures.contentID(1)
        let earlier = rig.request(id, attempt: TransportFixtures.attempt(1), path: "a.bin", expected: 3_000)
        try rig.staging.createPartial(earlier.partialName)
        _ = try rig.staging.appendPartial(body.prefix(1_000), to: earlier.partialName)
        let date = "Wed, 21 Oct 2026 07:28:00 GMT"
        let resumed = rig.request(id, attempt: TransportFixtures.attempt(2), path: "a.bin", expected: 3_000,
                                  resume: ResumePoint(previous: earlier.partialName, offset: 1_000, validator: .lastModified(date)))
        guard case .staged(let file)? = await run(await rig.source.transfer(resumed)).terminal else {
            Issue.record("not staged")
            await rig.stop()
            return
        }
        #expect(!file.resumed && rig.staging.contents[resumed.partialName] == body)
        #expect(await rig.server.requests.first?.header("if-range") == date)
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-6: every staging failure kind maps into the taxonomy, a cap as oversize and a source failure as local I/O", .timeLimit(.minutes(1)))
    func stagingFailureKinds() async throws {
        let rig = try await LoopbackRig.make { request in
            LoopbackResponse(body: request.target == "/empty.bin" ? Data() : TransportFixtures.payload(1_000))
        }
        rig.staging.failNext(.appendPartial, with: .tooLarge(limit: 7))
        let capped = rig.request(TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(1), path: "a.bin", expected: 1_000)
        #expect(await run(await rig.source.transfer(capped)).terminal == .failed(.integrity(.oversize(announced: nil, limit: 7))))
        rig.staging.failNext(.createPartial, with: .source(.notFound))
        let source = rig.request(TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(2), path: "a.bin", expected: 1_000)
        #expect(await run(await rig.source.transfer(source)).terminal == .failed(.transient(.localIO(posixCode: EIO), retryAfter: nil)))
        // An empty body's only staging call is the final size read: its failure is the transfer's failure.
        rig.staging.failNext(.appendPartial, with: .io(posixCode: EIO))
        let empty = rig.request(TransportFixtures.legacyID, attempt: TransportFixtures.attempt(3), path: "empty.bin", expected: nil)
        #expect(await run(await rig.source.transfer(empty)).terminal == .failed(.transient(.localIO(posixCode: EIO), retryAfter: nil)))
        await rig.stop()
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test("R-NET-8: a resumed request carries the current key, never a stale one", .timeLimit(.minutes(1)))
    func resumedRequestCarriesTheCurrentKey() async throws {
        let body = TransportFixtures.payload(1 << 20)
        let staging = FakeStagingSink()
        let (first, terminal) = try await Self.dropMidway(body: body, stall: 512 * 1_024, staging: staging, appKey: AppKey("OLD-KEY-1"))
        #expect(terminal == .failed(.transient(.connectionLost(resumable: true), retryAfter: nil)))
        // The sidecar holds a validator and a size, never a header: the next launch's key is the one sent.
        let sidecar = try #require(staging.sidecars[first.partialName])
        let rig = try await LoopbackRig.make(appKey: AppKey("NEW-KEY-2"), staging: staging) { _ in
            LoopbackResponse(body: body, rangeETag: "\"v1\"")
        }
        let second = rig.request(TransportFixtures.contentID(1), attempt: TransportFixtures.attempt(2), path: "video.bin", expected: Int64(body.count),
                                 resume: ResumePoint(previous: first.partialName, offset: sidecar.receivedBytes, validator: sidecar.validator))
        guard case .staged(let file)? = await run(await rig.source.transfer(second)).terminal else {
            Issue.record("not staged")
            await rig.stop()
            return
        }
        #expect(file.resumed && staging.contents[second.partialName] == body)
        let resumed = try #require(await rig.server.requests.first)
        #expect(resumed.header("range") == "bytes=\(512 * 1_024)-")
        #expect(resumed.header("x-zombietron-app-key") == "NEW-KEY-2")
        await rig.stop()
    }
}
